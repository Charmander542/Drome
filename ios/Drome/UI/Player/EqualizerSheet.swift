import SwiftUI
import UIKit

/// Traditional graphic equalizer — vertical faders, presets, and a few sound options.
struct EqualizerSheet: View {
    @Binding var detent: PresentationDetent
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = AudioFXPreferences.equalizerEnabled
    @State private var bands = AudioFXPreferences.equalizerBands
    @State private var preset = AudioFXPreferences.equalizerPreset
    @State private var savedSlots = AudioFXPreferences.savedEqualizers
    @State private var replayGain = AudioFXPreferences.replayGainEnabled
    @State private var crossfade = AudioFXPreferences.crossfadeSeconds
    @State private var renameSlot: Int?
    @State private var renameText = ""

    private let gainRange: ClosedRange<Double> = -12...12
    private let gainLabelHeight: CGFloat = 16
    private let hzLabelHeight: CGFloat = 16

    private var isExpanded: Bool { detent == .large }
    private var trackHeight: CGFloat { isExpanded ? 188 : 148 }

    private var builtInPresets: [(String, [Float])] {
        AudioFXPreferences.presets.filter { $0.0 != "Custom" }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    header

                    graphicEQ
                        .padding(.horizontal, 16)
                        .padding(.top, 2)

                    savedSlotsRow
                        .padding(.top, 12)

                    presetsSection
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    Divider().overlay(DromeTheme.divider)

                    extras
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                }
            }
            .background(DromeTheme.background.ignoresSafeArea())
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("drome.equalizer.screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .tint(.white)
            .alert("Rename EQ", isPresented: Binding(
                get: { renameSlot != nil },
                set: { if !$0 { renameSlot = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renameSlot = nil }
                Button("Save") {
                    guard let slot = renameSlot else { return }
                    AudioFXPreferences.renameSavedEqualizer(slot: slot, name: renameText)
                    savedSlots = AudioFXPreferences.savedEqualizers
                    renameSlot = nil
                }
            } message: {
                Text("Give this saved EQ a short name.")
            }
            .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(enabled ? "EQ On" : "EQ Off")
                        .font(.headline)
                    Text(enabled ? "Dragging faders shapes the sound" : "Turn on to hear band changes")
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted)
                }
            }
            .tint(DromeTheme.accent)
            .onChange(of: enabled) { _, v in
                AudioFXPreferences.equalizerEnabled = v
                if v { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var graphicEQ: some View {
        HStack(alignment: .top, spacing: 10) {
            scaleColumn(trackHeight: trackHeight)
                .padding(.top, gainLabelHeight + 8)

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(AudioFXPreferences.bandFrequencies.enumerated()), id: \.offset) { index, hz in
                    EQFader(
                        value: binding(for: index),
                        label: bandLabel(hz),
                        range: gainRange,
                        trackHeight: trackHeight,
                        gainLabelHeight: gainLabelHeight,
                        hzLabelHeight: hzLabelHeight
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(DromeTheme.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                }
        }
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.2), value: enabled)
        .accessibilityElement(children: .contain)
    }

    private func scaleColumn(trackHeight: CGFloat) -> some View {
        ZStack {
            VStack {
                Text("+12")
                Spacer(minLength: 0)
                Text("−12")
            }
            Text("0")
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(DromeTheme.muted)
        .frame(width: 32, height: trackHeight, alignment: .center)
    }

    private var savedSlotsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DromeTheme.muted)
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                ForEach(0..<AudioFXPreferences.savedSlotCount, id: \.self) { index in
                    savedSlotChip(index: index)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func savedSlotChip(index: Int) -> some View {
        let slot = savedSlots.indices.contains(index) ? savedSlots[index] : nil
        let selected = AudioFXPreferences.savedSlotIndex(fromPreset: preset) == index

        return Group {
            if let slot {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        AudioFXPreferences.applySavedEqualizer(slot: index)
                        syncFromPreferences()
                    }
                } label: {
                    Text(slot.name)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? DromeTheme.accent : DromeTheme.elevated2)
                        )
                        .foregroundStyle(selected ? .black : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        AudioFXPreferences.saveCurrentEqualizer(to: index, name: slot.name)
                        syncFromPreferences()
                    } label: {
                        Label("Overwrite with current", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        renameText = slot.name
                        renameSlot = index
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        AudioFXPreferences.clearSavedEqualizer(slot: index)
                        syncFromPreferences()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
                .accessibilityLabel("Saved EQ \(slot.name)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            } else {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    AudioFXPreferences.saveCurrentEqualizer(to: index)
                    syncFromPreferences()
                } label: {
                    Label("Save", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.white.opacity(0.75))
                        .background {
                            ZStack {
                                Capsule(style: .continuous)
                                    .fill(DromeTheme.elevated.opacity(0.55))
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        Color.white.opacity(0.28),
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save current EQ to slot \(index + 1)")
            }
        }
    }

    @ViewBuilder
    private var presetsSection: some View {
        if isExpanded {
            presetList
        } else {
            presetCarousel
        }
    }

    private var presetCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(builtInPresets, id: \.0) { name, bands in
                    Button {
                        applyBuiltInPreset(name)
                    } label: {
                        HStack(spacing: 8) {
                            EQPresetGraphIcon(bands: bands, selected: preset == name)
                                .frame(width: 36, height: 22)
                            Text(name)
                                .font(.caption.weight(.bold))
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(preset == name ? DromeTheme.accent : DromeTheme.elevated2)
                        )
                        .foregroundStyle(preset == name ? .black : .white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DromeTheme.muted)
                .padding(.horizontal, 16)

            VStack(spacing: 6) {
                ForEach(builtInPresets, id: \.0) { name, bands in
                    Button {
                        applyBuiltInPreset(name)
                    } label: {
                        HStack(spacing: 14) {
                            EQPresetGraphIcon(bands: bands, selected: preset == name)
                                .frame(width: 56, height: 34)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(preset == name
                                              ? DromeTheme.accent.opacity(0.18)
                                              : Color.white.opacity(0.04))
                                )

                            Text(name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)

                            Spacer(minLength: 0)

                            if preset == name {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DromeTheme.accent)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(preset == name ? DromeTheme.elevated2 : DromeTheme.elevated)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(
                                    preset == name ? DromeTheme.accent.opacity(0.55) : Color.white.opacity(0.05),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name) equalizer preset")
                    .accessibilityAddTraits(preset == name ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func applyBuiltInPreset(_ name: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            AudioFXPreferences.applyPreset(name)
            syncFromPreferences()
        }
    }

    private func syncFromPreferences() {
        bands = AudioFXPreferences.equalizerBands
        preset = AudioFXPreferences.equalizerPreset
        enabled = AudioFXPreferences.equalizerEnabled
        savedSlots = AudioFXPreferences.savedEqualizers
    }

    private var extras: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("ReplayGain", isOn: $replayGain)
                .tint(DromeTheme.accent)
                .onChange(of: replayGain) { _, v in AudioFXPreferences.replayGainEnabled = v }

            VStack(alignment: .leading, spacing: 8) {
                Text("Crossfade")
                    .font(.subheadline.weight(.semibold))
                Picker("Crossfade", selection: $crossfade) {
                    Text("Off").tag(0)
                    Text("3s").tag(3)
                    Text("6s").tag(6)
                    Text("9s").tag(9)
                    Text("12s").tag(12)
                }
                .pickerStyle(.segmented)
                .onChange(of: crossfade) { _, v in AudioFXPreferences.crossfadeSeconds = v }
            }

            Text("Same-album stays gapless. Crossfade soft-ramps between unrelated tracks.")
                .font(.caption2)
                .foregroundStyle(DromeTheme.muted)
        }
    }

    private func binding(for index: Int) -> Binding<Double> {
        Binding(
            get: { Double(bands[safe: index] ?? 0) },
            set: { newValue in
                guard bands.indices.contains(index) else { return }
                let clipped = Float(max(gainRange.lowerBound, min(gainRange.upperBound, newValue)))
                let stepped = (clipped * 2).rounded() / 2 // 0.5 dB steps feel snappy
                guard bands[index] != stepped else { return }
                bands[index] = stepped
                AudioFXPreferences.equalizerBands = bands
                AudioFXPreferences.equalizerPreset = "Custom"
                preset = "Custom"
                if !enabled {
                    enabled = true
                    AudioFXPreferences.equalizerEnabled = true
                }
            }
        )
    }

    private func bandLabel(_ hz: Float) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0fk", k)
                : String(format: "%.1fk", k)
        }
        return String(format: "%.0f", hz)
    }
}

// MARK: - Preset graph icon

/// Mini frequency-response sketch for a 5-band preset.
private struct EQPresetGraphIcon: View {
    let bands: [Float]
    var selected: Bool = false

    var body: some View {
        Canvas { context, size in
            let values = bands.isEmpty ? [Float](repeating: 0, count: 5) : bands
            let count = max(values.count, 1)
            let midY = size.height * 0.5
            let amp = size.height * 0.42

            // Zero line
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: midY))
            zero.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(
                zero,
                with: .color(selected ? Color.black.opacity(0.25) : Color.white.opacity(0.18)),
                lineWidth: 1
            )

            // Smooth response curve through band points
            var curve = Path()
            for (index, gain) in values.enumerated() {
                let t = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
                let x = t * size.width
                let clipped = max(-12, min(12, CGFloat(gain)))
                let y = midY - (clipped / 12) * amp
                if index == 0 {
                    curve.move(to: CGPoint(x: x, y: y))
                } else {
                    let prev = values[index - 1]
                    let prevT = CGFloat(index - 1) / CGFloat(count - 1)
                    let prevX = prevT * size.width
                    let prevY = midY - (max(-12, min(12, CGFloat(prev))) / 12) * amp
                    let c1 = CGPoint(x: (prevX + x) * 0.5, y: prevY)
                    let c2 = CGPoint(x: (prevX + x) * 0.5, y: y)
                    curve.addCurve(to: CGPoint(x: x, y: y), control1: c1, control2: c2)
                }
            }

            var fill = curve
            if let last = values.indices.last {
                let lastT = count == 1 ? 0.5 : CGFloat(last) / CGFloat(count - 1)
                fill.addLine(to: CGPoint(x: lastT * size.width, y: midY))
                fill.addLine(to: CGPoint(x: 0, y: midY))
                fill.closeSubpath()
            }
            context.fill(
                fill,
                with: .color(selected ? DromeTheme.accent.opacity(0.35) : DromeTheme.accent.opacity(0.22))
            )
            context.stroke(
                curve,
                with: .color(selected ? Color.black.opacity(0.75) : DromeTheme.accent),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            )

            // Band stems
            let barWidth = max(2, size.width / CGFloat(count * 4))
            for (index, gain) in values.enumerated() {
                let t = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
                let x = t * size.width
                let clipped = max(-12, min(12, CGFloat(gain)))
                let y = midY - (clipped / 12) * amp
                var stem = Path()
                stem.move(to: CGPoint(x: x, y: midY))
                stem.addLine(to: CGPoint(x: x, y: y))
                context.stroke(
                    stem,
                    with: .color(selected ? Color.black.opacity(0.35) : Color.white.opacity(0.28)),
                    lineWidth: barWidth
                )
                let dot = Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4))
                context.fill(
                    dot,
                    with: .color(selected ? Color.black.opacity(0.8) : Color.white.opacity(0.9))
                )
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Vertical fader

private struct EQFader: View {
    @Binding var value: Double
    let label: String
    var range: ClosedRange<Double>
    var trackHeight: CGFloat
    var gainLabelHeight: CGFloat
    var hzLabelHeight: CGFloat

    @State private var dragging = false

    var body: some View {
        VStack(spacing: 8) {
            Text(String(format: "%+.0f", value))
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(value == 0 ? DromeTheme.muted : DromeTheme.accent)
                .frame(height: gainLabelHeight)
                .opacity(dragging || value != 0 ? 1 : 0.55)
                .animation(.easeOut(duration: 0.15), value: value)

            GeometryReader { geo in
                let h = geo.size.height
                let w = geo.size.width
                let y = yPosition(in: h)

                ZStack {
                    // Tick rail
                    VStack(spacing: 0) {
                        ForEach(0..<25, id: \.self) { i in
                            Rectangle()
                                .fill(tickColor(i))
                                .frame(width: tickWidth(i), height: 1.5)
                            if i < 24 { Spacer(minLength: 0) }
                        }
                    }
                    .frame(width: 16, height: h)

                    // Center zero line
                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: min(w * 0.7, 32), height: 1)
                        .position(x: w / 2, y: h / 2)

                    // Accent fill from zero toward thumb
                    Capsule(style: .continuous)
                        .fill(DromeTheme.accent.opacity(dragging ? 0.55 : 0.35))
                        .frame(width: 3.5, height: max(abs(y - h / 2), 1))
                        .position(x: w / 2, y: (y + h / 2) / 2)

                    // Thumb
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white)
                        .overlay {
                            Capsule()
                                .fill(Color.black.opacity(0.2))
                                .frame(width: 12, height: 2)
                        }
                        .frame(width: 26, height: 16)
                        .shadow(color: DromeTheme.accent.opacity(dragging ? 0.55 : 0.18), radius: dragging ? 8 : 3)
                        .scaleEffect(dragging ? 1.1 : 1)
                        .position(x: w / 2, y: y)
                        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: dragging)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(drag(in: h))
                .onTapGesture(count: 2) {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        value = 0
                    }
                }
            }
            .frame(height: trackHeight)

            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(height: hzLabelHeight)
        }
        .accessibilityLabel("\(label) Hz")
        .accessibilityValue(String(format: "%+.0f dB", value))
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 1 : -1
            value = min(range.upperBound, max(range.lowerBound, value + step))
        }
    }

    private func drag(in height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if !dragging {
                    dragging = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
                let y = min(max(0, gesture.location.y), height)
                let next = value(fromY: y, height: height)
                if abs(next - value) >= 0.5 {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                value = next
            }
            .onEnded { _ in
                dragging = false
            }
    }

    private func yPosition(in height: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let t = (value - range.lowerBound) / span
        return height * (1 - t)
    }

    private func value(fromY y: CGFloat, height: CGFloat) -> Double {
        let t = 1 - (y / max(height, 1))
        let raw = range.lowerBound + t * (range.upperBound - range.lowerBound)
        return (raw * 2).rounded() / 2
    }

    private func tickColor(_ i: Int) -> Color {
        i == 12 ? Color.white.opacity(0.35) : Color.white.opacity(i % 4 == 0 ? 0.22 : 0.1)
    }

    private func tickWidth(_ i: Int) -> CGFloat {
        if i == 12 { return 16 }
        return i % 4 == 0 ? 12 : 7
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
