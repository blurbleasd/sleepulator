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
    /// A smoothed, normalized audio level (~0…1) for audio-reactive scenes. A *closure* (not a
    /// stored value) so scenes sample it live inside their own redraw without observing — and
    /// without reaching into `AudioEngine` directly. Defaults to silence for previews/tests.
    var audioLevel: () -> Double = { 0 }
    /// Smoothed gyro tilt (x = roll, y = pitch, each ~[-1, 1]) for parallax scenes — sampled
    /// live, never observed. `.zero` when no motion-using scene is active. Closure for the same
    /// reasons as `audioLevel`.
    var tilt: () -> SIMD2<Float> = { .zero }
}

/// A self-contained ambient backdrop for the home screen. The point of the protocol is that
/// adding a new look is "conform + register," not surgery on HomeView. (Phase 1 of
/// SCREENSAVER-LIBRARY-SPEC: just the seam — the two existing backdrops move behind this with
/// no visual change. A picker / thumbnails come later, if ever.)
protocol AmbientScene {
    var id: String { get }
    var title: String { get }
    var mood: SceneMood { get }
    /// True if the scene reads `SceneContext.tilt` for gyro parallax — the owner uses this to
    /// gate CoreMotion so it runs *only* for a motion-using, on-screen, non-dimmed scene.
    var usesMotion: Bool { get }
    func makeBackdrop(_ ctx: SceneContext) -> AnyView
}

extension AmbientScene {
    /// Most scenes don't use motion; they opt in by overriding this.
    var usesMotion: Bool { false }
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

/// Fades arbitrary backdrop content toward dark as the sleep timer winds down — the
/// general-purpose sibling of `NightDarken`, used for the warm static layers (the embers
/// hearth glow, the rain-glass bokeh) that should dim with the night. Isolated so it
/// re-renders only on the timer's ~1 Hz republish, never dragging its parent (or a sibling
/// `TimelineView` animation loop) into a re-render. Animating Canvas layers don't use this —
/// they read `nightProgress` live inside their own redraw instead.
struct NightFade<Content: View>: View {
    @ObservedObject var timer: SleepTimerService
    /// Opacity removed at full night (`nightProgress == 1`). 0.8 → fades to a faint glow.
    var maxDim: Double = 0.8
    @ViewBuilder var content: Content
    var body: some View {
        content.opacity(1 - maxDim * timer.nightProgress)
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
        AnyView(RainGlassView(paused: ctx.paused, sleepTimer: ctx.sleepTimer))
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

/// "Aurora": flowing curtains of dim light over near-black. Now a Metal fragment shader
/// (`AuroraShader.metal`) — a continuous domain-warped FBM field with dithering + a filmic
/// roll-off, replacing the old striated-rectangle Canvas. Wandering, focal-point-free.
struct AuroraScene: AmbientScene {
    let id = "aurora"
    let title = "Aurora"
    let mood = SceneMood.sleep
    var usesMotion: Bool { true }   // curtains shift with gyro parallax during the watching window

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(AuroraMetalView(paused: ctx.paused, sleepTimer: ctx.sleepTimer,
                                audioLevel: ctx.audioLevel, tilt: ctx.tilt))
    }
}

#if DEBUG
/// DEBUG-only A/B sibling: the original CPU `AuroraView` (Canvas striations). Registered next to
/// the shipping Metal aurora so the two can be compared on a real device over a full timer run
/// (the CLAUDE.md device gate). Retire `AuroraView.swift` once the shader clearly wins on look +
/// power.
struct AuroraCanvasScene: AmbientScene {
    let id = "aurora-canvas"
    let title = "Aurora (canvas)"
    let mood = SceneMood.sleep
    var usesMotion: Bool { true }

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(AuroraView(paused: ctx.paused, sleepTimer: ctx.sleepTimer,
                           audioLevel: ctx.audioLevel, tilt: ctx.tilt))
    }
}
#endif

/// "Embers": smoldering coals — a dark field of deep reds slowly churning on a gentle swirl.
/// A Metal fragment shader (`EmbersShader.metal`), dark + hypnotic with slow motion (the first
/// fire take was reverted as too stimulating; this one caps brightness and drops the sparks).
struct EmbersScene: AmbientScene {
    let id = "embers"
    let title = "Embers"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(EmbersMetalView(paused: ctx.paused, sleepTimer: ctx.sleepTimer, audioLevel: ctx.audioLevel))
    }
}

