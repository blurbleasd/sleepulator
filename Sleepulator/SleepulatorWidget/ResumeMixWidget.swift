import WidgetKit
import SwiftUI

// Home-screen / lock-screen widget: one tap to resume last night's mix. Static content —
// the tap deep-links into the app (sleepulator://resume), because the audio engine lives
// in the app process and needs an activated audio session; ContentView's onOpenURL calls
// `AudioEngine.resumeFromShortcut()`. Colors mirror the app's gold accent (widget
// extensions don't link the app's Palette — same convention as SleepTimerLiveActivity).

struct ResumeMixEntry: TimelineEntry {
    let date: Date
}

struct ResumeMixProvider: TimelineProvider {
    func placeholder(in context: Context) -> ResumeMixEntry { ResumeMixEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ResumeMixEntry) -> Void) {
        completion(ResumeMixEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ResumeMixEntry>) -> Void) {
        // Static widget — one entry, never reloads on its own.
        completion(Timeline(entries: [ResumeMixEntry(date: .now)], policy: .never))
    }
}

private let widgetGold = Color(red: 0.91, green: 0.63, blue: 0.30)

struct ResumeMixWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            // Lock-screen circular: just the moon — tap opens straight into playback.
            ZStack {
                Circle().fill(.black.opacity(0.35))
                Image(systemName: "moon.zzz.fill")
                    .font(.title2)
                    .foregroundStyle(widgetGold)
            }
            .accessibilityLabel("Resume sleep mix")
        default:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title)
                    .foregroundStyle(widgetGold)
                Spacer(minLength: 0)
                Text("Resume")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("last night's mix")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Resume last night's sleep mix")
        }
    }
}

struct ResumeMixWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.sleepulator.resume", provider: ResumeMixProvider()) { _ in
            ResumeMixWidgetView()
                .containerBackground(Color.black, for: .widget)
                .widgetURL(URL(string: "sleepulator://resume"))
        }
        .configurationDisplayName("Resume sleep mix")
        .description("One tap to start where you left off.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}
