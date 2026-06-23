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
    /// The Pomodoro, for time-reactive Focus scenes (work/break phase + progress).
    let pomodoro: PomodoroService
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

/// The default Sleep backdrop: a calm, slowly drifting starfield with a gentle breathing
/// brightness, a rare meteor, and a sky that deepens toward black as the sleep timer winds
/// down. Built to lull — continuous + dim, with no bright focal point.
struct NightSkyScene: AmbientScene {
    let id = "night-sky"
    let title = "Night sky"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(
            ZStack {
                StarfieldView(paused: ctx.paused)
                    .ignoresSafeArea()
                ShootingStarView()
                    .ignoresSafeArea()
                // Darkening must observe the timer itself: nightProgress is computed (not
                // @Published) and the timer is no longer forwarded through `audio`, so HomeView
                // stops re-rendering each second — without this leaf the sky would freeze.
                NightDarken(timer: ctx.sleepTimer)
            }
            .ignoresSafeArea()
        )
    }
}

/// The sleep sky-darkening overlay, isolated so it re-renders on each timer tick (it observes the
/// timer directly) rather than relying on its parent's per-second re-render.
private struct NightDarken: View {
    @ObservedObject var timer: SleepTimerService
    var body: some View {
        Color.black
            .opacity(timer.nightProgress * 0.35)
            .ignoresSafeArea()
            .allowsHitTesting(false)
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

/// "Current" (Focus): cool streams that quicken/brighten through a work interval and ease on a
/// break — momentum without flicker.
struct CurrentScene: AmbientScene {
    let id = "current"
    let title = "Current"
    let mood = SceneMood.focus

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(CurrentView(paused: ctx.paused, pomodoro: ctx.pomodoro))
    }
}

/// "Tide" (Focus): a calm cool level that rises across a work interval and recedes on a break —
/// an ambient, glanceable progress cue.
struct TideScene: AmbientScene {
    let id = "tide"
    let title = "Tide"
    let mood = SceneMood.focus

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(TideView(paused: ctx.paused, pomodoro: ctx.pomodoro))
    }
}

/// "Deep work" (Focus): a near-minimal cool field, crispest mid-session and softer at the
/// boundaries — the calmest, lowest-distraction backdrop.
struct DeepWorkScene: AmbientScene {
    let id = "deep-work"
    let title = "Deep work"
    let mood = SceneMood.focus

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(DeepWorkView(paused: ctx.paused, pomodoro: ctx.pomodoro))
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

#if DEBUG
/// DEBUG-only A/B sibling of `RainOnGlassScene`: the depth edition (a procedural droplet-as-lens
/// Metal shader over a brightened far world — RAIN-ON-GLASS-DEPTH-SPEC.md). Registered alongside
/// the shipping rain scene so the two can be compared on a real device, propped at the bedside,
/// over a full timer run (§10). Retire `RainOnGlassScene` once this clearly wins on look + power.
struct RainOnGlassDepthScene: AmbientScene {
    let id = "rain-on-glass-depth"
    let title = "Rain (depth)"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(RainGlassDepthView(paused: ctx.paused))
    }
}
#endif

/// "Breathe": a soft warm glow that swells and fades on a slow breath cadence — follow it and
/// your own breath slows. The most directly lulling scene (entrainment, not just ambience).
struct BreathingBloomScene: AmbientScene {
    let id = "breathing-bloom"
    let title = "Breathe"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(BreathingBloomView(paused: ctx.paused))
    }
}

/// "Aurora": slow curtains of dim color sway and breathe over near-black, blended additively so
/// overlaps glow. Wandering, focal-point-free — the eye drifts and settles.
struct AuroraScene: AmbientScene {
    let id = "aurora"
    let title = "Aurora"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(AuroraView(paused: ctx.paused))
    }
}

/// "Embers": warm motes drift up from a faint hearth glow and fade — the cozy, candle-lit
/// counterpart to the cool starfield.
struct EmbersScene: AmbientScene {
    let id = "embers"
    let title = "Embers"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(EmbersView(paused: ctx.paused))
    }
}

/// "Still water": faint concentric ripples spread and fade on a dark moonlit pond — predictable
/// and rhythmic, meditative rather than attention-grabbing. Pairs with the rain / ocean sound.
struct StillWaterScene: AmbientScene {
    let id = "still-water"
    let title = "Still water"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(StillWaterView(paused: ctx.paused))
    }
}

// MARK: - Registry

/// Lists every scene and resolves a persisted selection id to a scene. Selection itself lives
/// as @AppStorage in the views (keys `sceneSleep` / `sceneFocus`) so changing it re-renders
/// the home; the registry just enumerates + resolves. Invariant: every mood has >= 1 scene.
enum SceneRegistry {
    static let all: [any AmbientScene] = {
        var scenes: [any AmbientScene] = [NightSkyScene(), RainOnGlassScene()]
        #if DEBUG
        scenes.append(RainOnGlassDepthScene())   // A/B sibling, DEBUG builds only
        #endif
        scenes.append(contentsOf: [
            BreathingBloomScene(), AuroraScene(), EmbersScene(), StillWaterScene(),
            EnergyScene(), CurrentScene(), TideScene(), DeepWorkScene()
        ] as [any AmbientScene])
        return scenes
    }()

    static func scenes(for mood: SceneMood) -> [any AmbientScene] {
        all.filter { $0.mood == mood }
    }

    /// Resolve a selection id to a scene, falling back to the mood's first registered scene.
    static func scene(id: String, mood: SceneMood) -> any AmbientScene {
        let candidates = scenes(for: mood)
        return candidates.first(where: { $0.id == id }) ?? candidates[0]
    }
}
