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
                                    .foregroundColor(pal.dim)
                                    .lineLimit(1)
                            }
                            .frame(width: 132, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(pal.accent.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(pal.accent.opacity(0.22), lineWidth: 0.5))
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
                        .accessibilityLabel("Apply mix \(mix.name)")
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
                VolumeBar(value: $volume, accent: pal.accent, onEditingChanged: { editing in
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

