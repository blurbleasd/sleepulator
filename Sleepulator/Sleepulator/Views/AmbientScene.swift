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

/// "Rain on glass": a misted window with soft lights behind and droplets sliding down the
/// glass. Ambient (not time-reactive); pairs naturally with the rain sound.
struct RainOnGlassScene: AmbientScene {
    let id = "rain-on-glass"
    let title = "Rain on glass"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(RainGlassView(paused: ctx.paused))
    }
}

// MARK: - Registry

/// Lists every scene and resolves a persisted selection id to a scene. Selection itself lives
/// as @AppStorage in the views (keys `sceneSleep` / `sceneFocus`) so changing it re-renders
/// the home; the registry just enumerates + resolves. Invariant: every mood has >= 1 scene.
enum SceneRegistry {
    static let all: [any AmbientScene] = [NightSkyScene(), RainOnGlassScene(), EnergyScene()]

    static func scenes(for mood: SceneMood) -> [any AmbientScene] {
        all.filter { $0.mood == mood }
    }

    /// Resolve a selection id to a scene, falling back to the mood's first registered scene.
    static func scene(id: String, mood: SceneMood) -> any AmbientScene {
        let candidates = scenes(for: mood)
        return candidates.first(where: { $0.id == id }) ?? candidates[0]
    }
}
