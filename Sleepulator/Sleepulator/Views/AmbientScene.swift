import SwiftUI

/// Which mode a scene belongs to.
enum SceneMood {
    case sleep, focus
}

/// Everything an ambient backdrop needs, handed in so scenes never reach into AudioEngine
/// directly. Add a field here when a future scene needs more (e.g. `pomodoro` for a
/// time-reactive focus scene); existing scenes ignore what they don't use.
struct SceneContext {
    let palette: Palette
    let reduceMotion: Bool
    /// True once the screensaver has engaged — scenes settle to static for battery.
    let paused: Bool
    /// The sleep timer, for time-reactive sleep scenes (e.g. the setting moon).
    let sleepTimer: SleepTimerService
}

/// A self-contained ambient backdrop for the home screen. The point of the protocol is that
/// adding a new look is "conform + register," not surgery on HomeView. (Phase 1 of
/// SCREENSAVER-LIBRARY-SPEC: just the seam — the two existing backdrops move behind this with
/// no visual change. A picker / thumbnails come later, if ever.)
protocol AmbientScene {
    var id: String { get }
    var title: String { get }
    var mood: SceneMood { get }
    func makeBackdrop(_ ctx: SceneContext) -> AnyView
}

// MARK: - The built-in scenes (wrap today's backdrops verbatim)

/// The default Sleep backdrop: a realistic night sky with a phase-correct setting moon that
/// rides the sleep timer down its arc, a rare meteor, and a sky that deepens toward black as
/// the night ends. (Composed exactly as the old hardcoded HomeView branch.)
struct NightSkyScene: AmbientScene {
    let id = "night-sky"
    let title = "Night sky"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(
            ZStack {
                StarfieldView(paused: ctx.paused)
                    .ignoresSafeArea()
                MoonArc(sleepTimer: ctx.sleepTimer)
                    .ignoresSafeArea()
                ShootingStarView()
                    .ignoresSafeArea()
                Color.black
                    .opacity(ctx.sleepTimer.nightProgress * 0.35)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        )
    }
}

/// The default Focus backdrop: a slow cool "energy" sweep over the deep-indigo gradient.
struct EnergyScene: AmbientScene {
    let id = "energy"
    let title = "Energy"
    let mood = SceneMood.focus

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(FocusBackdrop(accent: ctx.palette.accent, reduceMotion: ctx.reduceMotion))
    }
}

// MARK: - Registry

/// Lists every scene and resolves the selected one per mood. Selection persists in
/// UserDefaults (`sceneSleep` / `sceneFocus`) and defaults to the mood's first registered
/// scene — so with one scene per mood today, this is effectively the default until a picker
/// exists. Invariant: every mood has at least one scene.
enum SceneRegistry {
    static let all: [any AmbientScene] = [NightSkyScene(), EnergyScene()]

    static func scenes(for mood: SceneMood) -> [any AmbientScene] {
        all.filter { $0.mood == mood }
    }

    private static func key(for mood: SceneMood) -> String {
        mood == .sleep ? "sceneSleep" : "sceneFocus"
    }

    static func selected(for mood: SceneMood) -> any AmbientScene {
        let candidates = scenes(for: mood)
        let saved = UserDefaults.standard.string(forKey: key(for: mood))
        return candidates.first(where: { $0.id == saved }) ?? candidates[0]
    }

    static func select(_ scene: any AmbientScene) {
        UserDefaults.standard.set(scene.id, forKey: key(for: scene.mood))
    }
}
