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
    /// AX horizontal pan offset (custom scroller — nested ScrollView ate taps / slow drags).
    @State private var axScrollOffset: CGFloat = 0
    /// Non-nil while an AX pan is in progress; holds offset at touch-down.
    @State private var axDragStartOffset: CGFloat?

    /// Accessibility-only scaling. Default/XXXL keep the fixed 9pt captions.
    @ScaledMetric(relativeTo: .caption2) private var chipCaptionSizeScaled: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var stationIconSizeScaled: CGFloat = 9
    @ScaledMetric(relativeTo: .body) private var stationIconSelectedSizeScaled: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var stationDotSizeScaled: CGFloat = 22
    @ScaledMetric(relativeTo: .title3) private var stationDotSelectedSizeScaled: CGFloat = 36

    private let vibes = MoodVibe.spectrum
    private var ax: Bool { dynamicTypeSize.isAccessibilitySize }

    private var chipCaptionSize: CGFloat {
        // Cap ~20; AX row scrolls horizontally so labels need not squeeze into 1/7 width.
        ax ? min(chipCaptionSizeScaled, 20) : 9
    }

    /// Minimum AX column width so shortLabels ("Happy", "Night", …) fit without ellipsis.
    private var axMinSlotWidth: CGFloat {
        max(70, chipCaptionSize * 4.0 + 12)
    }

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
        .overlay {
            if spinning != nil {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .overlay {
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Building your mix…")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            if player.current != nil {
                                Text("Current song keeps playing")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.white.opacity(0.72))
                            }
                        }
                        .padding(.horizontal, 20)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            player.current != nil
                                ? "Building your mix. Current song keeps playing."
                                : "Building your mix.")
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: spinning != nil)
        .padding(.horizontal, ax ? 0 : 16)
        // AX: asymmetric outer inset — clear the Home account button on the trailing edge.
        .padding(.leading, ax ? 16 : 0)
        .padding(.trailing, ax ? 52 : 0)
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
                    .lineLimit(ax ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 8) {
                if !ax {
                    VibeMeter(heights: selected.meterHeights, color: selected.ink)
                }
                Button {
                    guard spinning == nil else { return }
                    Task { await play(selected) }
                } label: {
                    playButtonLabel
                        .foregroundStyle(.black)
                        .padding(.horizontal, ax ? 14 : 16)
                        .padding(.vertical, ax ? 10 : 9)
                        .frame(minWidth: ax ? 72 : 108)
                        .background(selected.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(spinning == nil)
                .animation(nil, value: spinning)
                .accessibilityLabel(
                    spinning == nil ? "Play \(selected.title) mix" : "Building \(selected.title) mix")
                .accessibilityAddTraits(spinning == nil ? [] : .updatesFrequently)
            }
        }
    }

    @ViewBuilder
    private var playButtonLabel: some View {
        let busy = spinning != nil
        // Fixed min width so Play ↔ Mixing… doesn't jump the capsule.
        let icon = ZStack {
            Image(systemName: "play.fill")
                .font(.caption.weight(.bold))
                .offset(x: 0.5)
                .opacity(busy ? 0 : 1)
            ProgressView()
                .controlSize(.regular)
                .tint(.black)
                .opacity(busy ? 1 : 0)
                .scaleEffect(0.85)
        }
        .frame(width: 14, height: 14)

        let title = Text(busy ? "Mixing…" : "Play")
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.opacity)

        if ax {
            VStack(spacing: 4) {
                icon
                title
            }
        } else {
            HStack(spacing: 7) {
                icon
                title
            }
        }
    }

    @ViewBuilder
    private var tuner: some View {
        if ax {
            axScrollableTuner
        } else {
            // Exact pre-AX layout (keeps Home error block position identical to main).
            standardTuner
        }
    }

    /// Default / XXXL: equal-width dial + captions, scrub gesture. Unchanged vs main.
    private var standardTuner: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let n = CGFloat(max(vibes.count, 1))
                let width = geo.size.width.isFinite ? max(0, geo.size.width) : 0
                let slot = width > 0 ? width / n : 0
                let selectedIndex = vibes.firstIndex(of: selected) ?? 0

                ZStack(alignment: .leading) {
                    frequencyMarks
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

    /// AX: wide columns + one high-priority drag that both selects (tap) and pans
    /// (slow drag). Nested ScrollView ate taps; Button+pan fought over the same hits.
    private var axScrollableTuner: some View {
        let dialHeight = max(56, min(stationDotSelectedSizeScaled, 48) + 16)
        let slot = axMinSlotWidth
        let contentWidth = slot * CGFloat(vibes.count)
        let selectedIndex = vibes.firstIndex(of: selected) ?? 0
        let rowHeight = dialHeight + 8 + chipCaptionSize

        return GeometryReader { geo in
            let visible = geo.size.width.isFinite ? max(0, geo.size.width) : 0
            let maxOffset = max(0, contentWidth - visible)
            let shownOffset = min(max(axScrollOffset, 0), maxOffset)

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .leading) {
                    frequencyMarks
                        .frame(width: contentWidth, height: 16)
                        .offset(y: -22)
                    Capsule()
                        .fill(selected.ink.opacity(0.18))
                        .frame(width: slot, height: dialHeight)
                        .offset(x: slot * CGFloat(selectedIndex))
                }
                .frame(width: contentWidth, height: dialHeight, alignment: .leading)
                .allowsHitTesting(false)

                HStack(spacing: 0) {
                    ForEach(vibes) { vibe in
                        axChipColumn(vibe, slot: slot, dialHeight: dialHeight)
                    }
                }
            }
            .offset(x: -shownOffset)
            .frame(width: visible, height: rowHeight, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .highPriorityGesture(axTapOrPanGesture(slot: slot, maxOffset: maxOffset))
            .onChange(of: maxOffset) { _, newMax in
                axScrollOffset = min(axScrollOffset, newMax)
            }
            .accessibilityElement(children: .contain)
        }
        .frame(height: rowHeight)
    }

    private func axChipColumn(_ vibe: MoodVibe, slot: CGFloat, dialHeight: CGFloat) -> some View {
        VStack(spacing: 8) {
            station(vibe)
                .frame(width: slot, height: dialHeight)
            Text(vibe.shortLabel)
                .font(.system(size: chipCaptionSize,
                              weight: vibe == selected ? .bold : .medium))
                .foregroundStyle(vibe == selected ? selected.ink : Color.white.opacity(0.38))
                .lineLimit(1)
                .minimumScaleFactor(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)
        }
        .frame(width: slot)
        .contentShape(Rectangle())
        .allowsHitTesting(false) // selection comes from axTapOrPanGesture
    }

    /// Tap → select chip under finger; horizontal pan → scroll (including slow drags).
    private func axTapOrPanGesture(slot: CGFloat, maxOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // Ignore until clearly horizontal so tiny jitter doesn’t nudge the row.
                guard abs(dx) >= 6, abs(dx) >= abs(dy) else { return }
                let start = axDragStartOffset ?? axScrollOffset
                if axDragStartOffset == nil { axDragStartOffset = start }
                axScrollOffset = min(max(start - dx, 0), maxOffset)
            }
            .onEnded { value in
                let start = axDragStartOffset ?? axScrollOffset
                axDragStartOffset = nil

                let dx = value.translation.width
                let dy = value.translation.height
                let distance = hypot(dx, dy)

                if distance < 8 {
                    // Tap: restore any dead-zone nudge, then select chip under finger.
                    axScrollOffset = min(max(start, 0), maxOffset)
                    let xInContent = value.startLocation.x + start
                    selectAxVibe(atContentX: xInContent, slot: slot)
                    return
                }

                guard abs(dx) >= abs(dy) else {
                    // Vertical-ish drag: snap back to touch-down offset.
                    axScrollOffset = min(max(start, 0), maxOffset)
                    return
                }
                axScrollOffset = min(max(start - dx, 0), maxOffset)
            }
    }

    private func selectAxVibe(atContentX x: CGFloat, slot: CGFloat) {
        guard spinning == nil, slot > 0, !vibes.isEmpty else { return }
        let idx = Int((x / slot).rounded(.down))
        let clamped = min(max(idx, 0), vibes.count - 1)
        let vibe = vibes[clamped]
        if vibe != selected {
            selected = vibe
            WidgetVibeStore.selectedVibe = vibe
        }
    }

    private var frequencyMarks: some View {
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
    }

    private func station(_ vibe: MoodVibe) -> some View {
        let on = vibe == selected
        let dot: CGFloat
        let icon: CGFloat
        if ax {
            dot = on ? min(stationDotSelectedSizeScaled, 48) : min(stationDotSizeScaled, 32)
            icon = on ? min(stationIconSelectedSizeScaled, 20) : min(stationIconSizeScaled, 14)
        } else {
            dot = on ? 36 : 22
            icon = on ? 14 : 9
        }
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
        let ok = await MoodPlayer.play(vibe, session: session)
        if !ok {
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
