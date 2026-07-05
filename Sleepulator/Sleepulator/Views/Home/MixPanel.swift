import SwiftUI

struct MixPanel: View {
    @ObservedObject var audio: AudioEngine
    let pal: Palette
    var onPickEpisode: () -> Void = {}
    @State private var showingMusicPicker = false

    /// The noise sounds available in the current mode (Sleep vs Focus palettes share no sounds).
    private var noisePalette: [String] {
        audio.focusMode ? ["pink", "fan", "white", "gray"] : ["brown", "rain", "ocean", "pink", "green", "forest"]
    }

    var body: some View {
        VStack(spacing: 10) {
            // Podcast is on/off + volume like the other layers — episode picking lives in the
            // Library tab and the mini-player, not an impractical inline dropdown. With no episode
            // loaded the toggle has nothing to play, so the row becomes a clear call-to-action that
            // routes to the Podcasts tab instead of a switch that silently does nothing.
            if audio.hasLoadedEpisode {
                WarmMixerRow(
                    icon: "mic.fill",
                    title: audio.isPodPlaying ? audio.podTitle : "Podcast",
                    isOn: $audio.isPodPlaying,
                    volume: $audio.podVolume,
                    pal: pal,
                    onToggle: { audio.togglePodcast() }
                )
                .glassPanel(pal)
            } else {
                // Empty state: one clean line + a chevron. The chevron *is* "tap to choose" — a
                // "Choose an episode" caption underneath only restated it (and was unreadable dim
                // 11pt at 2am anyway).
                Button(action: onPickEpisode) {
                    HStack(spacing: UI.md) {
                        Image(systemName: "mic.fill")
                            .frame(minWidth: 30)
                            .foregroundColor(pal.dim)
                            .font(.title3)
                        Text("Podcast")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(pal.dim)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(pal.dim.opacity(0.7))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .glassPanel(pal)
                .accessibilityLabel("Podcast, no episode loaded")
                .accessibilityHint("Opens the Podcasts tab to choose an episode")
            }

            WarmMixerRow(
                icon: "waveform",
                title: audio.noiseType.capitalized,
                isOn: $audio.noiseOn,
                volume: $audio.noiseVolume,
                pal: pal,
                options: noisePalette,
                selection: $audio.noiseType
            )
            .glassPanel(pal)

            // Stacked extra noise layers (rain + brown, …). Only shown while the noise bed is
            // on, since the layers play *with* it. The switch MUTES the layer in place (type +
            // volume survive, engine declicks the slot to 0) — removal moved to the long-press
            // menu, so trying a layer on/off no longer destroys its settings.
            if audio.noiseOn {
                ForEach(audio.extraLayers) { layer in
                    WarmMixerRow(
                        icon: "plus.circle",
                        title: layer.type.capitalized,
                        isOn: Binding(
                            get: { !(layer.muted ?? false) },
                            set: { audio.setExtraLayerMuted(layer.id, !$0) }
                        ),
                        volume: Binding(
                            get: { layer.volume },
                            set: { audio.setExtraLayerVolume(layer.id, $0) }
                        ),
                        pal: pal,
                        options: noisePalette,
                        selection: Binding(
                            get: { layer.type },
                            set: { audio.setExtraLayerType(layer.id, $0) }
                        )
                    )
                    .glassPanel(pal)
                    .contextMenu {
                        Button(role: .destructive) {
                            audio.removeExtraLayer(layer.id)
                        } label: {
                            Label("Remove layer", systemImage: "trash")
                        }
                    }
                }

                if audio.extraLayers.count < AudioEngine.maxExtraLayers {
                    Button(action: {
                        audio.addExtraLayer()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }) {
                        Label("Add sound", systemImage: "plus.circle")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundColor(pal.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add another sound layer")
                }
            }

            WarmMixerRow(
                icon: "headphones",
                // Just "Binaural" — the selected preset is the chip's job below; a parenthetical
                // in the title said the same state twice.
                title: "Binaural",
                isOn: $audio.binauralOn,
                volume: $audio.binVolume,
                pal: pal,
                options: audio.focusMode ? ["alpha", "beta", "gamma"] : ["delta", "theta"],
                optionLabels: ["delta":"Deep","theta":"Drift","alpha":"Relax","beta":"Concentrate","gamma":"Focus"],
                selection: $audio.binauralPreset
            )
            .glassPanel(pal)

            // Apple Music — Focus only. DRM means it can't be a true mixer channel (no volume
            // slider / limiter); it plays alongside via the system player. See APPLE-MUSIC-FOCUS-SPEC.
            if audio.focusMode {
                AppleMusicMixRow(audio: audio, pal: pal) { showingMusicPicker = true }
                    .glassPanel(pal)
            }
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $showingMusicPicker) {
            AppleMusicPickerView(audio: audio)
        }
    }
}

/// The Focus-mode Apple Music row: a "choose music" call-to-action until something is selected,
/// then an on/off toggle. No volume slider on purpose — Apple Music plays at the device's system
/// music volume (the DRM stream can't be level-shaped in-app).
struct AppleMusicMixRow: View {
    @ObservedObject var audio: AudioEngine
    let pal: Palette
    var onPick: () -> Void

    var body: some View {
        if audio.hasAppleMusicSelection {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .frame(minWidth: 30)
                    .foregroundColor(audio.appleMusicOn ? pal.accent : pal.dim)
                    .font(.title3)
                // One line — the row is self-evident (music icon, a search affordance, a toggle).
                // "Plays over your sounds · device volume" was a spec footnote, not a control.
                Text(audio.appleMusicOn && !audio.appleMusicTitle.isEmpty ? audio.appleMusicTitle : "Apple Music")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(pal.text)
                    .lineLimit(1)
                Spacer()
                Button(action: onPick) {
                    Image(systemName: "magnifyingglass")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(pal.accent)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change Apple Music selection")
                Toggle("", isOn: Binding(
                    get: { audio.appleMusicOn },
                    set: { _ in audio.toggleAppleMusic() }
                ))
                .labelsHidden()
                .tint(pal.accent)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Apple Music")
        } else {
            Button(action: onPick) {
                HStack(spacing: UI.md) {
                    Image(systemName: "music.note")
                        .frame(minWidth: 30)
                        .foregroundColor(pal.dim)
                        .font(.title3)
                    Text("Apple Music")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(pal.dim)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(pal.dim.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel("Apple Music, nothing selected")
            .accessibilityHint("Opens Apple Music search to choose something to play")
        }
    }
}

