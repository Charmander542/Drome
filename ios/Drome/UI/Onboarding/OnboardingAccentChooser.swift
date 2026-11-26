import SwiftUI
import UIKit

/// Last-page accent playground — glowing orb that picks up the live accent.
struct OnboardingAccentMock: View {
    @ObservedObject private var store = AccentStore.shared
    var reduceMotion: Bool
    /// Compact (~200pt visual) so swatches clear the Continue bar.
    var compact: Bool = false

    @State private var pulse = false

    private var accent: Color { store.color }

    private var orbSize: CGFloat { compact ? 88 : 112 }
    private var ringBase: CGFloat { compact ? 92 : 118 }
    private var orbBlockHeight: CGFloat { compact ? 148 : 210 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: compact ? 10 : 16)

            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .stroke(
                            accent.opacity(0.28 - Double(ring) * 0.08),
                            lineWidth: 2)
                        .frame(
                            width: ringBase + CGFloat(ring) * (compact ? 28 : 38),
                            height: ringBase + CGFloat(ring) * (compact ? 28 : 38))
                        .scaleEffect(pulse && !reduceMotion ? 1.05 : 1)
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent, accent.opacity(0.55)],
                            center: .center,
                            startRadius: 8,
                            endRadius: orbSize * 0.65))
                    .frame(width: orbSize, height: orbSize)
                    .shadow(color: accent.opacity(0.55), radius: compact ? 18 : 26, y: 10)
                    .scaleEffect(pulse && !reduceMotion ? 1.04 : 1)

                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white.opacity(0.92))
                            .frame(width: compact ? 6 : 7, height: barHeight(index))
                    }
                }
            }
            .frame(height: orbBlockHeight)
            .animation(
                reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.68),
                value: store.preset)
            .animation(
                reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.68),
                value: store.customRGB)

            Text("DROME")
                .font(.system(size: compact ? 24 : 30, weight: .heavy))
                .foregroundStyle(accent)
                .padding(.top, compact ? 2 : 6)

            Text(vibeCaption)
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.top, 4)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.2),
                    value: vibeCaption)

            Spacer(minLength: compact ? 6 : 10)

            // Tiny chrome strip so the color feels “in the app.”
            HStack(spacing: 8) {
                Capsule().fill(accent).frame(width: 58, height: 9)
                Capsule().fill(Color.white.opacity(0.22)).frame(width: 42, height: 9)
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 34, height: 9)
            }
            .padding(.bottom, compact ? 14 : 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DromeTheme.background)
        .onAppear { restartPulse() }
        .onChange(of: store.preset) { _, _ in restartPulse() }
        .onChange(of: store.customRGB) { _, _ in restartPulse() }
        .onChange(of: reduceMotion) { _, _ in restartPulse() }
    }

    private var vibeCaption: String {
        switch store.preset {
        case .custom: return "Custom glow"
        case .amber: return "Amber vibes"
        case .pink: return "Pink vibes"
        case .red: return "Red vibes"
        case .orange: return "Orange vibes"
        case .yellow: return "Yellow vibes"
        case .green: return "Green vibes"
        case .teal: return "Teal vibes"
        case .blue: return "Blue vibes"
        case .indigo: return "Indigo vibes"
        case .purple: return "Purple vibes"
        }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let heights: [CGFloat] = compact
            ? [14, 26, 20, 30, 16]
            : [18, 34, 26, 40, 22]
        let base = heights[index % heights.count]
        return pulse && !reduceMotion ? base + (compact ? 4 : 6) : base
    }

    private func restartPulse() {
        pulse = false
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// Springy preset swatches + system colour picker for the tour closer.
struct OnboardingAccentChooser: View {
    @ObservedObject private var store = AccentStore.shared
    var reduceMotion: Bool

    @State private var popped: DromeAccentColor?
    @State private var revealed = false

    private let swatch: CGFloat = 40

    var body: some View {
        // Single horizontal row so swatches clear the Continue bar on SE + Pro.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(DromeAccentColor.presets.enumerated()), id: \.element.id) { index, preset in
                    Button {
                        select(preset)
                    } label: {
                        swatchLabel(
                            colour: preset.color(customRGB: store.customRGB),
                            selected: store.preset == preset,
                            popping: popped == preset)
                    }
                    .buttonStyle(.plain)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 10)
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.15)
                            : .spring(response: 0.45, dampingFraction: 0.72)
                                .delay(Double(index) * 0.03),
                        value: revealed)
                    .accessibilityLabel(preset.rawValue)
                    .accessibilityAddTraits(store.preset == preset ? .isSelected : [])
                }

                ColorPicker(selection: customBinding, supportsOpacity: false) {
                    Text("Custom colour")
                }
                .labelsHidden()
                .frame(width: swatch, height: swatch)
                .overlay {
                    if store.preset == .custom {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .allowsHitTesting(false)
                    }
                }
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 10)
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.15)
                        : .spring(response: 0.45, dampingFraction: 0.72)
                            .delay(Double(DromeAccentColor.presets.count) * 0.03),
                    value: revealed)
                .accessibilityAddTraits(store.preset == .custom ? .isSelected : [])
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drome.onboarding.accent")
        .onAppear {
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                    revealed = true
                }
            }
        }
    }

    private func swatchLabel(colour: Color, selected: Bool, popping: Bool) -> some View {
        ZStack {
            Circle()
                .fill(colour)
                .frame(width: swatch, height: swatch)
                .overlay {
                    Circle()
                        .stroke(
                            Color.white.opacity(selected ? 0.95 : 0.18),
                            lineWidth: selected ? 3 : 1)
                }
                .shadow(
                    color: selected ? colour.opacity(0.55) : .clear,
                    radius: selected ? 12 : 0,
                    y: 3)
                .scaleEffect(popping ? 1.2 : (selected ? 1.08 : 1))

            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DromeTheme.contrastingInk(on: colour))
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private func select(_ preset: DromeAccentColor) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        store.setPreset(preset)
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.42)) {
            popped = preset
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                if popped == preset { popped = nil }
            }
        }
    }

    private var customBinding: Binding<Color> {
        Binding {
            Color(
                .sRGB,
                red: store.customRGB[0],
                green: store.customRGB[1],
                blue: store.customRGB[2])
        } set: { colour in
            let resolved = colour.resolve(in: EnvironmentValues())
            store.setCustomRGB([
                Double(resolved.red),
                Double(resolved.green),
                Double(resolved.blue),
            ])
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }
}
