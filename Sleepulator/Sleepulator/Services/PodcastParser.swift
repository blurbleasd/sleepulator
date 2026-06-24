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
        // Configured session + retry-with-backoff: a single flaky-Wi-Fi blip no longer reads as
        // "feed broken." Only transient errors (timeout / connection-lost / 5xx) are retried; a
        // 4xx throws straight through (see Net.isRetryable).
        let data = try await Net.retry {
            let (tempFileUrl, response) = try await Net.feed.download(from: url)
            defer { try? FileManager.default.removeItem(at: tempFileUrl) }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw HTTPStatusError(statusCode: httpResponse.statusCode)
            }
            return try Data(contentsOf: tempFileUrl)
        }
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
        
        if inItem && elementName == "enclosure", let urlString = attributeDict["url"] {
            // Prefer an audio enclosure. Some feeds add transcript/chapters enclosures that would
            // otherwise overwrite the audio URL (last-wins); accept a typeless one only if we have
            // nothing yet.
            let type = (attributeDict["type"] ?? "").lowercased()
            if type.hasPrefix("audio/") || (currentAudioUrl.isEmpty && type.isEmpty) {
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
        // Most feeds are UTF-8, but some are Latin-1 / Windows-1252; fall back so those don't
        // silently lose show-notes (String(data:encoding:.utf8) returns nil on invalid UTF-8).
        if let string = String(data: CDATABlock, encoding: .utf8)
            ?? String(data: CDATABlock, encoding: .isoLatin1)
            ?? String(data: CDATABlock, encoding: .windowsCP1252) {
            accumulate(string)
        }
    }

    // Caps on accumulated text per field. A malformed feed with a giant CDATA block could
    // otherwise grow a buffer without bound and OOM. Show-notes get a generous ceiling; the
    // short fields (title/date/duration/guid) are tightly bounded.
    private static let maxDescriptionChars = 200_000
    private static let maxShortFieldChars  = 4_000

    /// Append `string` to `buffer` only while it stays under `cap`; silently drop the overflow.
    private func appendCapped(_ string: String, to buffer: inout String, cap: Int) {
        guard buffer.count < cap else { return }
        buffer += string
        if buffer.count > cap { buffer = String(buffer.prefix(cap)) }
    }

    /// Append text (plain or CDATA) to the buffer the current element maps to.
    private func accumulate(_ string: String) {
        if inItem {
            switch currentElement {
            case "title":                          appendCapped(string, to: &currentTitle, cap: Self.maxShortFieldChars)
            case "guid":                           appendCapped(string, to: &currentGuid, cap: Self.maxShortFieldChars)
            case "description", "content:encoded": appendCapped(string, to: &currentDescription, cap: Self.maxDescriptionChars)
            case "pubDate":                        appendCapped(string, to: &currentPubDate, cap: Self.maxShortFieldChars)
            case "itunes:duration":                appendCapped(string, to: &currentDuration, cap: Self.maxShortFieldChars)
            default:                               break
            }
        } else {
            if currentElement == "title" && !inImage {
                appendCapped(string, to: &channelTitle, cap: Self.maxShortFieldChars)
            } else if inImage && currentElement == "url" {
                appendCapped(string, to: &tempImageUrl, cap: Self.maxShortFieldChars)
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
        // RFC-822 variants: numeric offset (Z) and named zone (zzz, e.g. GMT/EST), with and without
        // seconds / a leading-zero day. Many real feeds use named zones, which the Z formats miss.
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "EEE, dd MMM yyyy HH:mm zzz"
        ]
        for fmt in formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: cleanStr) { return d }
        }

        // Atom / ISO-8601 (e.g. 2026-06-23T09:00:00Z).
        if let d = ISO8601DateFormatter().date(from: cleanStr) { return d }

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
