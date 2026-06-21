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
        
        self.episodes = []
        self.channelTitle = ""
        self.channelArtworkUrl = nil
        self.inItem = false
        self.inImage = false
        
        guard let parser = XMLParser(contentsOf: tempFileUrl) else {
            throw NSError(domain: "PodcastParser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create parser for file"])
        }
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
        if inItem {
            if currentElement == "title" {
                currentTitle += string
            } else if currentElement == "guid" {
                currentGuid += string
            } else if currentElement == "description" || currentElement == "content:encoded" {
                currentDescription += string
            } else if currentElement == "pubDate" {
                currentPubDate += string
            } else if currentElement == "itunes:duration" {
                currentDuration += string
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
            let id = currentGuid.isEmpty ? currentAudioUrl : currentGuid
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
