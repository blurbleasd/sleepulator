import Foundation

struct OPMLFeed: Identifiable {
    /// Stable across re-parses (was a fresh UUID() each parse, which broke SwiftUI diffing).
    var id: String { url }
    let name: String
    let url: String
}

class OPMLParser: NSObject, XMLParserDelegate {
    private var feeds: [OPMLFeed] = []
    private var seen = Set<String>()

    func parse(url: URL) -> [OPMLFeed] {
        feeds = []
        seen = []
        guard let data = try? Data(contentsOf: url) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return feeds
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName.lowercased() == "outline", let raw = attributeDict["xmlUrl"] else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only accept real http(s) feeds — reject file://, javascript:, and other schemes that
        // could be fetched or mishandled downstream.
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        // Dedupe: an OPML can list the same feed more than once.
        let key = trimmed.lowercased()
        guard !seen.contains(key) else { return }
        seen.insert(key)
        let name = attributeDict["text"] ?? attributeDict["title"] ?? trimmed
        feeds.append(OPMLFeed(name: name, url: trimmed))
    }
}
