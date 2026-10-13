import Foundation
import UIKit
import os

// The night journal: one record per Sleep night, kept on this phone. Its folder (the night files
// and the verdicts) is excluded from iCloud and computer backups, and the app's Backup file never
// carries it.
//
//   AudioEngine.noteSessionEdge ──── opened / paused / resumed ───┐
//   RMS tap + player clock (main) ── live audio, counted ──────────┤
//   SleepTimerService.onTerminalStop  closed by the timer ─────────┼──> NightJournal (main) ──> nights/<id>.jsonl  (one event per line,
//   PodcastPlayer.onPipelineEvent ── taints, filed by time ────────┤        │                   last 2 nights, no URLs)
//   podcast failures · interruptions · routes · terminate · Focus ─┘        └──> nights/night-verdicts.json (last 30)
//
// A night is clean (NightRules.isClean) when sound really played through it: to its timer's end
// while playing, with at least a minute of live audio (never a deadline found already passed, on
// the morning foreground or by the first tick after a Play), or 3+ hours on All night ended by a
// person; with no player rebuild, pipeline death, podcast failure, lost stream or noise-engine
// error while it played. News during a pause (an alarm's), and a dead or rebuilt player in the
// first 10 s after the sound starts or resumes, is a note. A pause over 30 minutes ends the night
// where it paused. A record left open while playing means the app died: not clean. The rating and
// tip asks count clean nights, at most one a night
// (docs/designs/APP-STORE-LAUNCH-1.0.md, NT-1, EV-1), and "Send feedback"
// attaches the files, which is why nothing written here may carry a URL (private podcast feeds
// keep their subscriber's secret in it).

/// Why a night ended.
nonisolated enum NightEndReason: String, Codable, Equatable {
    /// A pause that outlasted `UntimedNight.resumeWindow`, a force-quit while playing, or any
    /// stop a person made.
    case person
    /// The sleep timer's terminal stop, reached while the sound was playing.
    case timer
    /// "Stop after this episode" reached the episode's end while playing.
    case episodeEnd
    /// The app switched to Focus.
    case focusSwitch
    /// The record was found open, still playing, at the next launch: the app died.
    case died
}

/// One night's state, folded from its events. Pure data, so the rules are unit-tested.
nonisolated struct NightSummary: Codable, Equatable {
    var id: String
    var start: Date
    /// When the night ended; nil while it's open.
    var end: Date?
    /// Seconds of live audio: only while the session plays, and only from the render and player
    /// clocks, so a suspended app or a reconciled deadline adds nothing.
    var live: TimeInterval = 0
    /// What spoiled the night, if anything (player rebuilt, pipeline died, podcast failed, …).
    var taints: [String] = []
    var endedBy: NightEndReason?
    /// The terminal stop came from a deadline found already passed: on the morning foreground, or
    /// by the first tick after a Play (`SleepTimerService.overdueAfter`).
    var reconciled = false
    /// Set while paused; a resume within `UntimedNight.resumeWindow` keeps the night.
    var pausedAt: Date?
    /// The time of the last event written, so a died night can be closed where it stopped.
    var lastEventAt: Date
}

/// What the asks and the feedback summary need from a closed night.
nonisolated struct NightVerdict: Codable, Equatable {
    let id: String
    let start: Date
    let end: Date
    let live: TimeInterval
    let clean: Bool
    let endedBy: NightEndReason
    let taints: [String]
}

