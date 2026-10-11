import Foundation
import os

/// The settings backup: the user's mixes, podcasts, queue and settings as one JSON file, and the
/// restore that reads one back.
///
/// A restore is read → confirm → write. `read` parses and validates the file and says what's in it
/// without touching anything, so the person can confirm in their own terms ("4 mixes, 12 shows").
/// `restore` saves a snapshot of what's here first (`undoFile`), so a restore can be undone: it
/// replaces a curated library in one tap, and used to do it straight from the file picker.
enum Backup {

    /// How a restorable setting must look. A value of the wrong type, a non-finite number, a
    /// number outside its bounds, a fraction where a whole number is read, or an over-long string
    /// is skipped. "Most keys accept anything" let a hand-edited backup store a JSON null
    /// (UserDefaults raises an Objective-C exception on it that Swift can't catch: a crash after
    /// Replace), a volume of 1000 (past the Night Limiter's bound) or a skip of 1e300 (Int() traps
    /// in every view that shows it). The bounds are sanity bounds, wider than what Settings offers:
    /// they keep the readers from trapping or overdriving, not the UI's exact ranges.
    private enum Kind: Sendable { case bool, text, texts, number(ClosedRange<Double>), whole(ClosedRange<Double>) }

    /// Longest text setting (sound, scene and routing ids are short words) and the played list's
    /// limits (episode ids can be feed URLs), in UTF-8 bytes: a Character count let one letter
    /// carry any number of combining marks. Keeps a hand-edited file from parking megabytes in the
    /// preferences plist, which loads at every launch.
    nonisolated private static let maxTextBytes = 256
    nonisolated private static let maxListItems = 20_000
    nonisolated private static let maxListItemBytes = maxFeedFieldBytes
    nonisolated private static let maxListBytes = 1_000_000
    /// Longest id, title, address or name an episode or show may carry: the feed parser keeps
    /// 4,000 characters of a guid or title (PodcastParser), up to 16 KB in UTF-8. A restored
    /// episode or show over it is dropped; the app copies an episode's id and address into the
    /// preferences plist (the Last Night snapshot, the played list). The played list's items
    /// share it: at 2 KB a real guid was over the limit and the whole list was left out.
    nonisolated private static let maxFeedFieldBytes = 16_384

    /// The scalar UserDefaults settings a backup restores, and the shape of each. Single source of
    /// truth for both the export and the restore allowlist: restore writes nothing outside these,
    /// the encoded blobs (`encodedKeys`) and the file-backed collections below. Keep new persisted
    /// settings in sync here. `holdQueueDuringSleepTimer`, `finishedEpisodes` and the mode's last
    /// picks were missing until 2026-10, so a restore lost them.
    nonisolated private static let kinds: [String: Kind] = [
        "noiseVolume": .number(0...1), "binVolume": .number(0...1), "podVolume": .number(0...1),
        "masterVolume": .number(0...1), "stereoWidth": .number(0...1.5), "sleepEQIntensity": .number(0...2),
        "playbackSpeed": .number(0.25...4), "skipInterval": .number(1...300),
        "timerMinutes": .number(0...1440), "nightLengthMinutes": .number(0...1440),
        "ambientTailMinutes": .whole(0...1440),
        "pomoWork": .whole(1...600), "pomoRest": .whole(1...600), "pomoLongRest": .whole(1...600),
        "pomoCycles": .whole(1...100),
        "noiseType": .text, "binauralPreset": .text, "beatRouting": .text,
        "sceneSleep": .text, "sceneFocus": .text,
        "lastPick.noise.sleep": .text, "lastPick.noise.focus": .text,
        "lastPick.binaural.sleep": .text, "lastPick.binaural.focus": .text,
        "autoPlay": .bool, "shuffleQueue": .bool, "deleteOnCompletion": .bool, "hideFinishedEpisodes": .bool,
        "holdQueueDuringSleepTimer": .bool, "nightLimiterEnabled": .bool, "sleepEQEnabled": .bool,
        "limiterByMode": .bool, "bedtimeMode": .bool, "autoNightDim": .bool, "breathingOnRamp": .bool,
        "ambientMotion": .bool,
        "finishedEpisodes": .texts,
    ]

    /// The restorable scalar keys (`kinds`), in a stable order.
    nonisolated static let scalarKeys: [String] = kinds.keys.sorted()

    /// The mode, exported but never restored. The mode is where you are, not a setting: restoring
    /// a backup made in the other mode switched mode on the spot, cancelling a running sleep timer
    /// or Pomodoro. A backup's mode only decides which of its sounds belong to which mode
    /// (`restorePlan`). Always exported, even never written (someone who never switched modes has
    /// no key and is in Sleep), and read as Sleep when a backup predates it.
    nonisolated static let modeKey = "focusMode"

    /// Backup keys that map to StorageManager files (not UserDefaults). Each must decode into its
    /// Codable type before restore will write it (`validatedFileSection`).
    nonisolated static let fileBacked: [String: String] = [
        "savedPlaylists": "mixes.json",
        "savedPodcasts": "library.json",
        "upNextQueue": "queue.json",
        "episodePositions": "positions.json"
    ]

    /// Keys whose UserDefaults value is a Data-encoded Codable blob, not a plain scalar. Data can't
    /// go through JSON, so these expand to a nested JSON object on export and are re-encoded on
    /// import. `extraLayers` was in NEITHER list until 2026-07: the extra mixer layers were
    /// silently dropped from every backup and lost on restore.
    nonisolated static let encodedKeys: [String] = ["lastMix", "extraLayers"]

