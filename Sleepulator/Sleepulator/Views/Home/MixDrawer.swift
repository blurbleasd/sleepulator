import SwiftUI

// The "Build mix" drawer — all the detailed controls (mixer, master volume, save / saved
// mixes) live here so the main screen stays calm and art-first.
struct MixDrawer: View {
    @ObservedObject var audio: AudioEngine
    /// Observed directly so the saved-mixes row refreshes when a preset is saved / renamed /
    /// deleted, after Phase 3 dropped the mixStore objectWillChange forward into AudioEngine.
    @ObservedObject var mixStore: MixStore
    let pal: Palette
    /// Called when the user taps the podcast layer with no episode loaded — closes the drawer
    /// and routes to the Podcasts tab.
    var onPickEpisode: () -> Void = {}
    @AppStorage("sceneSleep") private var sleepSceneId = "night-sky"
    @AppStorage("sceneFocus") private var focusSceneId = "current"
    @State private var showNameDialog = false
    @State private var draftName = ""
    @State private var showOverwriteConfirm = false
    @State private var pendingPresetName = ""

    private var currentMode: String { audio.focusMode ? "focus" : "sleep" }
    private var modePresets: [SoundPreset] { mixStore.savedPresets.filter { $0.mode == currentMode } }
    private var canSaveMix: Bool { audio.noiseOn || audio.binauralOn }

    var body: some View {
        ScrollView {
            VStack(spacing: UI.lg) {
                Text("Your mix")
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundColor(pal.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, UI.xl)

                MixPanel(audio: audio, pal: pal, onPickEpisode: onPickEpisode)

                HomeBottomBar(audio: audio, pal: pal)
                    .padding(.top, UI.xs)

                if canSaveMix {
                    Button(action: {
                        draftName = audio.defaultPresetName()
                        showNameDialog = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.square.on.square")
                            Text("Save mix").font(.subheadline.bold())
                        }
                        .foregroundColor(pal.accent)
                        .padding(.horizontal, UI.lg).padding(.vertical, 10)
                        .background(Capsule().fill(pal.accent.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(
                            LinearGradient(colors: [pal.accent.opacity(0.5), pal.accent.opacity(0.12)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    }
                }

                if !modePresets.isEmpty {
                    SavedMixesList(audio: audio, presets: modePresets, pal: pal)
                }

                SceneSelector(mood: audio.focusMode ? .focus : .sleep,
                              selectedId: audio.focusMode ? $focusSceneId : $sleepSceneId,
                              pal: pal)
            }
            .padding(.vertical, UI.xl)
        }
        // No opaque fill here — the sheet's presentationBackground (a translucent dusk tint) lets
        // the home scene show through so the glass rows refract living content.
        .preferredColorScheme(.dark)
        // "Name your mix" + a text field is self-evident — no explanatory message line.
        .alert("Name your mix", isPresented: $showNameDialog) {
            TextField("Mix name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = trimmed.isEmpty ? audio.defaultPresetName() : trimmed
                if audio.presetWouldOverwrite(named: resolved) {
                    // Don't clobber a same-name preset silently — confirm first. Defer to the next
                    // runloop so this alert fully dismisses before the confirm alert presents.
                    pendingPresetName = resolved
                    DispatchQueue.main.async { showOverwriteConfirm = true }
                } else {
                    audio.savePreset(named: resolved)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Replace this mix?", isPresented: $showOverwriteConfirm) {
            Button("Replace", role: .destructive) {
                audio.savePreset(named: pendingPresetName)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("“\(pendingPresetName)” already exists in this mode. Replacing it overwrites the saved sounds.")
        }
    }
}

