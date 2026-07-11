import Foundation
import os

nonisolated struct OPMLFeed: Identifiable {
    /// Stable across re-parses (was a fresh UUID() each parse, which broke SwiftUI diffing).
    var id: String { url }
    let name: String
    let url: String
}

/// `nonisolated` so the parser can run inside `Task.detached` off the main thread (a large OPML
/// file would otherwise freeze the importer callback). The module defaults to @MainActor isolation,
/// which made `OPMLParser().parse(...)` a cross-actor (async) call from the detached context — an
/// error under Swift 6 mode. It's a self-contained, single-shot XML parser with no UI state.
nonisolated class OPMLParser: NSObject, XMLParserDelegate {
    /// Own logger rather than `Log.storage`: this class is `nonisolated` (it runs inside
    /// `Task.detached`), and `Log`'s statics are main-actor-isolated by the module default.
    private static let log = Logger(subsystem: "app.sleepulator", category: "storage")

    private var feeds: [OPMLFeed] = []
    private var seen = Set<String>()

    func parse(url: URL) -> [OPMLFeed] {
        feeds = []
        seen = []
        guard let data = try? Data(contentsOf: url) else {
            Self.log.error("OPML import: could not read file at \(url.lastPathComponent, privacy: .public)")
            return []
        }
        let parser = XMLParser(data: data)
        parser.delegate = self
        // A corrupt OPML otherwise looks identical to an empty one — leave a breadcrumb.
        // (Feeds found before the malformed point are still returned; XMLParser stops there.)
        if !parser.parse() {
            Self.log.error("OPML import: parse failed (\(parser.parserError?.localizedDescription ?? "unknown", privacy: .public)); returning \(self.feeds.count) feed(s) parsed before the error")
        }
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