    /// Marks a file as a Sleepulator backup, and when it was made (seconds since 1970). Never
    /// written to defaults. Backups from before 2026-10 have neither and still restore.
    nonisolated static let markerKey = "sleepulatorBackup"
    nonisolated static let exportedAtKey = "exportedAt"

    /// What was here before the last restore, which Undo puts back.
    nonisolated static let undoFile = "before-restore.json"
    /// In the Undo copy only: the backup keys it couldn't hold (a stored value JSON can't carry,
    /// a file neither of whose copies parses). Undo leaves those as they are; treating them as
    /// absent removed the setting or wrote [] over the file.
    nonisolated static let undoLeftOutKey = "undoLeftOut"
    /// When that snapshot was taken (seconds since 1970). Its own key so the Backup rows needn't
    /// parse a library-sized file to decide whether to offer Undo. Deliberately not backed up.
    nonisolated static let undoTakenAtKey = "restoreUndoTakenAt"
    /// When an Undo that couldn't save every file last ran (`UndoResult.incomplete`). The copy is
    /// then the only place what it couldn't save still is, so the week starts again from here;
    /// it expired on the restore's clock and was thrown away with no word.
    nonisolated static let undoKeptAtKey = "restoreUndoKeptAt"
    /// How long Undo is offered. Past a week it would roll back everything since, which nobody
    /// reaching for "undo" means.
    nonisolated static let undoWindow: TimeInterval = 7 * 24 * 3600

    // MARK: What a backup holds

    /// A backup's recognisable contents, for the confirm and the result. nil counts mean the
    /// section is absent (a restore leaves that part alone); 0 means it's there and empty (a
    /// restore empties it, which the confirm must say).
    nonisolated struct Contents: Equatable, Sendable {
        var mixes: Int?
        var shows: Int?
        var upNext: Int?
        var positions = false
        var settings = false
        var exportedAt: Date?

        /// Record a file-backed section (a backup key) as restored with `count` items, or as not
        /// restored when nil. One place maps the keys, for `prepare` and `write` alike.
        nonisolated mutating func record(_ key: String, count: Int?) {
            switch key {
            case "savedPlaylists":   mixes = count
            case "savedPodcasts":    shows = count
            case "upNextQueue":      upNext = count
            case "episodePositions": positions = count != nil
            default:                 assertionFailure("\(key) isn't a file-backed section")
            }
        }

        nonisolated var restoresAnything: Bool {
            mixes != nil || shows != nil || upNext != nil || positions || settings
        }
    }

    /// A read, validated backup awaiting the person's confirm. Holds the file's bytes (Sendable),
    /// not the parsed dictionary; the write re-parses them off the main thread.
    struct Pending: Sendable {
        let data: Data
        let contents: Contents
    }

    /// What a restore wrote. `skipped` counts sections that weren't recognised or didn't validate;
    /// `unwritten` names the sections (backup keys) whose files couldn't be saved, which were left
    /// as they were and aren't in `contents`.
    struct Outcome: Sendable {
        let contents: Contents
        let skipped: Int
        var unwritten: [String] = []
    }

    /// How an Undo went. `incomplete`: some files couldn't be saved (a full disk), so the copy is
    /// kept and Undo is still offered; the rest was put back.
    enum UndoResult: Equatable, Sendable { case undone, gone, incomplete(unwritten: [String]) }

    enum ReadFailure: Error, Equatable, Sendable { case noAccess, unreadable, tooLarge, notBackup }

    /// A backup made for saving, and the sections it couldn't include: backup keys whose file is
    /// there but neither copy parses (`StorageManager.rawData`).
    struct Export: Sendable {
        let data: Data
        let leftOut: [String]
    }

    /// The backup would be over `maxFileBytes` even written compactly, so a restore would refuse it.
    enum ExportFailure: Error, Equatable, Sendable { case tooLarge }

    /// No backup is this big (a library with show notes can run to tens of MB). JSON expands
    /// many times over as it's parsed, so a crafted file near this size could get the app killed
    /// for memory before anything was checked; 50 MB halves that worst case.
    nonisolated static let maxFileBytes = 50 * 1024 * 1024
    /// `maxFileBytes` as the alerts say it.
    nonisolated static let maxFileMB = maxFileBytes / (1024 * 1024)

    /// Decode a file-backed section into the Codable type its file expects, count its items, and
    /// encode what decoded. The decoded value is what's stored, never the backup's own JSON: the
    /// decoder ignores keys it doesn't know, so a hand-edited section could carry any amount of
    /// junk past the check. nil if the section is malformed or unexpected.
    ///
    /// `encode: false` only counts (the read's confirm): `data` is then empty. The write encodes.
    nonisolated static func validatedFileSection(key: String, value: Any, encode: Bool = true,
                                                 now: Date = Date()) -> (data: Data, count: Int)? {
        guard let data = jsonData(value) else { return nil }
        let decoder = JSONDecoder()
        func encoded<T: Encodable>(_ value: T, count: Int) -> (data: Data, count: Int)? {
            guard encode else { return (Data(), count) }
            return (try? JSONEncoder().encode(value)).map { ($0, count) }
        }
        /// An episode as restore keeps it: dropped when a text is over `maxFeedFieldBytes`, its
        /// date dropped when it couldn't be real.
        func kept(_ episode: Episode) -> Episode? {
            guard fits([episode.id, episode.title, episode.audioUrl, episode.artworkUrl], within: maxFeedFieldBytes) else { return nil }
            var episode = episode
            episode.pubDate = plausibleDate(episode.pubDate, now: now)
            return episode
        }
        func kept(_ show: Podcast) -> Podcast? {
            guard fits([show.id, show.name, show.url, show.artworkUrl], within: maxFeedFieldBytes) else { return nil }
            var show = show
            show.episodes = show.episodes.compactMap(kept)
            return show
        }
        switch key {
        case "savedPlaylists":   // current schema is [SoundPreset]; older backups are [SavedMix]
            if let presets = try? decoder.decode([SoundPreset].self, from: data) {
                let kept = presets.compactMap(sanitized)
                return encoded(kept, count: kept.count)
            }
            if let mixes = try? decoder.decode([SavedMix].self, from: data) {
                let kept = mixes.compactMap(sanitizedLegacyPreset)
                return encoded(kept, count: kept.count)
            }
            return nil
        case "savedPodcasts":
            guard let shows = try? decoder.decode([Podcast].self, from: data) else { return nil }
            let keptShows = shows.compactMap(kept)
            return encoded(keptShows, count: keptShows.count)
        case "upNextQueue":
            guard let queue = try? decoder.decode([Episode].self, from: data) else { return nil }
            let keptQueue = queue.compactMap(kept)
            return encoded(keptQueue, count: keptQueue.count)
        case "episodePositions":
            guard let places = try? decoder.decode([String: Double].self, from: data) else { return nil }
            return encoded(places.mapValues(clampedPosition), count: places.count)
        default:
            return nil
        }
    }

