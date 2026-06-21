//
//  SleepTimerLiveActivity.swift
//  Sleepulator Widget Extension
//
//  Lock-screen + Dynamic Island Live Activity for the sleep timer.
//
//  This file is the *presentation* only. The app drives the activity
//  lifecycle (start / update / end) from SleepTimerService. The
//  SleepTimerAttributes type is SHARED with the main app target — add
//  Models/SleepTimerAttributes.swift to this target's membership (File
//  Inspector → Target Membership → check the widget) so both targets
//  compile the same Attributes/ContentState definition.
//

import ActivityKit
import WidgetKit
import SwiftUI

@main
struct SleepulatorWidgetBundle: WidgetBundle {
    var body: some Widget {
        SleepTimerLiveActivity()
    }
}

// The app's gold accent, mirrored here — widget extensions don't link the app's Palette.
private let arferGold = Color(red: 0.91, green: 0.63, blue: 0.30)

struct SleepTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SleepTimerAttributes.self) { context in
            // Lock screen / banner presentation.
            SleepTimerLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(arferGold)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Sleep timer", systemImage: "moon.zzz.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(arferGold)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SleepCountdown(state: context.state)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Audio fades out, then stops")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(arferGold)
            } compactTrailing: {
                SleepCountdown(state: context.state)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(arferGold)
            }
            .keylineTint(arferGold)
        }
    }
}

private struct SleepTimerLockScreenView: View {
    let state: SleepTimerAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.title2)
                .foregroundStyle(arferGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sleep timer")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Audio fades out, then stops")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            SleepCountdown(state: state)
                .font(.system(.title, design: .rounded).monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding()
    }
}

/// Live, self-updating countdown driven off `endDate` so the system ticks it down
/// without the app pushing a per-second update. Falls back to the static remaining
/// value when `endDate` is absent (e.g. the final end state).
private struct SleepCountdown: View {
    let state: SleepTimerAttributes.ContentState

    var body: some View {
        if let end = state.endDate, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true, showsHours: true)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        } else {
            Text(formatRemaining(state.timerRemaining))
        }
    }
}

private func formatRemaining(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
