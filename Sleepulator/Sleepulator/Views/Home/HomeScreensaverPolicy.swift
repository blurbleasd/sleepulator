import SwiftUI

/// When the Home chrome may fade to the bare backdrop (the ambient screensaver). Pure, so the rules
/// are unit-tested: the screensaver hides every control *and* the tab bar, so getting it wrong
/// strands the user on a blank sky.
enum HomeScreensaverPolicy {
    /// Seconds without a touch before the chrome fades. Sleep fades fast (you want the room dark
    /// quickly); Focus lingers longer — the session readout is useful mid-work, and a good Focus
    /// scene encodes the Pomodoro progress anyway, so losing the numbers to the scene is no loss.
    static func idleDelay(focusMode: Bool) -> TimeInterval { focusMode ? 10 : 3 }

    /// The screensaver is for a session in progress, never an idle app — with nothing playing it
    /// blanked a first launch (coachmark, tab bar and all) three seconds in. It also never engages:
    ///   • under VoiceOver / Switch Control — SwiftUI drops opacity-0 views from the accessibility
    ///     tree, so a faded Home left those users a 3 s window to reach any control, and moving
    ///     focus isn't a touch, so it never pushed the countdown back;
    ///   • while a Home sheet or cover is up — work in the sheet doesn't reach Home's idle timer,
    ///     so dismissing it used to land on a blank screen.
    static func mayFade(sessionActive: Bool, assistiveTechRunning: Bool, presenting: Bool) -> Bool {
        sessionActive && !assistiveTechRunning && !presenting
    }

    /// A session worth handing the screen to the scene: any engine audio, Apple Music (a separate
    /// system player, deliberately outside `isAnythingPlaying`), or a Pomodoro running silently —
    /// a good Focus scene encodes its progress.
    static func sessionActive(audioPlaying: Bool, appleMusicOn: Bool, pomodoroRunning: Bool) -> Bool {
        audioPlaying || appleMusicOn || pomodoroRunning
    }

    /// How far hiding the tab bar moved each safe-area edge (bottom on iPhone, top on iPad's top
    /// tab bar). Padded back onto the controls so they hold position while the chrome fades.
    /// `anchored` is the inset measured while the tab bar showed; zero whenever it shows again.
    static func chromeLift(anchored: EdgeInsets, live: EdgeInsets) -> EdgeInsets {
        EdgeInsets(top: max(0, anchored.top - live.top), leading: 0,
                   bottom: max(0, anchored.bottom - live.bottom), trailing: 0)
    }
}
