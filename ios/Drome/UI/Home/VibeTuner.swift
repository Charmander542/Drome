import SwiftUI
import WidgetKit

/// Radio dial for moods. Stations sit on a slow→loud spectrum; play builds
/// a queue on-device from tempo and genre (not Daily Mix collages / ratings).
struct VibeTuner: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selected: MoodVibe = WidgetVibeStore.selectedVibe
    @State private var spinning: MoodVibe?
    @State private var error: String?

    /// Chip captions stay 9pt at default; scale with caption2, capped for AX.
    @ScaledMetric(relativeTo: .caption2) private var chipCaptionSize: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var stationIconSize: CGFloat = 9
    @ScaledMetric(relativeTo: .body) private var stationIconSelectedSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var stationDotSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title3) private var stationDotSelectedSize: CGFloat = 36

    private let vibes = MoodVibe.spectrum
    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

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
        .onChange(of: selected) { _, vibe in
            WidgetVibeStore.selectedVibe = vibe
            WidgetCenter.shared.reloadTimelines(ofKind: "VibeTunerWidget")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("VIBE TUNER")
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
                    .lineLimit(accessibilityLayout ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 8) {
                if !accessibilityLayout {
                    VibeMeter(heights: selected.meterHeights, color: selected.ink)
                }
                Button {
                    guard spinning == nil else { return }
                    Task { await play(selected) }
                } label: {
                    playButtonLabel
                        .foregroundStyle(.black)
                        .padding(.horizontal, accessibilityLayout ? 12 : 14)
                        .padding(.vertical, accessibilityLayout ? 10 : 9)
                        .background(selected.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(spinning == nil)
                .animation(nil, value: spinning)
                .accessibilityLabel("Play \(selected.title)")
            }
        }
    }

    @ViewBuilder
    private var playButtonLabel: some View {
        // Fixed slot so ProgressView ↔ play doesn't resize the capsule.
        let icon = ZStack {
            Image(systemName: "play.fill")
                .font(.caption.weight(.bold))
                .offset(x: 0.5)
                .opacity(spinning == nil ? 1 : 0)
            ProgressView()
                .controlSize(.small)
                .tint(.black)
                .opacity(spinning == nil ? 0 : 1)
        }
        .frame(width: 12, height: 12)

        let title = Text("Play")
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)

        if accessibilityLayout {
            VStack(spacing: 4) {
                icon
                title
            }
        } else {
            HStack(spacing: 6) {
                icon
                title
            }
        }
    }

    private var tuner: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let n = CGFloat(max(vibes.count, 1))
                let width = geo.size.width.isFinite ? max(0, geo.size.width) : 0
                let slot = width > 0 ? width / n : 0
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

                    if slot > 0 {
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
                }
                .contentShape(Rectangle())
                .gesture(scrub(width: width))
                .accessibilityElement(children: .contain)
            }
            .frame(height: accessibilityLayout ? max(56, stationDotSelectedSize + 16) : 56)

            HStack(spacing: 0) {
                ForEach(vibes) { vibe in
                    Text(vibe.shortLabel)
                        .font(.system(size: min(chipCaptionSize, 13),
                                      weight: vibe == selected ? .bold : .medium))
                        .foregroundStyle(vibe == selected ? selected.ink : Color.white.opacity(0.38))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func station(_ vibe: MoodVibe) -> some View {
        let on = vibe == selected
        let dot = on ? min(stationDotSelectedSize, 44) : min(stationDotSize, 30)
        let icon = on ? min(stationIconSelectedSize, 18) : min(stationIconSize, 12)
        return ZStack {
            Circle()
                .fill(vibe.wash)
                .overlay {
                    Circle().stroke(vibe.ink.opacity(on ? 0.9 : 0.35), lineWidth: on ? 2 : 1)
                }
                .frame(width: dot, height: dot)
            Image(systemName: vibe.symbol)
                .font(.system(size: icon, weight: .semibold))
                .foregroundStyle(vibe.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
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
            WidgetVibeStore.selectedVibe = vibe
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
