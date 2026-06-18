import Foundation

struct OPMLFeed: Identifiable {
    let id = UUID()
    let name: String
    let url: String
}

class OPMLParser: NSObject, XMLParserDelegate {
    private var feeds: [OPMLFeed] = []
    
    func parse(url: URL) -> [OPMLFeed] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return feeds
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName.lowercased() == "outline", let url = attributeDict["xmlUrl"] {
            let name = attributeDict["text"] ?? attributeDict["title"] ?? url
            feeds.append(OPMLFeed(name: name, url: url))
        }
    }
}
