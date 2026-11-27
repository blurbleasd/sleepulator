import SwiftUI

/// Settings ▸ Backup & support ▸ Recent nights: the night journal's verdicts, newest first, in
/// plain words. How each Sleep session went, read in the morning on the phone itself: how long
/// sound really played, how it ended, and either clean or what spoiled it. A failure at 3 a.m.
/// shows here without a cable or a log.
///
/// Pure, so the tests pin the wording, as `MorningReadback` and `NightLineCopy` are. It reads only
/// the verdicts the journal already keeps (`NightJournal.verdicts`, the last 30) and changes
/// nothing: the asks and the morning read-back keep their own rules.
nonisolated enum RecentNights {
    /// One night's heading and its sessions (a night can hold several: a pause past the resume
    /// window, a restart after the app died).
    struct Night: Equatable, Identifiable {
        /// The night's evening, "2026-11-26": unique and stable.
        let id: String
        /// "Wed, Nov 26": the evening the night began.
        let title: String
        let sessions: [Session]
    }

    struct Session: Equatable, Identifiable {
        let id: String
        /// "7 hr 12 min of sound"; "Under a minute of sound".
        let played: String
        /// "11:04 PM – 6:40 AM · the timer eased it out".
        let detail: String
        let status: Status
        /// The whole row for VoiceOver, units and the dash in words.
        let spoken: String
    }

    enum Status: Equatable {
        case clean
        /// `failure`: something went wrong (a failure while it played, or the app stopped), so the
        /// row's status reads a step brighter. A short or untimed-out night isn't a failure.
        case notClean(reason: String?, failure: Bool)

        var text: String {
            switch self {
            case .clean: return "Clean"
            case .notClean(let reason, _): return reason.map { "Not clean: \($0)" } ?? "Not clean"
            }
        }

        var isFailure: Bool {
            if case .notClean(_, let failure) = self { return failure }
            return false
        }
    }

    /// The page's footer: what "clean" means (`NightRules.isClean`, in a person's words).
    static let footer = "The last \(NightRules.keptVerdicts) Sleep sessions, kept on this iPhone. Clean means the sound played to the timer's end, or for 3 hours or more, with nothing going wrong."

    /// A session that started before this hour belongs to the evening before (a 1:00 bedtime is
    /// Tuesday night's), as the morning read-back's night runs to 05:00.
    static let nightUntilHour = MorningReadback.nightUntilHour

    /// - `verdicts`: `NightJournal.verdicts`, oldest first (any order works).
    static func nights(_ verdicts: [NightVerdict], calendar: Calendar = .current) -> [Night] {
        let newestFirst = verdicts.sorted { $0.start > $1.start }
        var order: [String] = []
        var grouped: [String: (title: String, sessions: [Session])] = [:]
        for v in newestFirst {
            let day = evening(of: v.start, calendar: calendar)
            let key = dayKey(day, calendar: calendar)
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = (title(for: day, calendar: calendar), [])
            }
            grouped[key]?.sessions.append(session(v, calendar: calendar))
        }
        return order.compactMap { key in
            grouped[key].map { Night(id: key, title: $0.title, sessions: $0.sessions) }
        }
    }

    static func session(_ v: NightVerdict, calendar: Calendar = .current) -> Session {
        let locale = calendar.locale ?? .current
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                     calendar: calendar, timeZone: calendar.timeZone)
        let from = v.start.formatted(style), to = v.end.formatted(style)
        let live = PlayerClock.clamped(v.live)
        let played: String, playedSpoken: String
        if live < 60 {
            played = "Under a minute of sound"
            playedSpoken = played
        } else {
            played = "\(PlayerClock.short(live)) of sound"
            playedSpoken = "\(PlayerClock.spoken(live, locale: locale)) of sound"
        }
        let how = ending(v)
        let status = status(v)
        return Session(id: v.id, played: played, detail: "\(from) – \(to) · \(how)", status: status,
                       spoken: "\(playedSpoken). \(from) to \(to), \(how). \(status.text).")
    }

    /// How it ended, in the person's words. A `.person` end says only that the sound stopped, not
    /// who stopped it: the queue running out and a long pause end the same way.
    static func ending(_ v: NightVerdict) -> String {
        switch v.endedBy {
        case .timer: return "the timer eased it out"
        case .episodeEnd: return "ended with the episode"
        case .person: return v.interrupted == true ? "interrupted, and the sound didn't come back" : "stopped"
        case .focusSwitch: return "switched to Focus"
        case .died: return "the app stopped while playing"
        }
    }

    /// Clean, or why not. The reasons follow `NightRules.isClean`: what spoiled it (its taints, or
    /// the app stopping), else what it fell short of (a minute of sound under a timer, 3 hours
    /// without one, a timer that ran out while nothing played).
    static func status(_ v: NightVerdict) -> Status {
        if v.clean { return .clean }
        if !v.taints.isEmpty { return .notClean(reason: failures(v.taints), failure: true) }
        switch v.endedBy {
        case .died:
            // The ending already says why.
            return .notClean(reason: nil, failure: true)
        case .timer, .episodeEnd:
            if v.live < NightRules.timedNightMinimumLive {
                return .notClean(reason: "under a minute of sound", failure: false)
            }
            // A timed night with sound and no taint is unclean only for a reconciled deadline: the
            // timer's end was found after the fact (the morning foreground, a Play over a pause).
            return .notClean(reason: "the timer ran out while nothing was playing", failure: false)
        case .person, .focusSwitch:
            if v.live < NightRules.allNightThreshold {
                return .notClean(reason: "under 3 hours of sound", failure: false)
            }
            return .notClean(reason: nil, failure: false)
        }
    }

    /// The taints in plain words, in the order they first happened, counted: "the podcast player
    /// restarted twice and the podcast stream was lost". Never the raw key.
    static func failures(_ taints: [String]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for t in taints {
            let p = phrase(t)
            if counts[p] == nil { order.append(p) }
            counts[p, default: 0] += 1
        }
        let parts = order.map { p -> String in
            switch counts[p] ?? 1 {
            case 1: return p
            case 2: return p + " twice"
            case let n: return p + " \(n) times"
            }
        }
        return joined(parts)
    }

    /// One taint in plain words. The keys are `NightRules`' constants; an unknown one (a newer
    /// build's, or a scrubbed one) reads as "something else went wrong", never the key itself.
    static func phrase(_ taint: String) -> String {
        switch taint {
        case NightRules.playerRebuilt: return "the podcast player restarted"
        case NightRules.streamLost: return "the podcast stream was lost"
        case NightRules.silentAfterRebuild: return "the podcast stayed silent"
        case NightRules.podcastFailed: return "an episode wouldn't play"
        case NightRules.soundEngineError: return "the sound engine couldn't start"
        default:
            guard taint.hasPrefix(NightRules.pipelineDied) else { return "something else went wrong" }
            return taint.hasSuffix(NightRules.mediaServicesReset) ? "iOS reset its audio" : "the podcast audio cut out"
        }
    }

    /// "a", "a and b", "a, b and c" (the app's list style: no serial comma).
    static func joined(_ parts: [String]) -> String {
        guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The start of the evening a session belongs to: its own day, or the day before when it
    /// started before `nightUntilHour`.
    static func evening(of start: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: start)
        guard calendar.component(.hour, from: start) < nightUntilHour else { return day }
        return calendar.date(byAdding: .day, value: -1, to: day) ?? day
    }

    static func title(for day: Date, calendar: Calendar) -> String {
        day.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar,
                                       timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day())
    }

    private static func dayKey(_ day: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// The page. Read-only, and as quiet as the pages around it: the text and dim tones, no accent,
/// a failure a step brighter than the rest rather than a colour. Reads the journal on appear (it
/// isn't observable; a night closes while nobody's on this page).
struct RecentNightsView: View {
    let journal: NightJournal
    let pal: Palette
    @State private var nights: [RecentNights.Night] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && nights.isEmpty {
                VStack(spacing: UI.sm) {
                    Image(systemName: "moon.zzz")
                        .font(.largeTitle)
                        .foregroundStyle(pal.dim)
                        .accessibilityHidden(true)
                    Text("No nights yet")
                        .font(.headline)
                        .foregroundStyle(pal.text)
                    Text("Each Sleep session shows here once it ends: how long the sound played and how it ended.")
                        .font(.footnote)
                        .foregroundStyle(pal.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, UI.xxl)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(pal.bg.ignoresSafeArea())
            } else {
                List {
                    ForEach(nights) { night in
                        Section {
                            ForEach(night.sessions) { SessionRow(session: $0, pal: pal) }
                        } header: {
                            Text(night.title).foregroundStyle(pal.dim)
                        } footer: {
                            if night.id == nights.last?.id {
                                Text(RecentNights.footer).foregroundStyle(pal.dim)
                            }
                        }
                    }
                    .listRowBackground(pal.text.opacity(0.05))
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(pal.bg.ignoresSafeArea())
            }
        }
        // Room for the floating mini-player, measured (a pushed page ends at the bottom edge).
        .miniPlayerClearance()
        .navigationTitle("Recent nights")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // A pause past its resume window ended its night: close it first, as the asks do
            // when they look, so this morning's night is on the list.
            journal.closeLapsedPause()
            nights = RecentNights.nights(journal.verdicts)
            loaded = true
        }
    }

    private struct SessionRow: View {
        let session: RecentNights.Session
        let pal: Palette

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.played)
                    .monospacedDigit()
                    .foregroundStyle(pal.text)
                Text(session.detail)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(pal.dim)
                Text(session.status.text)
                    .font(.footnote)
                    .foregroundStyle(session.status.isFailure ? pal.text : pal.dim)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.spoken)
        }
    }
}
