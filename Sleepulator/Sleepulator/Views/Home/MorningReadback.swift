import SwiftUI

/// Sleep Home's morning read-back: the morning after a night that held, one quiet line under the
/// night line says how it went ("Last night · 1 hr 30 min, eased out at 12:41 AM"). The app's best
/// work happens while the person is asleep; this is the one place they hear that it held.
///
/// Pure, so the tests pin every case. A night is every Sleep session that started in it (18:00 to
/// before 05:00), not the newest one: a morning Play is never last night, and a night the app died
/// in stays broken after the person restarts the sound. Any session that broke silences the line.
/// It reads only what the night journal already keeps, on this phone.
nonisolated enum MorningReadback {
    /// The line shows from 05:00 to 18:00 local, when "last night" means the night just gone.
    static let showsFromHour = 5
    static let hidesAtHour = 18
    /// A session that started from 18:00 to before 05:00 belongs to that evening's night; any
    /// other start (a morning Play, a nap after a night shift, an afternoon rest) isn't a night.
    static let nightFromHour = 18
    static let nightUntilHour = 5
    /// A clean timed night needs only a minute of live audio; a line about one minute reads as a
    /// test, not a night. Counted in the rounded minutes the line shows: live audio runs a little
    /// under a timer's length, and a 10-minute night came in at 599 s.
    static let minimumMinutes = 10

    struct Line: Equatable {
        /// What followed the lead: "7 hr 12 min, until 6:40 AM".
        let record: String
        /// The whole line for VoiceOver, with the units in words ("hr" reads as letters).
        let spoken: String

        static let lead = "Last night"
        static let separator = " · "
        var text: String { Self.lead + Self.separator + record }
    }

    /// - `nights`: the journal's closed sessions (`NightJournal.verdicts`), oldest first.
    /// - `openSince`: when the journal's open session started (playing, or paused under the resume
    ///   window). One that started last night means the night hasn't ended; a morning one doesn't.
    /// - `playing`: anything plays or is starting; the layer pills have the slot then.
    static func line(nights: [NightVerdict], openSince: Date?, focusMode: Bool, playing: Bool,
                     now: Date, calendar: Calendar = .current) -> Line? {
        guard !focusMode, !playing else { return nil }
        let hourNow = calendar.component(.hour, from: now)
        guard hourNow >= showsFromHour, hourNow < hidesAtHour else { return nil }
        if let openSince, isLastNight(openSince, now: now, calendar: calendar) { return nil }
        let sessions = nights.filter { isLastNight($0.start, now: now, calendar: calendar) }
        guard let final = sessions.max(by: { $0.end < $1.end }), final.end <= now,
              !sessions.contains(where: broke) else { return nil }
        // Rounded once, so the screen and VoiceOver can't disagree by a minute.
        let minutes = Int((sessions.reduce(0) { $0 + $1.live } / 60).rounded())
        guard minutes >= minimumMinutes else { return nil }

        let locale = calendar.locale ?? .current
        let time = final.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                        calendar: calendar, timeZone: calendar.timeZone))
        let ending: String
        switch final.endedBy {
        case .timer: ending = "eased out at \(time)"
        case .episodeEnd: ending = "ended with the episode at \(time)"
        case .person, .focusSwitch: ending = "until \(time)"
        case .died: return nil
        }
        let span = Double(minutes * 60)
        return Line(record: "\(PlayerClock.short(span)), \(ending)",
                    spoken: "\(Line.lead), \(PlayerClock.spoken(span, locale: locale)), \(ending)")
    }

    /// A session that started in the night just gone: yesterday from 18:00, or today before 05:00.
    static func isLastNight(_ start: Date, now: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: start)
        guard hour >= nightFromHour || hour < nightUntilHour else { return false }
        let eveningOf = hour < nightUntilHour
            ? calendar.date(byAdding: .day, value: -1, to: start) ?? start : start
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        else { return false }
        return calendar.isDate(eveningOf, inSameDayAs: yesterday)
    }

    /// A session that spoils the night's claim: it died, something failed while it played, or its
    /// timer end can't be trusted (a deadline reconciled on the morning foreground, or under a
    /// minute of sound: `NightRules.isClean`). A session the person ended early is not a failure.
    static func broke(_ session: NightVerdict) -> Bool {
        switch session.endedBy {
        case .died: return true
        case .timer, .episodeEnd: return !session.clean
        case .person, .focusSwitch: return !session.taints.isEmpty
        }
    }
}

/// The read-back under the night line: smaller than the line above it and in the same dim tone,
/// so it reads as a note on the night rather than a control. Not tappable.
struct MorningReadbackLine: View {
    let line: MorningReadback.Line
    let pal: Palette

    var body: some View {
        // "Last night" carries the line's weight; the rest is the record. A step quieter than the
        // night line above it (smaller, lighter, 85%: still ~5.5:1 on the warm black), since that
        // line is the control and this one is only news.
        Text("\(Text(MorningReadback.Line.lead).fontWeight(.medium))\(MorningReadback.Line.separator)\(line.record)")
            .font(.system(.footnote, design: .rounded))
            .monospacedDigit()
            .foregroundColor(pal.dim.opacity(0.85))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 30)
            // Capped like Home's bottom row: past accessibility size 2 the orb's stack outgrew a
            // small phone, and this line is the one Home can most easily spare.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.spoken)
            .accessibilityIdentifier("morningReadback")
    }
}