#if DEBUG
/// DEBUG-only A/B sibling: the original CPU `EmbersView` (drifting motes), for on-device
/// comparison against the dark smoldering shader.
struct EmbersCanvasScene: AmbientScene {
    let id = "embers-canvas"
    let title = "Embers (canvas)"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(EmbersView(paused: ctx.paused, sleepTimer: ctx.sleepTimer, audioLevel: ctx.audioLevel))
    }
}
#endif

/// "Still water": a low moon over a dark pond, its reflected path shimmering on the surface with
/// faint concentric ripples. Now a Metal fragment shader (`StillWaterShader.metal`) — a per-pixel
/// FBM wave field with real specular glints, replacing the old wireframe ellipse rings.
struct StillWaterScene: AmbientScene {
    let id = "still-water"
    let title = "Still water"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(StillWaterMetalView(paused: ctx.paused, sleepTimer: ctx.sleepTimer, audioLevel: ctx.audioLevel))
    }
}

#if DEBUG
/// DEBUG-only A/B sibling: the original CPU `StillWaterView` (stroked ellipse rings), kept for
/// on-device comparison against the Metal shader over a full timer run. Retire `StillWaterView.swift`
/// once the shader clearly wins on look + power.
struct StillWaterCanvasScene: AmbientScene {
    let id = "still-water-canvas"
    let title = "Still water (canvas)"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(StillWaterView(paused: ctx.paused, sleepTimer: ctx.sleepTimer, audioLevel: ctx.audioLevel))
    }
}
#endif

/// "Deep space" (Sleep): a slow nebula of domain-warped FBM cloud over a parallax star field,
/// with a rare comet. A Metal showpiece (`DeepSpaceShader.metal`); no CPU predecessor.
struct DeepSpaceScene: AmbientScene {
    let id = "deep-space"
    let title = "Deep space"
    let mood = SceneMood.sleep
    var usesMotion: Bool { true }   // nebula + star tiers parallax with gyro during the watching window

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(DeepSpaceMetalView(paused: ctx.paused, sleepTimer: ctx.sleepTimer,
                                   audioLevel: ctx.audioLevel, tilt: ctx.tilt))
    }
}

/// "Sandfall" (Focus): an abstract hourglass whose sand level tracks the Pomodoro — a tactile,
/// numberless read on how far through the current interval you are.
struct SandfallScene: AmbientScene {
    let id = "sandfall"
    let title = "Sandfall"
    let mood = SceneMood.focus

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(SandfallView(paused: ctx.paused, pomodoro: ctx.pomodoro))
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
        scenes.append(RainOnGlassDepthScene())     // A/B sibling, DEBUG builds only
        scenes.append(AuroraCanvasScene())         // A/B vs the Metal aurora, DEBUG builds only
        scenes.append(StillWaterCanvasScene())     // A/B vs the Metal still water, DEBUG builds only
        scenes.append(EmbersCanvasScene())         // A/B vs the dark Metal embers, DEBUG builds only
        #endif
        scenes.append(contentsOf: [
            BreathingBloomScene(), AuroraScene(), EmbersScene(), StillWaterScene(), DeepSpaceScene(),
            EnergyScene(), CurrentScene(), TideScene(), DeepWorkScene(), SandfallScene()
        ] as [any AmbientScene])
        return scenes
    }()

    static func scenes(for mood: SceneMood) -> [any AmbientScene] {
        all.filter { $0.mood == mood }
    }

    /// Resolve a selection id to a scene, falling back to the mood's first registered scene.
    static func scene(id: String, mood: SceneMood) -> any AmbientScene {
        let candidates = scenes(for: mood)
        return candidates.first(where: { $0.id == id }) ?? candidates.first ?? NightSkyScene()
    }
}