    /// The furthest a saved place in an episode can be, in seconds (about 11 days): a sanity
    /// bound, like `kinds`'s. A place of 1e300 traps in the time readouts' `Int(seconds)`.
    nonisolated static let maxPosition: Double = 1_000_000

    nonisolated private static func clampedPosition(_ seconds: Double) -> Double {
        min(max(seconds, 0), maxPosition)
    }

    nonisolated private static func unitClamped(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// A date a backup could really hold: from 1970 to a year from now. The show list and Up Next
    /// format and sort episodes by it; a hand-edited 1e300 went through them unchecked, as the
    /// export time did.
    nonisolated private static func plausibleDate(_ date: Date?, now: Date) -> Date? {
        guard let date, (0...now.addingTimeInterval(365 * 86_400).timeIntervalSince1970).contains(date.timeIntervalSince1970)
        else { return nil }
        return date
    }

    /// Whether every text fits a limit in UTF-8 bytes (the settings' `maxTextBytes` by default).
    nonisolated private static func fits(_ texts: [String?], within limit: Int = maxTextBytes) -> Bool {
        texts.allSatisfy { ($0?.utf8.count ?? 0) <= limit }
    }

    /// A restored preset as the engine can play it, or nil when a text is over the settings'
    /// limit. Tapping a preset writes its sounds and scene into the preferences plist, so a
    /// padded one carried any amount of text there, the same hole `lastMix` had.
    nonisolated static func sanitized(_ preset: SoundPreset) -> SoundPreset? {
        var preset = preset
        preset.extraLayers = preset.extraLayers.map(sanitized)
        let layerTexts: [String?] = (preset.extraLayers ?? []).flatMap { [$0.id, $0.type] }
        guard fits([preset.id, preset.name, preset.mode, preset.noiseType, preset.binauralPreset, preset.sceneId] + layerTexts)
        else { return nil }
        preset.noiseVolume = unitClamped(preset.noiseVolume)
        preset.binVolume = unitClamped(preset.binVolume)
        return preset
    }

    /// An older backup's preset (a `SavedMix`), bounded the same way. Its podcast never belonged
    /// in a reusable recipe and is dropped when MixStore converts it, so it's dropped here.
    nonisolated private static func sanitizedLegacyPreset(_ mix: SavedMix) -> SavedMix? {
        var mix = sanitized(mix)
        mix.podcastUrl = nil
        mix.podcastId = nil
        mix.podcastPosition = nil
        let layerTexts: [String?] = (mix.extraLayers ?? []).flatMap { [$0.id, $0.type] }
        return fits([mix.id, mix.name, mix.noiseType, mix.binauralPreset] + layerTexts) ? mix : nil
    }

    /// The extra mixer layers as the engine can play them: no more than it stacks, at a volume it
    /// takes. A million layers decoded fine and went into the preferences plist whole.
    nonisolated static func sanitized(_ layers: [ExtraNoiseLayer]) -> [ExtraNoiseLayer] {
        layers.prefix(AudioEngine.maxExtraLayers).map { var layer = $0; layer.volume = unitClamped(layer.volume); return layer }
    }

    /// The Last Night snapshot with its volumes, place and layers inside what the engine reads.
    nonisolated static func sanitized(_ mix: SavedMix) -> SavedMix {
        var mix = mix
        mix.noiseVolume = unitClamped(mix.noiseVolume)
        mix.binVolume = unitClamped(mix.binVolume)
        mix.podVolume = unitClamped(mix.podVolume)
        mix.podcastPosition = mix.podcastPosition.map(clampedPosition)
        mix.extraLayers = mix.extraLayers.map(sanitized)
        return mix
    }

    /// Whether a restorable scalar's value has the shape its reader expects (`kinds`). The
    /// property-list check comes first: it refuses NSNull anywhere in the value without raising.
    nonisolated private static func scalarValid(key: String, value: Any) -> Bool {
        guard let kind = kinds[key], PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
            return false
        }
        switch kind {
        case .bool:
            return value is Bool
        case .text:
            guard let text = value as? String else { return false }
            return text.utf8.count <= maxTextBytes
        case .texts:
            guard let list = value as? [String], list.count <= maxListItems else { return false }
            var total = 0
            for item in list {
                let bytes = item.utf8.count
                guard bytes <= maxListItemBytes else { return false }
                total += bytes
            }
            return total <= maxListBytes
        case .number(let range), .whole(let range):
            guard !(value is String), let n = value as? NSNumber else { return false }
            let x = n.doubleValue
            guard x.isFinite, range.contains(x) else { return false }
            // A reader of a whole number (`as? Int`, `integer(forKey:)`) falls back or truncates.
            if case .whole = kind { return x.rounded() == x }
            return true
        }
    }

