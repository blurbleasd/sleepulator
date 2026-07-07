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
    /// True when the screen is actually occluded — the night-dim veil, backgrounding, or a
    /// low-luminance/Always-On display — so scenes settle to static for battery. NOT the
    /// lighter controls-faded screensaver: scenes keep animating through that (it's the show).
    /// See `HomeView.scenesFrozen` / the `nightDimmed → audio.screenDimmed` hand-off.
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
                ShootingStarView(paused: ctx.paused, sleepTimer: ctx.sleepTimer)
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

// (EnergyScene retired 2026-07-06 — a rotating blurred glow with no depth/reactivity; a weak
// concept Metal wouldn't save. Focus now defaults to "current". FocusBackdrop in Backdrops.swift
// is now dead code, safe to delete in a cleanup pass.)

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

#if DEBUG
/// DEBUG-only A/B sibling of `CurrentScene`: the Metal edition (a domain-warped FBM flow-field
/// shader — CurrentShader.metal `currentField` via `CurrentMetalView`, driven by the shared
/// `FocusDrivers` mapping so it reads the Pomodoro identically to the Canvas Current). Registered
/// alongside the Canvas scene so the two can be compared on a real device over a full, *unoccluded*
/// Focus session (look + thermal + battery — Focus never freezes like the Sleep scenes do, so this
/// is the real power test). Reduce Motion feeds the flow clock rate 0 → static field. Retire
/// `CurrentScene` once this clearly wins; take the thermal verdict from a Release/Profile build.
struct CurrentMetalScene: AmbientScene {
    let id = "current-metal"
    let title = "Current (Metal)"
    let mood = SceneMood.focus

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(CurrentMetalView(paused: ctx.paused, pomodoro: ctx.pomodoro,
                                 reduceMotion: ctx.reduceMotion))
    }
}
#endif

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

#if DEBUG
/// DEBUG-only A/B sibling of `TideScene`: the Metal edition (`TideShader.metal` `tideField` via
/// `TideMetalView`) — a per-pixel water level whose height tracks the Pomodoro, with an FBM-
/// modulated surface, depth shading, a crisp waterline and specular glints, instead of the flat
/// Canvas fill. Reduce Motion stills the surface. A/B against the Canvas Tide on device; promote
/// once it wins. (Deep work retired 2026-07-06 — invisible-by-design, a weak concept.)
struct TideMetalScene: AmbientScene {
    let id = "tide-metal"
    let title = "Tide (Metal)"
    let mood = SceneMood.focus

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(TideMetalView(paused: ctx.paused, pomodoro: ctx.pomodoro,
                              reduceMotion: ctx.reduceMotion))
    }
}
#endif

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
    /// The drops' far world parallaxes with gyro (held-in-hand bonus); flat on a nightstand it
    /// still reads deep from focus + refraction. HomeView.reconcileMotion gates CoreMotion on this.
    var usesMotion: Bool { true }

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(RainGlassDepthView(paused: ctx.paused,
                                   sleepTimer: ctx.sleepTimer,
                                   tilt: ctx.tilt))
    }
}
#endif

/// "Breathe": a soft warm glow that swells and fades on a slow breath cadence — follow it and
/// your own breath slows. The most directly lulling scene (entrainment, not just ambience).
/// Takes the timer so the glow dims with the night (read live inside its own redraw, per the
/// animating-scene convention) — it was the only sleep scene that stayed bedtime-bright at
/// nightProgress 1.
struct BreathingBloomScene: AmbientScene {
    let id = "breathing-bloom"
    let title = "Breathe"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(BreathingBloomView(paused: ctx.paused, sleepTimer: ctx.sleepTimer))
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

// (The CPU `AuroraView` A/B sibling was retired 2026-07-04 — the Metal aurora won the
// on-device comparison; the canvas version read as dim and near-static.)

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

/// DEBUG-only A/B sibling: the **depth edition** of Still Water — the ocean generalization of the
/// rain-glass depth recipe (RAIN-ON-GLASS-DEPTH-SPEC §2). Rides the shared `.layerEffect`
/// `DepthBackdrop`: the near swell refracts a composited far world (sky + moon + hazy horizon) into a
/// wave-distorted reflection — near-sharp swell, far-soft horizon — reactive via `DepthReactivity`
/// (F1). Second consumer of the depth host (the trigger that justified building it). A/B against
/// `StillWaterScene` on device; retire the flat one if the depth version wins (§10).
struct StillWaterDepthScene: AmbientScene {
    let id = "still-water-depth"
    let title = "Still water (depth)"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(StillWaterDepthView(paused: ctx.paused, sleepTimer: ctx.sleepTimer))
    }
}

