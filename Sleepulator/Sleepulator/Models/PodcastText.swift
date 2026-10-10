import Foundation

/// Pure text rules for the podcast screens: show-notes cleanup, counts, durations, and when a
/// stored show name is only a placeholder. No UI, no I/O; unit-tested in `PodcastTextTests`.
/// `nonisolated` so the parser can flatten show-notes off the main actor.
nonisolated enum PodcastText {

    // MARK: - Show notes

    /// Stored show-notes are capped here: past this it's sponsor reads and link lists, and a
    /// 750-episode feed of raw HTML was writing a ~3 MB library.json on every visit.
    static let showNotesLimit = 3_000

    /// Feed show-notes arrive as HTML (`<p>`, `<a href>`, `<strong>`, entities). `Text` renders
    /// markup literally, which put a wall of raw tags in front of someone in bed. This flattens
    /// it to plain text with paragraph breaks and list bullets, and caps the length at a
    /// paragraph or word boundary. Idempotent on its own output, so it's safe to run again on
    /// episodes cached before it existed.
    static func plainShowNotes(_ raw: String, limit: Int = showNotesLimit) -> String {
        var text = decodeEntities(stripTags(raw))
        // Some feeds double-encode (`&lt;p&gt;`), so a decode can surface a second layer of tags.
        if looksLikeMarkup(text) { text = decodeEntities(stripTags(text)) }
        return truncate(normalizeWhitespace(text), limit: limit)
    }

    /// The collapsed show-notes: whole opening paragraphs up to about `budget` characters (always
    /// at least the first, cut at a word if it alone runs long). Equal to `notes` when nothing
    /// was held back, which is how the row knows whether to offer "More".
    static func notesPreview(_ notes: String, budget: Int = 320) -> String {
        let paragraphs = notes.components(separatedBy: "\n\n")
        var kept: [String] = []
        var used = 0
        for p in paragraphs {
            if !kept.isEmpty && used + p.count > budget { break }
            kept.append(p)
            used += p.count
        }
        let preview = kept.joined(separator: "\n\n")
        return preview.count > budget + 120 ? truncate(preview, limit: budget) : preview
    }

    /// `episodes` with every description flattened by `plainShowNotes`; empty notes become nil.
    static func withPlainShowNotes(_ episodes: [Episode]) -> [Episode] {
        episodes.map { ep in
            var ep = ep
            if let raw = ep.description {
                let clean = plainShowNotes(raw)
                ep.description = clean.isEmpty ? nil : clean
            }
            return ep
        }
    }

    private static let paragraphTags: Set<String> = [
        "p", "div", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "table", "tr", "hr", "section", "article", "header", "footer", "pre",
    ]

    private static func stripTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var i = s.startIndex
        var skippingUntil: String? = nil   // inside <script>/<style>: drop everything to its close
        while i < s.endIndex {
            let c = s[i]
            guard c == "<", let close = s[i...].firstIndex(of: ">") else {
                if skippingUntil == nil { out.append(c) }
                i = s.index(after: i)
                continue
            }
            let inner = s[s.index(after: i)..<close]
            let isClosing = inner.hasPrefix("/")
            let name = tagName(inner)
            // "a < b > c" isn't a tag: a real one starts with a letter, "/" or "!".
            guard !name.isEmpty || inner.hasPrefix("!") else {
                if skippingUntil == nil { out.append(c) }
                i = s.index(after: i)
                continue
            }
            if let target = skippingUntil {
                if isClosing && name == target { skippingUntil = nil }
            } else if name == "script" || name == "style" {
                if !isClosing { skippingUntil = name }
            } else if name == "br" {
                out.append("\n")
            } else if name == "li" {
                if !isClosing { out.append("\n• ") }
            } else if paragraphTags.contains(name) {
                out.append("\n\n")
            }
            i = s.index(after: close)
        }
        return out
    }

    /// Lowercased element name: letters and digits after an optional "/".
    private static func tagName(_ inner: Substring) -> String {
        var name = ""
        for ch in inner.drop(while: { $0 == "/" }) {
            guard ch.isASCII, ch.isLetter || ch.isNumber else { break }
            name.append(ch)
        }
        // A name must start with a letter ("<3" is a heart, not a tag).
        guard let first = name.first, first.isLetter else { return "" }
        return name.lowercased()
    }

    private static func looksLikeMarkup(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("</") || lower.contains("<p") || lower.contains("<br") || lower.contains("<a ")
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "bull": "\u{2022}",
        "middot": "\u{00B7}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "eacute": "\u{00E9}", "egrave": "\u{00E8}", "aacute": "\u{00E1}", "oacute": "\u{00F3}",
        "uuml": "\u{00FC}", "ouml": "\u{00F6}", "auml": "\u{00E4}", "ntilde": "\u{00F1}",
    ]

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            // An entity is short: look for its ";" within the next 10 characters only.
            if c == "&",
               let semi = s[i...].prefix(11).firstIndex(of: ";"),
               let decoded = entity(String(s[s.index(after: i)..<semi])) {
                out.append(decoded)
                i = s.index(after: semi)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func entity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value = digits.lowercased().hasPrefix("x")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return scalar == "\u{00A0}" ? " " : String(Character(scalar))
        }
        return namedEntities[body.lowercased()]
    }

    /// Collapse runs of spaces inside lines, trim each line, and keep at most one blank line
    /// between paragraphs.
    private static func normalizeWhitespace(_ s: String) -> String {
        let unified = s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        var lines: [String] = []
        var lastWasBlank = true   // drops leading blank lines
        for rawLine in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            if line.isEmpty {
                if !lastWasBlank { lines.append("") }
                lastWasBlank = true
            } else {
                lines.append(line)
                lastWasBlank = false
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        let head = s.prefix(limit)
        // Prefer ending on a whole paragraph, then a whole word, so the cut never lands mid-word.
        if let para = head.range(of: "\n\n", options: .backwards), head.distance(from: head.startIndex, to: para.lowerBound) > limit / 2 {
            return String(head[..<para.lowerBound]) + "\u{2026}"
        }
        if let space = head.lastIndex(of: " ") {
            return String(head[..<space]) + "\u{2026}"
        }
        return String(head) + "\u{2026}"
    }

    // MARK: - Counts and durations

    /// "1 episode", "750 episodes".
    static func episodeCount(_ n: Int) -> String {
        n == 1 ? "1 episode" : "\(n) episodes"
    }

    /// "1 show", "3 shows".
    static func showCount(_ n: Int) -> String {
        n == 1 ? "1 show" : "\(n) shows"
    }

    /// The library row's second line. Says the unplayed count only when it tells you something:
    /// "40 unplayed · 40" repeated the same number for every show you hadn't started.
    static func librarySubtitle(total: Int, unplayed: Int) -> String {
        guard total > 0 else { return "Tap to load episodes" }
        if unplayed == 0 { return "All caught up · \(episodeCount(total))" }
        if unplayed >= total { return episodeCount(total) }
        return "\(unplayed) unplayed of \(total)"
    }

    /// "1 hr 3 min", "42 min", "<1 min"; nil when the feed gave no length.
    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let total = Int(seconds)
        if total < 60 { return "<1 min" }
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }

    /// "23 min left", "1 hr 5 min left", "<1 min left"; nil when the length isn't known.
    static func timeLeft(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0, let text = duration(seconds) else { return nil }
        return text + " left"
    }

    /// The night ring's length as an adjective: "45-min", "1-hour", "1 hr 30 min".
    static func nightLabel(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)-min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)-hour" : "\(hours) hr \(rest) min"
    }

    /// A quiet note when what's left of an episode outlasts tonight's night ring. The timer still
    /// fades it out where the ring says; this only sets expectations. Sleep only, and never for
    /// All night (0). A minute of grace so a near-fit doesn't nag.
    static func nightCue(remaining: TimeInterval?, nightMinutes: Double, focusMode: Bool) -> String? {
        guard !focusMode, nightMinutes > 0, let remaining, remaining > nightMinutes * 60 + 60 else { return nil }
        return "Runs past your \(nightLabel(minutes: Int(nightMinutes))) night"
    }

    // MARK: - Show names

    /// True when a stored show name is a stand-in rather than the show's real title: empty, the
    /// generic "Podcast", or the feed's host name (a link added before its feed ever loaded showed
    /// up in the library as "feeds.simplecast.com"). Callers swap in the feed's title.
    static func isPlaceholderName(_ name: String, feedURL: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Podcast" { return true }
        guard let host = URL(string: feedURL)?.host?.lowercased() else { return false }
        let lower = trimmed.lowercased()
        return lower == host || "www." + lower == host || lower == host.replacingOccurrences(of: "www.", with: "")
    }
}
