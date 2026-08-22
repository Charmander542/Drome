import SwiftUI

/// Radio dial for moods. Stations sit on a slow→loud spectrum; play builds
/// a queue on-device from tempo and genre (not Daily Mix collages / ratings).
struct VibeTuner: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var selected: MoodVibe = Self.vibeForHour()
    @State private var spinning: MoodVibe?
    @State private var error: String?

    private let vibes = MoodVibe.spectrum

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tuner
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(selected.wash.opacity(0.92))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(selected.ink.opacity(0.22), lineWidth: 1)
                }
        }
        .padding(.horizontal, 16)
        .hoverEffectDisabled()
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: selected)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TUNE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.6)
                    .foregroundStyle(selected.ink.opacity(0.7))
                Text(selected.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(selected.blurb)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 8) {
                VibeMeter(heights: selected.meterHeights, color: selected.ink)
                Button {
                    Task { await play(selected) }
                } label: {
                    HStack(spacing: 6) {
                        if spinning != nil {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.caption.weight(.bold))
                                .offset(x: 0.5)
                        }
                        Text(spinning == nil ? "Play" : "Tuning")
                            .font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(selected.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(spinning != nil)
                .accessibilityLabel("Play \(selected.title)")
            }
        }
    }

    private var tuner: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let n = CGFloat(vibes.count)
                let slot = geo.size.width / n
                let selectedIndex = vibes.firstIndex(of: selected) ?? 0

                ZStack(alignment: .leading) {
                    // Frequency hash marks — radio, not a mix collage.
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { i in
                                Rectangle()
                                    .fill(Color.white.opacity(i.isMultiple(of: 4) ? 0.28 : 0.1))
                                    .frame(width: 1, height: i.isMultiple(of: 4) ? 10 : 5)
                                if i < 23 { Spacer(minLength: 0) }
                            }
                        }
                        .padding(.horizontal, 4)
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                            .frame(height: 2)
                    }
                    .frame(height: 16)
                    .offset(y: -22)

                    Capsule()
                        .fill(selected.ink.opacity(0.18))
                        .frame(width: slot, height: 56)
                        .offset(x: slot * CGFloat(selectedIndex))

                    HStack(spacing: 0) {
                        ForEach(vibes) { vibe in
                            station(vibe)
                                .frame(width: slot, height: 56)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(scrub(width: geo.size.width))
                .accessibilityElement(children: .contain)
            }
            .frame(height: 56)

            HStack(spacing: 0) {
                ForEach(vibes) { vibe in
                    Text(vibe.shortLabel)
                        .font(.system(size: 9, weight: vibe == selected ? .bold : .medium))
                        .foregroundStyle(vibe == selected ? selected.ink : Color.white.opacity(0.38))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func station(_ vibe: MoodVibe) -> some View {
        let on = vibe == selected
        return ZStack {
            Circle()
                .fill(vibe.wash)
                .overlay {
                    Circle().stroke(vibe.ink.opacity(on ? 0.9 : 0.35), lineWidth: on ? 2 : 1)
                }
                .frame(width: on ? 36 : 22, height: on ? 36 : 22)
            Image(systemName: vibe.symbol)
                .font(.system(size: on ? 14 : 9, weight: .semibold))
                .foregroundStyle(vibe.ink)
            if spinning == vibe {
                ProgressView().tint(vibe.ink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .opacity(spinning != nil && spinning != vibe ? 0.45 : 1)
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
                let distance = hypot(value.translation.width, value.translation.height)
                guard distance >= 6 else { return }
                selectVibe(atX: value.location.x, width: width)
            }
            .onEnded { value in
                guard spinning == nil else { return }
                let distance = hypot(value.translation.width, value.translation.height)
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
        HStack(alignment: .bottom, spacing: 2.5) {
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