    /// Re-encode a parsed section. A section that isn't an array or object (a string where the
    /// show list should be) makes JSONSerialization raise an Objective-C exception that `try?`
    /// can't catch, which crashed the app on a hand-edited backup, so it's refused first.
    nonisolated private static func jsonData(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [])
    }

    /// Longest a Data-encoded blob may be once re-encoded. The Last Night snapshot is a few
    /// hundred bytes (an episode URL is the longest part); a padded name or id is refused here.
    nonisolated private static let maxEncodedBytes = 16 * 1024

    /// A Data-encoded blob as restore stores it: decoded into its type, trimmed and clamped
    /// (`sanitized`), and encoded again, within `maxEncodedBytes`. Storing the backup's own JSON
    /// once it decoded let a hand-edited `lastMix` carry a 40 MB junk field (the decoder ignores
    /// unknown keys) into the preferences plist, which loads at every launch.
    nonisolated private static func encodedValue(key: String, value: Any) -> Data? {
        guard let data = jsonData(value) else { return nil }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let encoded: Data?
        switch key {
        case "lastMix":
            encoded = (try? decoder.decode(SavedMix.self, from: data)).flatMap { try? encoder.encode(sanitized($0)) }
        case "extraLayers":
            encoded = (try? decoder.decode([ExtraNoiseLayer].self, from: data)).flatMap { try? encoder.encode(sanitized($0)) }
        default:
            encoded = nil
        }
        guard let encoded, encoded.count <= maxEncodedBytes else { return nil }
        return encoded
    }

    /// What a parsed backup would restore, without writing anything (the same `prepare` the
    /// write uses, so the confirm and the result can't disagree).
    nonisolated static func contents(of dict: [String: Any], now: Date = Date()) -> Contents {
        prepare(dict, currentFocus: false, now: now, encodeFiles: false).contents
    }

    // MARK: Copy (pure, unit-tested)

    /// "no mixes" / "1 mix" / "4 mixes".
    nonisolated static func counted(_ n: Int, _ singular: String, _ plural: String) -> String {
        switch n {
        case 0:  return "no \(plural)"
        case 1:  return "1 \(singular)"
        default: return "\(n) \(plural)"
        }
    }

    /// "a", "a and b", "a, b and c": the app's list style (no serial comma).
    nonisolated static func joined(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }

    /// The contents as a phrase list; `settings` names the settings ("settings", "your settings").
    nonisolated static func phrases(_ c: Contents, settings: String) -> [String] {
        var parts: [String] = []
        if let n = c.mixes { parts.append(counted(n, "mix", "mixes")) }
        if let n = c.shows { parts.append(counted(n, "show", "shows")) }
        if let n = c.upNext { parts.append(counted(n, "episode", "episodes") + " in Up Next") }
        if c.settings { parts.append(settings) }
        return parts
    }

    /// The year only when it isn't this one: on the same date a year later, a year-old backup
    /// read like today's at the moment of replacing everything.
    nonisolated static func confirmTitle(_ c: Contents, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = c.exportedAt else { return "Replace with this backup?" }
        let style: Date.FormatStyle = calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year()
        return "Replace with the backup from \(date.formatted(style))?"
    }

    nonisolated static func confirmMessage(_ c: Contents) -> String {
        let parts = phrases(c, settings: "settings")
        let what = parts.isEmpty ? "the backup's saved places in episodes" : "the backup's " + joined(parts)
        return "This replaces what's on this iPhone with \(what). You can undo it afterwards."
    }

    /// When the copy of what's here can't be saved, the restore stops: the confirm promised Undo.
    nonisolated static let noSnapshotMessage = "Couldn't save a copy of what's on this iPhone first, so nothing was replaced."

    nonisolated static func restoredMessage(_ o: Outcome) -> String {
        let parts = phrases(o.contents, settings: "your settings")
        var message = !parts.isEmpty ? "Restored \(joined(parts))."
            : o.contents.positions ? "Restored where you'd got to in each episode." : "Nothing could be restored."
        if !o.unwritten.isEmpty {
            message += " Your \(joined(names(o.unwritten))) couldn't be saved on this iPhone and weren't changed."
        }
        if o.skipped > 0 { message += " A few parts of the file weren't recognised and were left as they were." }
        return message
    }

    nonisolated static func failureMessage(_ failure: ReadFailure) -> String {
        switch failure {
        case .noAccess:   return "Couldn't open that file. Pick it again from Files; if it's in iCloud, let it download first."
        case .unreadable: return "Couldn't read that file. Pick it again from Files; if it's in iCloud, let it download first."
        case .tooLarge:   return "That file is too big to restore. A backup can be up to \(maxFileMB) MB."
        case .notBackup:  return "That isn't a Sleepulator backup. Make one with Export a backup."
        }
    }

    /// Export couldn't fit under the size a restore reads (`ExportFailure.tooLarge`). Show notes
    /// are what makes a library big.
    nonisolated static let tooLargeToExportMessage =
        "Your podcast library is too big for one backup file (over \(maxFileMB) MB). Remove shows you no longer listen to, then try again."

    /// The file-backed sections as a person names them, in the order they're listed.
    nonisolated static let sectionNames: [(key: String, name: String)] = [
        ("savedPlaylists", "mixes"), ("savedPodcasts", "podcasts"), ("upNextQueue", "Up Next"),
        ("episodePositions", "places in episodes"),
    ]

    nonisolated private static func names(_ keys: [String]) -> [String] {
        sectionNames.filter { keys.contains($0.key) }.map(\.name)
    }

    /// The sections an export left out (`Export.leftOut`), named for a person; nil when none were.
    nonisolated static func leftOutMessage(_ keys: [String]) -> String? {
        let names = names(keys)
        guard !names.isEmpty else { return nil }
        return "It was saved without your \(joined(names)), which couldn't be read. Everything else is in it."
    }

    /// An Undo that couldn't save every file (`UndoResult.incomplete`). The copy is kept.
    nonisolated static func undoIncompleteMessage(_ keys: [String]) -> String {
        "Your \(joined(names(keys))) couldn't be saved on this iPhone, so they weren't put back yet. Free up some space, then tap Undo the restore again."
    }

    /// Whether Undo is still offered for a snapshot taken at `takenAt`. A snapshot from the
    /// future (the clock set back since, or the stored time rounding a hair past now) is still
    /// offered, up to a week ahead: refusing it threw the snapshot away, and with it the only way
    /// back. Further ahead is no clock correction, and unbounded it kept a library-sized copy on
    /// disk until that date came round.
    nonisolated static func undoAvailable(takenAt: Date?, now: Date) -> Bool {
        guard let takenAt else { return false }
        return abs(now.timeIntervalSince(takenAt)) < undoWindow
    }

    /// "sleepulator-backup-2026-10-11": dated, so a second export doesn't overwrite the first.
    /// Always in Gregorian years: under the Japanese calendar the device's own named it
    /// "sleepulator-backup-0008-10-11". Only `calendar`'s time zone is read.
    nonisolated static func filename(for date: Date, prefix: String = "sleepulator-backup",
                                     calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return prefix + String(format: "-%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: UserDefaults halves (pure + parameterized on `defaults`, unit-tested)

    /// The UserDefaults side of an export: scalar settings + the Data-encoded blobs, ready to merge
    /// into the backup dictionary. The shipping export calls this too, so the test covers the real
    /// path.
    nonisolated static func userDefaults(from defaults: UserDefaults) -> [String: Any] {
        var out: [String: Any] = [:]
        // Only what a restore would take back (`kinds`). One stored NaN or wrong-typed value made
        // JSONSerialization refuse the whole export. (The Undo copy has its own builder,
        // `undoUserDefaults`.) A text list keeps what fits: one over-long id left out the whole
        // played list.
        for key in scalarKeys {
            guard var v = defaults.object(forKey: key) else { continue }
            if case .texts? = kinds[key], let list = v as? [String] { v = fittingList(list) }
            if scalarValid(key: key, value: v) { out[key] = v }
        }
        out[modeKey] = defaults.bool(forKey: modeKey)
        for key in encodedKeys {
            if let data = defaults.data(forKey: key),
               let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) {
                out[key] = obj
            }
        }
        return out
    }

    /// The UserDefaults side of the Undo copy: every restorable setting as it's stored, and the
    /// keys it couldn't hold (`undoLeftOutKey`). The restore's `kinds` bounds don't apply: these
    /// are the app's own values (a played list holding one long episode id is one), and the export
    /// leaving one out meant Undo removed it.
    nonisolated static func undoUserDefaults(from defaults: UserDefaults) -> (values: [String: Any], leftOut: [String]) {
        var out: [String: Any] = [modeKey: defaults.bool(forKey: modeKey)]
        var leftOut: [String] = []
        for key in scalarKeys {
            guard let v = defaults.object(forKey: key) else { continue }
            // The copy is JSON: a value it can't carry (a NaN) is left out, and left alone.
            if PropertyListSerialization.propertyList(v, isValidFor: .binary), JSONSerialization.isValidJSONObject([v]) {
                out[key] = v
            } else {
                leftOut.append(key)
            }
        }
        for key in encodedKeys {
            guard defaults.object(forKey: key) != nil else { continue }
            if let data = defaults.data(forKey: key),
               let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) {
                out[key] = obj
            } else {
                leftOut.append(key)
            }
        }
        return (out, leftOut)
    }

    /// A text list cut to what a restore takes: over-long items dropped, then the oldest (the
    /// played list is in recency order, newest last) until it's within the count and size.
    nonisolated private static func fittingList(_ list: [String]) -> [String] {
        let kept = list.filter { $0.utf8.count <= maxListItemBytes }
        var total = kept.reduce(0) { $0 + $1.utf8.count }
        var start = 0
        while start < kept.count, kept.count - start > maxListItems || total > maxListBytes {
            total -= kept[start].utf8.count
            start += 1
        }
        return Array(kept[start...])
    }

    /// What a restore would write to UserDefaults: the allowlisted scalars that validate, the
    /// Data blobs re-encoded, and `absent`, the restorable keys the dictionary lacks (Undo removes
    /// those). Anything else counts as skipped; file-backed keys, the marker and the export-only
    /// mode are passed over without counting. Pure, so it runs off the main thread.
    ///
    /// A backup made in the other mode (`currentFocus` differs from its `focusMode`): its current
    /// sounds are that mode's latest picks, and this mode's sounds are its remembered picks, the
    /// same memory a mode switch keeps (`AudioEngine.pickKey`).
    ///
    /// `trusted` (Undo, from its own copy): an allowlisted setting comes back as it was stored,
    /// held only to being a property-list value, and a key the copy left out is neither written
    /// nor removed.
    nonisolated static func restorePlan(from dict: [String: Any], currentFocus: Bool, trusted: Bool = false)
        -> (values: [String: Any], absent: [String], skipped: Int) {
        var values: [String: Any] = [:]
        var skipped = 0
        for (key, value) in dict {
            if fileBacked[key] != nil || key == markerKey || key == exportedAtKey || key == modeKey || key == undoLeftOutKey {
                continue
            } else if encodedKeys.contains(key) {
                if let encoded = trusted ? jsonData(value) : encodedValue(key: key, value: value) {
                    values[key] = encoded
                } else {
                    skipped += 1
                }
            } else if trusted ? kinds[key] != nil && PropertyListSerialization.propertyList(value, isValidFor: .binary)
                              : scalarValid(key: key, value: value) {
                values[key] = value
            } else {
                skipped += 1                                   // unknown or malformed: never blind-write
            }
        }
        let backupFocus = dict[modeKey] as? Bool ?? false
        if backupFocus != currentFocus {
            for (kind, currentKey) in [("noise", "noiseType"), ("binaural", "binauralPreset")] {
                if let sound = values[currentKey] { values[AudioEngine.pickKey(kind, focus: backupFocus)] = sound }
                values[currentKey] = values[AudioEngine.pickKey(kind, focus: currentFocus)]   // none: keep today's sound
            }
        }
        // Absent: not in the backup and not written by the remap (Undo removing a pick it had
        // just written lost the other mode's remembered sound), nor left out of an Undo copy.
        let leftOut = trusted ? Set(dict[undoLeftOutKey] as? [String] ?? []) : []
        let absent = (scalarKeys + encodedKeys).filter { dict[$0] == nil && values[$0] == nil && !leftOut.contains($0) }
        return (values, absent, skipped)
    }

    /// Write a plan's values; `replacing` (Undo) also removes its absent keys, so a snapshot comes
    /// back exactly. On the main actor in the app: @AppStorage observers fire on the writing thread.
    nonisolated static func apply(_ values: [String: Any], absent: [String], into defaults: UserDefaults,
                                  replacing: Bool) {
        for (key, value) in values { defaults.set(value, forKey: key) }
        if replacing { absent.forEach { defaults.removeObject(forKey: $0) } }
    }

    /// The UserDefaults side of a restore in one call: `restorePlan` then `apply`, the two steps
    /// `write` runs (with a hand-off between threads in between). A test convenience; the
    /// app's restore goes through `write`. Returns (restored, skipped) for the UserDefaults keys.
    nonisolated static func restoreUserDefaults(from dict: [String: Any], into defaults: UserDefaults,
                                                replacing: Bool = false) -> (restored: Int, skipped: Int) {
        // Replacing is Undo, which trusts its own copy (`write` does the same).
        let plan = restorePlan(from: dict, currentFocus: defaults.bool(forKey: modeKey), trusted: replacing)
        apply(plan.values, absent: plan.absent, into: defaults, replacing: replacing)
        return (plan.values.count, plan.skipped)
    }

    /// The whole backup dictionary: defaults, the file-backed collections' JSON, and the marker.
    nonisolated static func exportDictionary(defaults: UserDefaults, files: [String: Data], at date: Date) -> [String: Any] {
        adding(files: files, at: date, to: userDefaults(from: defaults))
    }

    /// The Undo copy's dictionary: every setting as stored (`undoUserDefaults`), the files, and
    /// what it couldn't hold, the unreadable files (`unread`) included.
    nonisolated static func undoDictionary(defaults: UserDefaults, files: [String: Data], unread: [String],
                                           at date: Date) -> [String: Any] {
        let settings = undoUserDefaults(from: defaults)
        var dict = adding(files: files, at: date, to: settings.values)
        dict[undoLeftOutKey] = settings.leftOut + unread
        return dict
    }

    nonisolated private static func adding(files: [String: Data], at date: Date, to settings: [String: Any]) -> [String: Any] {
        var dict = settings
        for (key, file) in fileBacked {
            if let data = files[file],
               let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) {
                dict[key] = obj
            }
        }
        dict[markerKey] = 1
        dict[exportedAtKey] = date.timeIntervalSince1970
        return dict
    }

    // MARK: I/O

    // The I/O below takes the store and defaults as parameters (the shared ones by default) so
    // the restore → undo round trip is tested against a temp store, never the app's own data.

    /// The file-backed collections as they are on disk (a parseable copy of each, `rawData`), and
    /// the backup keys of those that are there but couldn't be read. Call after `storage.flush()`.
    nonisolated private static func currentFiles(_ storage: StorageManager) -> (files: [String: Data], leftOut: [String]) {
        var files: [String: Data] = [:]
        var leftOut: [String] = []
        for (key, file) in fileBacked {
            if let data = storage.rawData(for: file) {
                files[file] = data
            } else if storage.exists(file) {
                leftOut.append(key)
            }
        }
        return (files, leftOut.sorted())
    }

    /// A backup of everything here now, read and serialized off the main thread (a large library
    /// would otherwise stall the UI), after any queued writes land.
    ///
    /// `maxBytes`, for a backup someone saves: the most a restore will read (`maxFileBytes`).
    /// Pretty-printed when that fits, compact when only that does, refused (`ExportFailure`)
    /// when neither does: a file a restore refuses is no backup. The restore's own Undo copy
    /// passes none; it's never read through `read`.
    ///
    /// `undoCopy`: the restore's copy of what's here (`undoDictionary`), which keeps every setting
    /// as stored rather than what a restore would take.
    static func exportData(at date: Date = Date(), storage: StorageManager = .shared,
                           defaults: UserDefaults = .standard, pretty: Bool = true,
                           maxBytes: Int? = nil, undoCopy: Bool = false) async throws -> Export {
        storage.flush()
        return try await Task.detached(priority: .userInitiated) {
            let current = currentFiles(storage)
            let dict = undoCopy
                ? undoDictionary(defaults: defaults, files: current.files, unread: current.leftOut, at: date)
                : exportDictionary(defaults: defaults, files: current.files, at: date)
            // Refuse rather than raise: a non-JSON value would throw an uncatchable exception.
            guard JSONSerialization.isValidJSONObject(dict) else { throw CocoaError(.coderInvalidValue) }
            var data = try JSONSerialization.data(withJSONObject: dict, options: pretty ? .prettyPrinted : [])
            if let maxBytes, data.count > maxBytes {
                if pretty {
                    data = Data()       // let the pretty bytes go first: this is the largest library
                    data = try JSONSerialization.data(withJSONObject: dict, options: [])
                }
                guard data.count <= maxBytes else { throw ExportFailure.tooLarge }
            }
            return Export(data: data, leftOut: current.leftOut)
        }.value
    }

    /// Read and validate a picked file. Writes nothing.
    static func read(_ url: URL) async -> Result<Pending, ReadFailure> {
        await Task.detached(priority: .userInitiated) { () -> Result<Pending, ReadFailure> in
            // Whether iOS grants a scope varies: a file in the app's own container needs none and
            // can return false here (the simulator returns true even for a temp file), so only
            // a failed read counts as no access.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // The size check refuses a big file before reading it; the bounded read holds the cap
            // even when the size can't be read (or the file grew in between).
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxFileBytes {
                return .failure(.tooLarge)
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure(scoped ? .unreadable : .noAccess) }
            defer { try? handle.close() }
            // `try?` would fold "nothing to read" (an empty file) into a read failure.
            let data: Data
            do { data = try handle.read(upToCount: maxFileBytes + 1) ?? Data() } catch { return .failure(.unreadable) }
            guard data.count <= maxFileBytes else { return .failure(.tooLarge) }
            guard let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                return .failure(.notBackup)
            }
            let contents = contents(of: dict)
            guard contents.restoresAnything else { return .failure(.notBackup) }
            return .success(Pending(data: data, contents: contents))
        }.value
    }

    /// Write a confirmed backup, or nil if nothing was replaced. Snapshots what's here first, so
    /// Undo can put it back even if the write goes wrong part-way; when that copy can't be saved,
    /// the restore stops (the confirm promised Undo). The caller reloads the engine afterwards.
    ///
    /// `settle` lands the writes the app still has queued (`AudioEngine.flushPendingWrites`). It
    /// runs before the copy, so the copy holds them, and again just before the restore writes,
    /// so none lands on top of it.
    static func restore(_ pending: Pending, now: Date = Date(), storage: StorageManager = .shared,
                        defaults: UserDefaults = .standard, settle: () -> Void = {}) async -> Outcome? {
        settle()
        // The copy is written atomically before anything is replaced. When it can't be saved the
        // restore replaces nothing and the previous Undo stays as it was (file and date): nothing
        // changed, so it still describes a real earlier state.
        // Written off the main thread: it's library-sized, and nothing else writes this file.
        guard let snapshot = try? await exportData(at: now, storage: storage, defaults: defaults, pretty: false, undoCopy: true),
              (try? await Task.detached(priority: .userInitiated, operation: { try storage.writeRawNow(snapshot.data, to: undoFile) }).value) != nil
        else {
            return nil
        }
        defaults.set(now.timeIntervalSince1970, forKey: undoTakenAtKey)
        defaults.removeObject(forKey: undoKeptAtKey)          // a new copy, a new week
        let written = await write(pending.data, replacing: false, storage: storage, defaults: defaults, settle: settle)
        return Outcome(contents: written.contents, skipped: written.skipped, unwritten: written.unwritten)
    }

    /// When the snapshot Undo would put back was taken, if it's still offered. Clears an expired
    /// one, so a month-old library never sits in Application Support waiting to be "undone" to.
    static func undoDate(now: Date = Date(), storage: StorageManager = .shared,
                         defaults: UserDefaults = .standard) -> Date? {
        let seconds = defaults.object(forKey: undoTakenAtKey) as? Double
        let takenAt = seconds.map { Date(timeIntervalSince1970: $0) }
        let keptAt = (defaults.object(forKey: undoKeptAtKey) as? Double).map { Date(timeIntervalSince1970: $0) }
        if takenAt != nil, undoAvailable(takenAt: takenAt, now: now) || undoAvailable(takenAt: keptAt, now: now) {
            return takenAt
        }
        if takenAt != nil { discardUndo(storage, defaults) }
        return nil
    }

    /// Put back what was here before the last restore, exactly: Undo trusts its own copy (`write`'s
    /// `replacing`). `gone` if there's nothing to put back; a copy that's gone or unreadable is
    /// discarded too, so Undo stops being offered. `incomplete` when a file couldn't be saved: the
    /// copy is kept, so Undo can run again. It used to be thrown away whatever happened, with
    /// "back as they were" over a library a full disk had kept from coming back.
    /// `settle` runs just before the writes, as in `restore`.
    static func undo(now: Date = Date(), storage: StorageManager = .shared,
                     defaults: UserDefaults = .standard, settle: () -> Void = {}) async -> UndoResult {
        storage.flush()
        guard undoDate(now: now, storage: storage, defaults: defaults) != nil else { return .gone }
        // Read (and parsed, to fall back to the `.bak`) off the main thread: it's library-sized.
        guard let data = await Task.detached(priority: .userInitiated, operation: { storage.rawData(for: undoFile) }).value else {
            discardUndo(storage, defaults)
            return .gone
        }
        let written = await write(data, replacing: true, storage: storage, defaults: defaults, settle: settle)
        guard written.parsed else {
            discardUndo(storage, defaults)
            return .gone
        }
        guard written.unwritten.isEmpty else {
            defaults.set(now.timeIntervalSince1970, forKey: undoKeptAtKey)
            return .incomplete(unwritten: written.unwritten)
        }
        discardUndo(storage, defaults)
        storage.flush()
        return .undone
    }

    private static func discardUndo(_ storage: StorageManager, _ defaults: UserDefaults) {
        storage.delete(filename: undoFile)
        defaults.removeObject(forKey: undoTakenAtKey)
        defaults.removeObject(forKey: undoKeptAtKey)
    }

    /// The settings plan, handed from the detached task to the main actor. Unchecked: every value
    /// is an immutable property-list value that passed `propertyList(_:isValidFor:)`.
    nonisolated private struct PlanValues: @unchecked Sendable { let values: [String: Any] }

    /// The validated writes a backup asks for, worked out off the main thread (Sendable, so the
    /// detached task can hand it back).
    nonisolated private struct Prepared: Sendable {
        var files: [String: Data] = [:]      // filename → bytes
        var absentFiles: [String] = []       // files a replacing write empties
        var settings: PlanValues?            // the UserDefaults plan
        var absentKeys: [String] = []
        var contents = Contents()
        var skipped = 0
    }

    /// Validate a parsed backup once: each file-backed section, the settings plan, and what it
    /// all amounts to (`contents`). The read's confirm and the write both come here.
    ///
    /// `trusted` (Undo, from its own copy): a file section is written back as the copy has it,
    /// even one today's types can't decode (a schema change PersistenceMigrator leaves on disk
    /// for a fixed build), and a section the copy couldn't read is left alone. `encodeFiles:
    /// false` only counts (the read's confirm).
    nonisolated private static func prepare(_ dict: [String: Any], currentFocus: Bool, now: Date,
                                            trusted: Bool = false, encodeFiles: Bool = true) -> Prepared {
        var p = Prepared()
        let leftOut = trusted ? Set(dict[undoLeftOutKey] as? [String] ?? []) : []
        for (key, file) in fileBacked where !leftOut.contains(key) {
            guard let value = dict[key] else { p.absentFiles.append(file); continue }
            if trusted {
                if let data = jsonData(value) { p.files[file] = data } else { p.skipped += 1 }
                continue
            }
            guard let section = validatedFileSection(key: key, value: value, encode: encodeFiles, now: now) else {
                p.skipped += 1
                continue
            }
            p.files[file] = section.data
            p.contents.record(key, count: section.count)
        }
        let plan = restorePlan(from: dict, currentFocus: currentFocus, trusted: trusted)
        p.absentKeys = plan.absent
        p.skipped += plan.skipped
        // When it was made, if that's a time it could have been: from 1970 to a day from now
        // (a clock that ran a little fast). The confirm's title formats it, and a hand-edited
        // 1e300 went through Calendar and the date formatter unchecked.
        if let seconds = dict[exportedAtKey] as? Double,
           (0...now.addingTimeInterval(86_400).timeIntervalSince1970).contains(seconds) {
            p.contents.exportedAt = Date(timeIntervalSince1970: seconds)
        }
        if !plan.values.isEmpty {
            p.settings = PlanValues(values: plan.values)
            p.contents.settings = true
        }
        return p
    }

    /// Empty values for a replacing write's absent files. Written, not deleted: a view that holds
    /// the collection (LibraryView's shows) ignores a missing file, kept what the restore brought
    /// in and saved it straight back, so Undo never removed restored shows.
    nonisolated private static let emptyFile: [String: Data] = [
        "mixes.json": Data("[]".utf8), "library.json": Data("[]".utf8),
        "queue.json": Data("[]".utf8), "positions.json": Data("{}".utf8)
    ]

    /// Parse, validate and write a backup's bytes. The parsing and validation run off the main
    /// thread; UserDefaults is written on the main actor (@AppStorage observers fire on the
    /// writing thread), and the files are on disk when it returns (the closing flush lands any
    /// other queued write before the caller's reload). `settle` runs between the two, with nothing awaited after it: what the
    /// app queued while the backup was parsed lands before the writes, not after. So the files
    /// are written here, each checked (`writeRawNow`): a file that couldn't be saved is left as it
    /// was and named in `unwritten` (backup keys), and dropped from `contents`.
    /// `replacing` is Undo, which trusts its own copy (`prepare`'s `trusted`).
    private static func write(_ data: Data, replacing: Bool, storage: StorageManager, defaults: UserDefaults,
                              settle: () -> Void) async -> (parsed: Bool, contents: Contents, skipped: Int, unwritten: [String]) {
        let currentFocus = defaults.bool(forKey: modeKey)
        let prepared = await Task.detached(priority: .userInitiated) { () -> Prepared? in
            guard let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else { return nil }
            return prepare(dict, currentFocus: currentFocus, now: Date(), trusted: replacing)
        }.value
        guard let prepared else { return (false, Contents(), 0, []) }
        settle()
        apply(prepared.settings?.values ?? [:], absent: prepared.absentKeys, into: defaults, replacing: replacing)
        var writes = prepared.files
        if replacing {
            for file in prepared.absentFiles { if let empty = emptyFile[file] { writes[file] = empty } }
        }
        var unwritten: [String] = []
        for (file, bytes) in writes {
            do { try storage.writeRawNow(bytes, to: file) } catch {
                Log.storage.error("\(replacing ? "Undo" : "Restore", privacy: .public) couldn't save \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if let key = fileBacked.first(where: { $0.value == file })?.key { unwritten.append(key) }
            }
        }
        storage.flush()
        var contents = prepared.contents
        for key in unwritten { contents.record(key, count: nil) }
        return (true, contents, prepared.skipped, unwritten.sorted())
    }
}
