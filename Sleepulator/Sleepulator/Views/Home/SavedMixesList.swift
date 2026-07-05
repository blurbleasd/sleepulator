import SwiftUI

struct SavedMixesList: View {
    @ObservedObject var audio: AudioEngine
    let presets: [SoundPreset]
    let pal: Palette
    @State private var renaming: SoundPreset?
    @State private var draftName = ""

    private func mixSummary(_ p: SoundPreset) -> String {
        var parts: [String] = []
        if p.noiseOn { parts.append(p.noiseType.capitalized) }
        if p.binauralOn { parts.append(p.binauralPreset.capitalized) }
        return parts.isEmpty ? "Silent" : parts.joined(separator: " + ")
    }

    /// True when this preset's sound *recipe* matches what's playing right now — the card wears a
    /// "now playing" rim. Stateless: it compares live engine state, so swapping a sound or toggling
    /// a layer clears it (volume tweaks do NOT — levels aren't part of the recipe). A silent preset
    /// never matches, so an idle mixer highlights nothing. Extra stacked layers are folded in when
    /// the noise bed is on, so "Brown" and "Brown + Rain" can't both light up at once.
    private func isActive(_ p: SoundPreset) -> Bool {
        guard p.noiseOn || p.binauralOn else { return false }
        guard p.noiseOn == audio.noiseOn, (!p.noiseOn || p.noiseType == audio.noiseType),
              p.binauralOn == audio.binauralOn, (!p.binauralOn || p.binauralPreset == audio.binauralPreset)
        else { return false }
        guard p.noiseOn else { return true }   // extra layers only play with the noise bed
        let live = audio.extraLayers.filter { !($0.muted ?? false) }.map(\.type).sorted()
        let saved = (p.extraLayers ?? []).filter { !($0.muted ?? false) }.map(\.type).sorted()
        return live == saved
    }

    // A horizontal row of compact preset cards — tap to apply (sounds swap, any podcast keeps
    // playing), long-press to rename or delete.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved mixes")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(pal.dim)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets, id: \.id) { (mix: SoundPreset) in
                        let active = isActive(mix)
                        Button(action: {
                            audio.applyPreset(mix)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mix.name)
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundColor(pal.text)
                                    .lineLimit(1)
                                Text(mixSummary(mix))
                                    .font(.caption2)
                                    // Bright cream when active (legible) — accent-on-accent-tint
                                    // fell below AA, the same reason chips use cream when selected.
                                    .foregroundColor(active ? pal.text : pal.dim)
                                    .lineLimit(1)
                            }
                            .frame(width: 132, alignment: .leading)
                            .padding(.horizontal, UI.lg)
                            .padding(.vertical, UI.md)
                            // Active card wears a brighter accent rim + a touch more fill — a
                            // "now playing" cue, no glow (the drawer is a look-at-it surface,
                            // but keep to warmth-not-brightness per the house rule).
                            .background(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
                                .fill(pal.accent.opacity(active ? 0.18 : 0.12)))
                            .overlay(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [pal.accent.opacity(active ? 0.7 : 0.35),
                                                                      pal.accent.opacity(active ? 0.2 : 0.08)],
                                                             startPoint: .top, endPoint: .bottom),
                                              lineWidth: active ? 1 : 0.5))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { draftName = mix.name; renaming = mix } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) { audio.deletePreset(mix) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityLabel("\(active ? "Now playing: " : "Apply mix ")\(mix.name)")
                        .accessibilityHint("Long press to rename or delete")
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .alert("Rename mix", isPresented: Binding(get: { renaming != nil },
                                                  set: { if !$0 { renaming = nil } })) {
            TextField("Mix name", text: $draftName)
            Button("Save") {
                if let m = renaming { audio.renamePreset(m, to: draftName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

struct WarmMixerRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    @Binding var volume: Double
    let pal: Palette
    var onToggle: (() -> Void)? = nil
    
    var options: [String] = []
    var optionLabels: [String: String]? = nil
    var selection: Binding<String>? = nil
    var customMenu: AnyView? = nil

    @Environment(\.dynamicTypeSize) private var typeSize

    private var rowToggle: some View {
        Toggle("", isOn: Binding(
            get: { isOn },
            set: { newValue in
                if let action = onToggle { action() }
                else { isOn = newValue }
            }
        ))
        .labelsHidden()
        .toggleStyle(SwitchToggleStyle(tint: pal.accent))
        .accessibilityLabel(Text(title))   // VoiceOver: identify which layer this switch is
    }

    @ViewBuilder private var iconAndTitle: some View {
        Image(systemName: icon)
            .frame(minWidth: 30)
            .foregroundColor(isOn ? pal.accent : pal.dim)
            .font(.title3)
            .accessibilityHidden(true)

        if let custom = customMenu {
            custom
        } else {
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundColor(isOn ? pal.text : pal.dim)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            // At accessibility text sizes the fixed-width UISwitch can't share a row with a
            // grown title — drop it to a second line instead of truncating the title.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) { iconAndTitle; Spacer() }
                    HStack { Spacer(); rowToggle }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    iconAndTitle
                    Spacer()
                    rowToggle
                }
            }

            // Volume + sound picker appear only when the layer is ON, so an idle layer is a
            // single tight row instead of a tall panel — big space win when most are off.
            if isOn {
                VolumeBar(value: $volume, accent: pal.accent, thumbColor: pal.text, onEditingChanged: { editing in
                    if editing { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    else { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                })
                .accessibilityLabel(Text("\(title) volume"))

                if let sel = selection, !options.isEmpty {
                    ChipRow(options: options, labels: optionLabels, selection: sel, palette: pal)
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }
}

