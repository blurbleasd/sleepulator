import Foundation

class PodcastParser: NSObject, XMLParserDelegate {
    private var episodes: [Episode] = []
    private var currentElement = ""
    private var currentTitle = ""
    private var currentAudioUrl = ""
    private var currentGuid = ""
    private var currentDescription = ""
    private var inItem = false
    
    func parseFeed(url: URL) async throws -> [Episode] {
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "PodcastParser", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(status)"])
        }
        
        self.episodes = []
        
        let parser = XMLParser(data: data)
        parser.delegate = self
        if parser.parse() {
            return episodes
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
            } else if currentElement == "description" || currentElement == "content:encoded" {
                currentDescription += string
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            inItem = false
            let id = currentGuid.isEmpty ? currentAudioUrl : currentGuid
            if !currentAudioUrl.isEmpty {
                let desc = currentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let ep = Episode(id: id, title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines), audioUrl: currentAudioUrl, description: desc.isEmpty ? nil : desc)
                episodes.append(ep)
            }
        }
    }
}