/// The night's rules, pure.
nonisolated enum NightRules {
    /// All night counts as clean from this much live audio on.
    static let allNightThreshold: TimeInterval = 3 * 3600
    /// A timed night needs this much live audio to count: a deadline that passed while the app
    /// slept, fired by a lock-screen Play in the morning, ends a night that hardly played.
    static let timedNightMinimumLive: TimeInterval = 60
    /// News this soon after a night's sound starts (it opens, or resumes from a pause) is the
    /// pause's aftermath when it's a player the pause killed: its death, or its rebuild by the
    /// resume or by the watchdog a few seconds later (`RenderHeartbeatMonitor.deadAfter`, 4 s).
    static let graceAfterResume: TimeInterval = 10

    /// The pipeline news a pause can leave behind. `PodcastPlayer` sends these; `isPauseAftermath`
    /// reads them, so a rewording can't quietly end the grace.
    static let playerRebuilt = "player rebuilt"
    static let pipelineDied = "pipeline died"

    /// Only a dead or rebuilt player is a pause's aftermath. A failed episode, a lost stream,
    /// silence after a rebuild or the noise engine's error spoil a night whatever their timing.
    static func isPauseAftermath(_ kind: String) -> Bool {
        kind == playerRebuilt || kind.hasPrefix(pipelineDied)
    }
    /// News is stamped where it happens and filed on main after a hop, so it can trail the edge
    /// it belongs to by this much: the noise engine's start error is stamped as the switch flips,
    /// just before the session edge opens the night; a player's death is stamped off main, a
    /// moment before the Play that resumes the night or the interruption that pauses it.
    static let newsLead: TimeInterval = 2
    /// A checkpoint line every this much live audio, so a death keeps most of the count.
    static let checkpointEvery: TimeInterval = 5 * 60
    /// A tick further apart than this from the last one isn't live time (the app was suspended,
    /// or nothing rendered in between).
    static let maxTickGap: TimeInterval = 2
    /// Night files kept for "Send feedback".
    static let keptNightFiles = 2
    /// Past this, a night's file takes only the lines that decide its verdict.
    static let fileSoftCap = 128 * 1024
    /// Verdicts kept for the asks and the feedback summary.
    static let keptVerdicts = 30

    static func isClean(_ s: NightSummary) -> Bool {
        guard let endedBy = s.endedBy, s.taints.isEmpty else { return false }
        switch endedBy {
        case .died: return false
        case .timer, .episodeEnd: return !s.reconciled && s.live >= timedNightMinimumLive
        case .person, .focusSwitch: return s.live >= allNightThreshold
        }
    }

    /// Clean nights, at most one per night: a night runs noon to noon on the wall clock, by when
    /// it started, so naps and a short timer tried three times count once (NT-1; ship review D7,
    /// 2026-10-12). Wall-clock hours, so a daylight-saving day doesn't move the boundary.
    static func cleanNightCount(_ verdicts: [NightVerdict], calendar: Calendar = .current) -> Int {
        Set(verdicts.filter(\.clean).map { v in
            let day = calendar.component(.hour, from: v.start) < 12
                ? calendar.date(byAdding: .day, value: -1, to: v.start) ?? v.start : v.start
            return calendar.dateComponents([.year, .month, .day], from: day)
        }).count
    }

    static func verdict(_ s: NightSummary) -> NightVerdict? {
        guard let end = s.end, let endedBy = s.endedBy else { return nil }
        return NightVerdict(id: s.id, start: s.start, end: end, live: s.live, clean: isClean(s),
                            endedBy: endedBy, taints: s.taints)
    }

    /// Text safe for the trail: anything shaped like a URL becomes "[link]".
    static func scrub(_ text: String) -> String {
        text.replacingOccurrences(of: #"[A-Za-z][A-Za-z0-9+.\-]*://\S+"#, with: "[link]",
                                  options: .regularExpression)
    }

    /// A night's file name from its start: sortable, and readable in a mail attachment.
    static func id(for start: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: start)
    }
}

/// One line of a night's file.
nonisolated struct NightEvent: Codable, Equatable {
    var v = 1
    let at: Date
    /// opened, paused, resumed, live, threshold, taint, note, closed
    let kind: String
    var detail: String?
}

nonisolated extension NightSummary {
    /// Fold one event into the summary: how a file is read back at launch.
    mutating func apply(_ e: NightEvent) {
        lastEventAt = max(lastEventAt, e.at)
        switch e.kind {
        case "paused":
            pausedAt = e.at
            live = max(live, Double(e.detail ?? "") ?? live)
        case "resumed": pausedAt = nil
        case "live", "threshold": live = max(live, Double(e.detail ?? "") ?? live)
        case "taint": if let d = e.detail { taints.append(d) }
        case "closed":
            let parts = (e.detail ?? "").split(separator: " ").map(String.init)
            endedBy = parts.first.flatMap(NightEndReason.init(rawValue:)) ?? .person
            if parts.count > 1, let l = Double(parts[1]) { live = max(live, l) }
            reconciled = parts.contains("reconciled")
            end = e.at
        default: break
        }
    }
}

