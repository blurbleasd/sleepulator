import Foundation

class PodcastParser: NSObject, XMLParserDelegate {
    private var episodes: [Episode] = []
    private var currentElement = ""
    private var currentTitle = ""
    private var currentAudioUrl = ""
    private var currentGuid = ""
    private var inItem = false
    
    func parseFeed(url: URL) async throws -> [Episode] {
        let (data, _) = try await URLSession.shared.data(from: url)
        self.episodes = []
        
        let parser = XMLParser(data: data)
        parser.delegate = self
        if parser.parse() {
            return episodes
        } else {
            throw NSError(domain: "PodcastParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse XML"])
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
        }
        
        if inItem && elementName == "enclosure" {
            if let urlString = attributeDict["url"] {
                currentAudioUrl = urlString
            }
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem {
            if currentElement == "title" {
                currentTitle += string
            } else if currentElement == "guid" {
                currentGuid += string
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            inItem = false
            let id = currentGuid.isEmpty ? currentAudioUrl : currentGuid
            if !currentAudioUrl.isEmpty {
                let ep = Episode(id: id, title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines), audioUrl: currentAudioUrl)
                episodes.append(ep)
            }
        }
    }
}
