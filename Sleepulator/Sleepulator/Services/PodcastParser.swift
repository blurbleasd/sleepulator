import Foundation

class PodcastParser: NSObject, XMLParserDelegate {
    struct ParsedFeed {
        let title: String
        let artworkUrl: String?
        let episodes: [Episode]
    }
    
    private var episodes: [Episode] = []
    private var channelTitle = ""
    private var channelArtworkUrl: String? = nil
    
    private var currentElement = ""
    private var currentTitle = ""
    private var currentAudioUrl = ""
    private var currentGuid = ""
    private var currentDescription = ""
    private var currentPubDate = ""
    private var currentDuration = ""
    private var currentItemArtworkUrl: String? = nil
    
    private var inItem = false
    private var inImage = false
    private var tempImageUrl = ""
    
    func parseFeed(url: URL) async throws -> ParsedFeed {
        let (tempFileUrl, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempFileUrl) }
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "PodcastParser", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(status)"])
        }

        let data = try Data(contentsOf: tempFileUrl)
        return try parse(data: data)
    }

    /// Parse feed XML from in-memory bytes. Split out from the network fetch so the parsing
    /// logic (CDATA, dates, durations, artwork) is unit-testable without hitting the network.
    func parse(data: Data) throws -> ParsedFeed {
        self.episodes = []
        self.channelTitle = ""
        self.channelArtworkUrl = nil
        self.inItem = false
        self.inImage = false

        let parser = XMLParser(data: data)
        parser.delegate = self
        if parser.parse() {
            // Sort by pubDate descending
            episodes.sort { ($0.pubDate ?? Date.distantPast) > ($1.pubDate ?? Date.distantPast) }
            return ParsedFeed(title: channelTitle.trimmingCharacters(in: .whitespacesAndNewlines), artworkUrl: channelArtworkUrl, episodes: episodes)
        } else {
            let errDesc = parser.parserError?.localizedDescription ?? "Failed to parse XML"
            throw NSError(domain: "PodcastParser", code: 1, userInfo: [NSLocalizedDescriptionKey: errDesc])
        }
    }
    
    // MARK: - XMLParserDelegate
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if elementName == "item" {
            inItem = true
            currentTitle = ""
            currentAudioUrl = ""
            currentGuid = ""
            currentDescription = ""
            currentPubDate = ""
            currentDuration = ""
            currentItemArtworkUrl = nil
        } else if elementName == "image" && !inItem {
            inImage = true
            tempImageUrl = ""
        }
        
        if inItem && elementName == "enclosure" {
            if let urlString = attributeDict["url"] {
                currentAudioUrl = urlString
            }
        }
        
        if elementName == "itunes:image" {
            if let href = attributeDict["href"] {
                if inItem {
                    currentItemArtworkUrl = href
                } else if channelArtworkUrl == nil {
                    channelArtworkUrl = href
                }
            }
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        accumulate(string)
    }

    // Most real feeds wrap <description>/<content:encoded> (and sometimes <title>) in
    // CDATA, which XMLParser delivers here — NOT via foundCharacters. Without this,
    // episode show-notes came back empty for the majority of podcasts.
    func parser(_ parser: XMLParser, foundCDATABlock CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            accumulate(string)
        }
    }

    /// Append text (plain or CDATA) to the buffer the current element maps to.
    private func accumulate(_ string: String) {
        if inItem {
            switch currentElement {
            case "title":                       currentTitle += string
            case "guid":                        currentGuid += string
            case "description", "content:encoded": currentDescription += string
            case "pubDate":                     currentPubDate += string
            case "itunes:duration":             currentDuration += string
            default:                            break
            }
        } else {
            if currentElement == "title" && !inImage {
                channelTitle += string
            } else if inImage && currentElement == "url" {
                tempImageUrl += string
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            inItem = false
            let trimmedGuid = currentGuid.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = trimmedGuid.isEmpty ? currentAudioUrl.trimmingCharacters(in: .whitespacesAndNewlines) : trimmedGuid
            if !currentAudioUrl.isEmpty {
                let desc = currentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                
                let ep = Episode(
                    id: id,
                    title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    audioUrl: currentAudioUrl,
                    duration: parseDuration(currentDuration),
                    pubDate: parseDate(currentPubDate),
                    description: desc.isEmpty ? nil : desc,
                    artworkUrl: currentItemArtworkUrl ?? channelArtworkUrl
                )
                episodes.append(ep)
            }
        } else if elementName == "image" {
            inImage = false
            if channelArtworkUrl == nil && !tempImageUrl.isEmpty {
                channelArtworkUrl = tempImageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Clear the current element so whitespace between tags doesn't leak into the next
        // buffer — it was accumulating into currentGuid, leaving ids like "ep-1\n            ".
        currentElement = ""
    }
    
    private func parseDate(_ dateStr: String) -> Date? {
        let cleanStr = dateStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanStr.isEmpty { return nil }
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let d = formatter.date(from: cleanStr) { return d }
        
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        if let d = formatter.date(from: cleanStr) { return d }
        
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm Z"
        if let d = formatter.date(from: cleanStr) { return d }
        
        return nil
    }
    
    private func parseDuration(_ durationStr: String) -> TimeInterval? {
        let cleanStr = durationStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanStr.isEmpty { return nil }
        
        if let seconds = TimeInterval(cleanStr) {
            return seconds
        }
        
        let parts = cleanStr.split(separator: ":").compactMap { TimeInterval($0) }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        } else if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }
        return nil
    }
}