/// The journal itself. Main-thread API; files are written on a serial queue, best effort: a
/// failed write is logged once and never touches the audio. `nonisolated deinit` per CLAUDE.md
/// ("Isolated deinits"): AudioEngine owns it and the tests create and free it.
final class NightJournal {
    private(set) var open: NightSummary?
    private(set) var verdicts: [NightVerdict] = []
    var now: () -> Date = Date.init

    let directory: URL
    private let storage: StorageManager
    private let fileQueue = DispatchQueue(label: "app.sleepulator.nights", qos: .utility)
    private var lastTick: Date?
    /// When the open night's sound last started: it opened, or resumed from a pause
    /// (`NightRules.graceAfterResume`).
    private var soundStartedAt: Date?
    private var liveAtCheckpoint: TimeInterval = 0
    private var thresholdWritten = false
    private var bytesWritten = 0
    private var loggedWriteFailure = false
    private var terminateObserver: NSObjectProtocol?
    private static let verdictsFile = "night-verdicts.json"

    /// `directory` defaults to Application Support/Sleepulator/nights (excluded from iCloud
    /// backup, default file protection so a locked phone can still write at 3am). The verdicts
    /// live there too, through a store of their own, so they're excluded with it. Tests pass a
    /// temp dir and their own StorageManager.
    /// `now` is the journal's clock, read by the launch recovery too (tests inject theirs here).
    init(directory: URL? = nil, storage: StorageManager? = nil, observeTermination: Bool = true,
         now: @escaping () -> Date = Date.init) {
        self.now = now
        let fm = FileManager.default
        let dir = directory ?? {
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            return base.appendingPathComponent("Sleepulator/nights", isDirectory: true)
        }()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var excluded = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        self.directory = dir
        self.storage = storage ?? StorageManager(directory: dir)
        verdicts = self.storage.load(from: Self.verdictsFile) ?? []
        recoverUnclosedNight()
        if observeTermination {
            // A force-quit of a playing (so running, not suspended) app delivers this: the night
            // ends by a person. A suspended or killed app gets nothing, and stays open → died.
            terminateObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.appWillTerminate() }
            }
        }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    /// The journal AudioEngine uses. Inside a unit-test host, or an app a UI test launched with
    /// `-uiTestIsolated`, it's a throwaway one in a temp folder with its own store, so a dev
    /// simulator's real nights and the tests' nights never mix (enough timer-ended nights and a
    /// rating prompt would pop up over a UI test). Each such launch empties the shared
    /// sleepulator-test-nights root once.
    static func makeDefault() -> NightJournal {
        guard AppInfo.isUnitTestHost || AppInfo.isUITestRun else {
            return NightJournal()
        }
        // One root per test host, emptied on first use, so the engines tests make don't leave a
        // folder each behind run after run.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sleepulator-test-nights", isDirectory: true)
        if !testRootCleared {
            testRootCleared = true
            try? FileManager.default.removeItem(at: root)
        }
        let tmp = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return NightJournal(directory: tmp, storage: StorageManager(directory: tmp), observeTermination: false)
    }
    private static var testRootCleared = false

    /// A force-quit of a running app: the night ends by a person, where it paused if it had.
    func appWillTerminate() {
        guard let night = open else { return }
        close(.person, at: night.pausedAt, flush: true)
    }

    // MARK: Session edges

    /// A Sleep session started playing from rest (or Focus → Sleep with sound on).
    func sessionStarted() {
        let t = now()
        if var night = open, let pausedAt = night.pausedAt {
            if t.timeIntervalSince(pausedAt) < UntimedNight.resumeWindow {
                night.pausedAt = nil
                open = night
                soundStartedAt = t
                write(NightEvent(at: t, kind: "resumed"), essential: true)
                return
            }
            // The pause outlasted the window: that night ended when it paused.
            close(.person, at: pausedAt)
        } else if open != nil {
            return   // already playing: nothing to open
        }
        let id = NightRules.id(for: t)
        open = NightSummary(id: id, start: t, lastEventAt: t)
        lastTick = nil
        // A night can open on a player that died while it sat paused (overnight, or past the
        // window): the watchdog's rebuild a few seconds in is that aftermath too.
        soundStartedAt = t
        liveAtCheckpoint = 0
        thresholdWritten = false
        bytesWritten = 0
        pruneNightFiles(keepingAlso: id)
        write(NightEvent(at: t, kind: "opened"))
    }

    /// The Sleep session's sound stopped (a pause, a call, headphones out, the timer's own stop).
    /// `at` is when it stopped, if known before the hop to main (an interruption's own time).
    func sessionStopped(at: Date? = nil) {
        guard var night = open, night.pausedAt == nil else { return }
        let t = max(at ?? now(), night.start)
        night.pausedAt = t
        open = night
        lastTick = nil
        write(NightEvent(at: t, kind: "paused", detail: liveText(night.live)), essential: true)
    }

    /// Live audio: the RMS tap and the player clock, both on main, ~20 Hz while sound renders.
    /// Counts the time since the last tick from either source (so two sources don't double up),
    /// only while the night is open and not paused.
    func liveTick() {
        guard var night = open, night.pausedAt == nil else { return }
        let t = now()
        defer { lastTick = t }
        guard let last = lastTick else { return }
        let gap = t.timeIntervalSince(last)
        guard gap > 0, gap <= NightRules.maxTickGap else { return }
        night.live += gap
        open = night
        if night.live - liveAtCheckpoint >= NightRules.checkpointEvery {
            liveAtCheckpoint = night.live
            write(NightEvent(at: t, kind: "live", detail: liveText(night.live)))
        }
        if !thresholdWritten, night.live >= NightRules.allNightThreshold {
            thresholdWritten = true
            write(NightEvent(at: t, kind: "threshold", detail: liveText(night.live)), essential: true)
        }
    }

    /// The sleep timer's terminal stop, reported before it stops everything. Counts as the
    /// timer's end only while playing; a stop over a pause ends the night where it paused. A
    /// deadline from before this night opened (last night's, found by the first tick after a
    /// morning Play that opened a new night) discards this one: it never played, and recording
    /// it would count a zero-length night and push last night's file out of the two kept.
    func timerStopped(episode: Bool, reconciled: Bool, endedAt: Date) {
        guard let night = open else { return }
        if let pausedAt = night.pausedAt {
            close(.person, at: pausedAt)
        } else if endedAt < night.start {
            discardOpenNight()
        } else {
            close(episode ? .episodeEnd : .timer, at: endedAt, reconciled: reconciled)
        }
    }

    /// A pause that outlasted `UntimedNight.resumeWindow` ended its night where it paused. Run
    /// before filing news and when the asks look, so a night counts the morning it ends (not when
    /// play is next pressed) and nothing from later lands in it.
    func closeLapsedPause() {
        guard let night = open, let pausedAt = night.pausedAt,
              now().timeIntervalSince(pausedAt) >= UntimedNight.resumeWindow else { return }
        close(.person, at: pausedAt)
    }

    /// Leaving Sleep ends the night.
    func switchedToFocus() {
        guard let night = open else { return }
        close(night.pausedAt != nil ? .person : .focusSwitch, at: night.pausedAt)
    }

    // MARK: Taints and notes (filed by the time they happened, EV-1)

    /// Something that spoils a night: filed into the night whose span contains `at` (the open one,
    /// from a moment before its start, or a recent closed one, whose verdict is then recomputed);
    /// dropped if none. While the night is paused (an alarm, a call, the person's pause) nothing is
    /// meant to play, so news then is a trail note; so is a dead or rebuilt player within
    /// `graceAfterResume` of the sound starting again (`isPauseAftermath`).
    func taint(_ kind: String, at: Date) {
        let kind = NightRules.scrub(kind)
        closeLapsedPause()
        // A dead or rebuilt player stamped a moment before the pause is the pause's own (an
        // alarm's interruption and the player's death it causes can reach main in either order).
        if let night = open, let pausedAt = night.pausedAt,
           at >= pausedAt || (NightRules.isPauseAftermath(kind) && at >= pausedAt.addingTimeInterval(-NightRules.newsLead)) {
            write(NightEvent(at: at, kind: "note", detail: kind + " while paused"))
            return
        }
        // From a moment before, as the player's news is stamped off main and can trail the edge.
        if open != nil, NightRules.isPauseAftermath(kind), let soundStartedAt,
           at >= soundStartedAt.addingTimeInterval(-NightRules.newsLead),
           at.timeIntervalSince(soundStartedAt) <= NightRules.graceAfterResume {
            write(NightEvent(at: at, kind: "note", detail: kind + " just after the sound started"))
            return
        }
        if var night = open, at >= night.start.addingTimeInterval(-NightRules.newsLead) {
            night.taints.append(kind)
            open = night
            write(NightEvent(at: at, kind: "taint", detail: kind), essential: true)
            return
        }
        guard let index = verdicts.lastIndex(where: { $0.start <= at && at <= $0.end }) else {
            Log.storage.info("night journal: dropped a late \(kind, privacy: .public) outside every night")
            return
        }
        let old = verdicts[index]
        verdicts[index] = NightVerdict(id: old.id, start: old.start, end: old.end, live: old.live,
                                       clean: false, endedBy: old.endedBy, taints: old.taints + [kind])
        storage.save(verdicts, to: Self.verdictsFile)
        append(NightEvent(at: at, kind: "taint", detail: kind), toNight: old.id)
    }

    /// Context for the trail that doesn't spoil the night: an interruption, a route change.
    func note(_ text: String) {
        closeLapsedPause()
        guard open != nil else { return }
        write(NightEvent(at: now(), kind: "note", detail: NightRules.scrub(text)))
    }

    // MARK: For the asks and "Send feedback"

    /// What the asks wait for: clean nights, one a night at most (`NightRules.cleanNightCount`).
    var cleanNightCount: Int { NightRules.cleanNightCount(verdicts) }

    /// One line for the feedback mail: "Last 7 nights: 5 clean, 1 ended early or spoiled, 1 left open."
    func summaryLine(last n: Int = 7) -> String {
        let recent = verdicts.suffix(n)
        guard !recent.isEmpty else { return "No night recorded yet." }
        let clean = recent.filter(\.clean).count
        let died = recent.filter { $0.endedBy == .died }.count
        let other = recent.count - clean - died
        var parts = ["\(clean) clean"]
        if other > 0 { parts.append("\(other) ended early or spoiled") }
        if died > 0 { parts.append("\(died) left open") }
        return "Last \(recent.count) night\(recent.count == 1 ? "" : "s"): " + parts.joined(separator: ", ") + "."
    }

    /// The kept night files, newest first, for the feedback attachment.
    func nightFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: Internals

    private func close(_ reason: NightEndReason, at: Date?, reconciled: Bool = false, flush: Bool = false) {
        guard var night = open else { return }
        let end = at ?? now()
        night.end = end
        night.endedBy = reason
        night.reconciled = reconciled
        var detail = "\(reason.rawValue) \(Int(night.live))"
        if reconciled { detail += " reconciled" }
        append(NightEvent(at: end, kind: "closed", detail: detail), toNight: night.id, flush: flush)
        open = nil
        lastTick = nil
        soundStartedAt = nil
        if let v = NightRules.verdict(night) { record(v) }
        // The terminate path: the verdict must land before the process goes, or the night is
        // closed on disk with no verdict (recovery then rebuilds it from the file).
        if flush { storage.flush() }
    }

    /// Drop the open night with no verdict, and its file.
    private func discardOpenNight() {
        guard let night = open else { return }
        open = nil
        lastTick = nil
        soundStartedAt = nil
        let url = directory.appendingPathComponent(night.id).appendingPathExtension("jsonl")
        // Synchronously, after its queued lines: the next night's prune must not see it and keep
        // it over last night's file.
        fileQueue.sync { try? FileManager.default.removeItem(at: url) }
        Log.storage.info("night journal: discarded a night a stale deadline ended as it opened")
    }

    /// Keep one verdict per night (a recovery can meet a night already recorded), the newest 30.
    private func record(_ v: NightVerdict) {
        verdicts.removeAll { $0.id == v.id }
        verdicts.append(v)
        if verdicts.count > NightRules.keptVerdicts {
            verdicts.removeFirst(verdicts.count - NightRules.keptVerdicts)
        }
        storage.save(verdicts, to: Self.verdictsFile)
    }

    /// At launch: a night file without a "closed" line, by its last known state. Paused inside
    /// `UntimedNight.resumeWindow` → it stays open (a resume carries it on; closeLapsedPause ends
    /// it where it paused). Paused longer → it ended when it paused (a person's stop). Playing →
    /// the app died. A closed file whose verdict never landed (the process went between the two
    /// writes) is recorded from the file.
    private func recoverUnclosedNight() {
        guard let newest = nightFiles().first else { return }
        let id = newest.deletingPathExtension().lastPathComponent
        // Already recorded, the usual case: nothing to read on the launch path.
        guard !verdicts.contains(where: { $0.id == id }),
              let data = try? Data(contentsOf: newest),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A kill mid-write can leave a partial last line: skip anything that doesn't decode.
        let events = text.split(separator: "\n").compactMap { try? decoder.decode(NightEvent.self, from: Data($0.utf8)) }
        guard let first = events.first, first.kind == "opened" else { return }
        var night = NightSummary(id: id, start: first.at, lastEventAt: first.at)
        events.forEach { night.apply($0) }
        if night.end != nil {
            if let v = NightRules.verdict(night) { record(v) }
            return
        }
        open = night
        bytesWritten = data.count
        // A partial last line: end it, so the closing line isn't glued to it and lost.
        if data.last != 0x0A { try? Self.appendLine(Data([0x0A]), to: newest) }
        if let pausedAt = night.pausedAt {
            // Still inside its resume window (the app was ended while paused, as iOS does to a
            // suspended app): the night carries on if play comes back in time, and
            // closeLapsedPause ends it where it paused otherwise.
            if now().timeIntervalSince(pausedAt) < UntimedNight.resumeWindow {
                liveAtCheckpoint = night.live
                thresholdWritten = night.live >= NightRules.allNightThreshold
                return
            }
            close(.person, at: pausedAt)
        } else {
            close(.died, at: night.lastEventAt)
        }
    }

    private func liveText(_ live: TimeInterval) -> String { String(Int(live)) }

    /// Append to the open night's file. Past the soft cap only the lines that decide a verdict
    /// (taints, the threshold, the close) are written.
    private func write(_ event: NightEvent, essential: Bool = false) {
        guard var night = open else { return }
        night.lastEventAt = max(night.lastEventAt, event.at)
        open = night
        guard essential || bytesWritten < NightRules.fileSoftCap else { return }
        append(event, toNight: night.id)
    }

    private func append(_ event: NightEvent, toNight id: String, flush: Bool = false) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        // Only the open night's own file counts toward its soft cap (a late taint can land in an
        // older night's file).
        if id == open?.id { bytesWritten += line.count }
        let url = directory.appendingPathComponent(id).appendingPathExtension("jsonl")
        if flush {
            // The terminate path: write before the process goes.
            let failure: Error? = fileQueue.sync {
                do { try Self.appendLine(line, to: url); return nil } catch { return error }
            }
            if let failure { reportWriteFailure(failure) }
        } else {
            fileQueue.async { [weak self] in
                do {
                    try Self.appendLine(line, to: url)
                } catch {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.reportWriteFailure(error) } }
                }
            }
        }
    }

    /// Off main, on `fileQueue`. FileHandle writes are plain syscalls: a line written survives
    /// the app being killed (only power loss could lose it, and a dead phone is a lost night).
    nonisolated private static func appendLine(_ line: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func reportWriteFailure(_ error: Error) {
        guard !loggedWriteFailure else { return }
        loggedWriteFailure = true
        Log.storage.error("night journal write failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Keep the newest night files (plus the one being opened); older ones go.
    private func pruneNightFiles(keepingAlso id: String) {
        let keep = NightRules.keptNightFiles - 1
        let old = nightFiles().filter { $0.deletingPathExtension().lastPathComponent != id }.dropFirst(keep)
        fileQueue.async { old.forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    /// Wait for queued writes, the night files' and the verdicts' (tests, and "Send feedback"
    /// before it reads the files).
    func drain() {
        fileQueue.sync {}
        storage.flush()
    }
}
