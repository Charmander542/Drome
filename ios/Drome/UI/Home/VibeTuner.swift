import SwiftUI

/// Compact radio-tuner for mood vibes. Tap a station to select it, scrub to
/// preview along the spectrum, then hit play.
struct VibeTuner: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var selected: MoodVibe = Self.vibeForHour()
    @State private var spinning: MoodVibe?
    @State private var error: String?

    private let vibes = MoodVibe.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            tuner
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DromeTheme.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(selected.colors[0].opacity(0.16))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                }
        }
        .padding(.horizontal, 16)
        .hoverEffectDisabled()
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: selected)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await play(selected) }
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: selected.colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing)
                        )
                    if spinning != nil {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .offset(x: 1)
                    }
                }
                .frame(width: 44, height: 44)
                .shadow(color: selected.colors[0].opacity(0.45), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(spinning != nil)
            .accessibilityLabel("Play \(selected.title)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 8) {
                    Text(selected.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    VibeMeter(heights: selected.meterHeights, color: selected.colors[0])
                }
                Text(selected.blurb)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }
        }
    }

    private var tuner: some View {
        GeometryReader { geo in
            let n = CGFloat(vibes.count)
            let slot = geo.size.width / n
            let selectedIndex = vibes.firstIndex(of: selected) ?? 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: vibes.map { $0.colors[0] },
                            startPoint: .leading,
                            endPoint: .trailing)
                    )
                    .frame(height: 4)
                    .padding(.horizontal, slot / 2 - 2)
                    .opacity(0.85)

                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: slot, height: 52)
                    .offset(x: slot * CGFloat(selectedIndex))

                HStack(spacing: 0) {
                    ForEach(vibes) { vibe in
                        station(vibe)
                            .frame(width: slot, height: 52)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(scrub(width: geo.size.width))
            .accessibilityElement(children: .contain)
        }
        .frame(height: 52)
    }

    private func station(_ vibe: MoodVibe) -> some View {
        let on = vibe == selected
        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: vibe.colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                )
                .frame(width: on ? 42 : 28, height: on ? 42 : 28)
                .shadow(color: on ? vibe.colors[0].opacity(0.55) : .clear, radius: 8)
            Image(systemName: vibe.symbol)
                .font(.system(size: on ? 16 : 11, weight: .bold))
                .foregroundStyle(.white)
            if spinning == vibe {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .opacity(spinning != nil && spinning != vibe ? 0.55 : 1)
        .accessibilityLabel(vibe.title)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Selects this mood. Use Play to start the mix.")
        .accessibilityAction {
            guard spinning == nil else { return }
            selected = vibe
        }
    }

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard spinning == nil else { return }
                // Only scrub after a clear drag so a tap doesn't fight selection.
                let distance = hypot(value.translation.width, value.translation.height)
                guard distance >= 6 else { return }
                selectVibe(atX: value.location.x, width: width)
            }
            .onEnded { value in
                guard spinning == nil else { return }
                let distance = hypot(value.translation.width, value.translation.height)
                // Tap (or tiny movement): select the vibe under the finger.
                if distance < 6 {
                    selectVibe(atX: value.location.x, width: width)
                }
            }
    }

    private func selectVibe(atX x: CGFloat, width: CGFloat) {
        let n = vibes.count
        guard width > 0, n > 0 else { return }
        let idx = Int((x / width) * CGFloat(n))
        let clamped = min(max(idx, 0), n - 1)
        let vibe = vibes[clamped]
        if vibe != selected {
            selected = vibe
        }
    }

    private func play(_ vibe: MoodVibe) async {
        error = nil
        spinning = vibe
        defer { spinning = nil }
        await MoodPlayer.play(vibe, session: session)
        if player.current == nil {
            error = "Couldn't find tracks for that vibe — try another, or add more music."
        }
    }

    /// Opens on a vibe that fits the time of day.
    private static func vibeForHour() -> MoodVibe {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: return .focus
        case 11..<17: return .feelGood
        case 17..<21: return .hype
        default: return .lateNight
        }
    }
}

private struct VibeMeter: View {
    let heights: [CGFloat]
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: h)
            }
        }
        .frame(height: 18, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

private extension MoodVibe {
    /// Tiny EQ silhouette so each mood has a different "shape" in the header.
    var meterHeights: [CGFloat] {
        switch self {
        case .chill: return [7, 11, 8, 9]
        case .hype: return [16, 18, 13, 17]
        case .lateNight: return [6, 10, 14, 8]
        case .feelGood: return [12, 16, 11, 15]
        case .focus: return [10, 10, 14, 10]
        case .heartbreak: return [5, 14, 8, 6]
        case .lucky: return [17, 8, 16, 11]
        }
    }
}