/// DEBUG-only A/B sibling: the STRUCTURAL audio-reactivity variant of the flat Metal Still Water.
/// Same `stillWaterField` shader but `reactive: true`, so audio disturbs the wave FIELD (the moon
/// reflection shimmers/breaks up with the bed) instead of a global brightness swell. A/B against
/// `StillWaterScene` over a pre-sleep session with audio playing: does the structural response read
/// better AND stay subtle enough not to wake you? Promote (make it the default + delete the shader's
/// `reactive < 0.5` branch) once it wins on device. Passes `reduceMotion` so it falls to the calm
/// branch under Reduce Motion. (Orthogonal to `StillWaterDepthScene`, which is the layer-lens depth
/// A/B — this one is about audio response on the flat scene.)
struct StillWaterReactiveScene: AmbientScene {
    let id = "still-water-reactive"
    let title = "Still water (reactive)"
    let mood = SceneMood.sleep

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(StillWaterMetalView(paused: ctx.paused, sleepTimer: ctx.sleepTimer,
                                    audioLevel: ctx.audioLevel, reactive: true,
                                    reduceMotion: ctx.reduceMotion))
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

#if DEBUG
/// DEBUG-only A/B sibling of `SandfallScene`: the Metal edition (`SandfallShader.metal`
/// `sandField` via `SandfallMetalView`) — a procedural hourglass with FBM-granular sand in both
/// bulbs, the top draining and the bottom mounding as the Pomodoro runs, and a turbulent falling
/// column through the neck, instead of 14 stiff Canvas grains. Reduce Motion stills the fall.
/// A/B against the Canvas Sandfall on device; promote once it wins.
struct SandfallMetalScene: AmbientScene {
    let id = "sandfall-metal"
    let title = "Sandfall (Metal)"
    let mood = SceneMood.focus

    func makeBackdrop(_ ctx: SceneContext) -> AnyView {
        AnyView(SandfallMetalView(paused: ctx.paused, pomodoro: ctx.pomodoro,
                                  reduceMotion: ctx.reduceMotion))
    }
}
#endif

// MARK: - Registry

/// Lists every scene and resolves a persisted selection id to a scene. Selection itself lives
/// as @AppStorage in the views (keys `sceneSleep` / `sceneFocus`) so changing it re-renders
/// the home; the registry just enumerates + resolves. Invariant: every mood has >= 1 scene.
enum SceneRegistry {
    static let all: [any AmbientScene] = {
        var scenes: [any AmbientScene] = [NightSkyScene(), RainOnGlassScene()]
        #if DEBUG
        scenes.append(RainOnGlassDepthScene())     // A/B sibling, DEBUG builds only
        scenes.append(StillWaterCanvasScene())     // A/B vs the Metal still water, DEBUG builds only
        scenes.append(StillWaterDepthScene())      // depth A/B vs the flat Metal still water, DEBUG only
        scenes.append(StillWaterReactiveScene())   // A/B: structural audio reactivity, DEBUG builds only
        scenes.append(EmbersCanvasScene())         // A/B vs the dark Metal embers, DEBUG builds only
        scenes.append(CurrentMetalScene())         // A/B vs the Canvas Current (Focus), DEBUG builds only
        scenes.append(TideMetalScene())            // A/B vs the Canvas Tide (Focus), DEBUG builds only
        scenes.append(SandfallMetalScene())        // A/B vs the Canvas Sandfall (Focus), DEBUG builds only
        #endif
        scenes.append(contentsOf: [
            BreathingBloomScene(), AuroraScene(), EmbersScene(), StillWaterScene(), DeepSpaceScene(),
            CurrentScene(), TideScene(), SandfallScene()
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
