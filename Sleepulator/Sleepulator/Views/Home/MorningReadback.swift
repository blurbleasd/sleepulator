import SwiftUI

/// Sleep Home's morning read-back: the morning after a clean night, one quiet line under the night
/// line says how the night went ("Last night · 1 hr 30 min, eased out at 12:41 AM"). The app's best
/// work happens while the person is asleep; this is the one place they hear that it held.
///
/// Pure, so the tests pin every case. Only a clean night speaks (`NightRules.isClean`): a night
/// that hiccupped, was reconciled on the morning foreground or died never claims it went well.
/// It reads only what the night journal already keeps, on this phone.
nonisolated enum MorningReadback {
    /// The line shows from 05:00 to 18:00 local, when "last night" means the night just gone.
    static let firstHour = 5
    static let lastHour = 18
    /// A night that started from 18:00 to before 05:00 is a night; any other start (a nap after a
    /// night shift, an afternoon rest) isn't "last night".
    static let nightFromHour = 18
    /// A clean timed night needs only a minute of live audio; a line about one minute reads as a
    /// test, not a night.
    static let minimumLive: TimeInterval = 10 * 60

    struct Line: Equatable {
        /// What followed "Last night": "7 hr 12 min, until 6:40 AM".
        let record: String
        /// The whole line for VoiceOver, with the units in words ("hr" reads as letters).
        let spoken: String

        static let lead = "Last night"
        var text: String { "\(Self.lead) · \(record)" }
    }

    /// - `last`: the newest closed night (`NightJournal.verdicts.last`).
    /// - `nightOpen`: a session is open in the journal (playing, or paused under the resume
    ///   window), so the night hasn't ended.
    /// - `playing`: anything plays or is starting; the layer pills have the slot then.
    static func line(last: NightVerdict?, nightOpen: Bool, focusMode: Bool, playing: Bool,
                     now: Date, calendar: Calendar = .current) -> Line? {
        guard !focusMode, !playing, !nightOpen,
              let night = last, night.clean, night.live >= minimumLive, night.end <= now else { return nil }
        let hourNow = calendar.component(.hour, from: now)
        guard hourNow >= firstHour, hourNow < lastHour else { return nil }
        let startHour = calendar.component(.hour, from: night.start)
        guard startHour >= nightFromHour || startHour < firstHour else { return nil }
        // The night just gone: it started yesterday evening, or after midnight today.
        let today = calendar.startOfDay(for: now)
        let eveningOf = calendar.startOfDay(for: startHour < firstHour
            ? calendar.date(byAdding: .day, value: -1, to: night.start) ?? night.start : night.start)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              calendar.isDate(eveningOf, inSameDayAs: yesterday) else { return nil }

        let time = night.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                        locale: calendar.locale ?? .current,
                                                        calendar: calendar, timeZone: calendar.timeZone))
        let span = PlayerClock.short(night.live)
        let spokenSpan = PlayerClock.spoken(night.live)
        let ending: String
        switch night.endedBy {
        case .timer: ending = "eased out at \(time)"
        case .episodeEnd: ending = "ended with the episode at \(time)"
        case .person, .focusSwitch: ending = "until \(time)"
        case .died: return nil
        }
        return Line(record: "\(span), \(ending)", spoken: "\(Line.lead), \(spokenSpan), \(ending)")
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
        Text("\(Text(MorningReadback.Line.lead).fontWeight(.medium)) · \(line.record)")
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
