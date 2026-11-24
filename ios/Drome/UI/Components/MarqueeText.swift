import SwiftUI

/// Single-line label that scrolls horizontally when the title is wider than
/// its container (Spotify-style mini / now-playing titles).
struct MarqueeText: View {
    let text: String
    var font: Font = .subheadline.weight(.semibold)
    var color: Color = .white
    /// Gap between the looping copies.
    var spacing: CGFloat = 28
    /// Pause at the starting position before each scroll cycle.
    var startDelay: TimeInterval = 1.4
    /// Points per second while scrolling.
    var speed: CGFloat = 32

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var lineHeight: CGFloat = 0
    /// Epoch for the current text — changing text restarts the pause/scroll clock.
    @State private var clockStart = Date()

    private var needsScroll: Bool {
        textWidth > 0 && containerWidth > 0 && textWidth > containerWidth + 1
    }

    var body: some View {
        Group {
            if needsScroll && !reduceMotion {
                scrollingBody
            } else {
                staticBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: lineHeight > 0 ? lineHeight : nil, alignment: .center)
        .background(heightProbe)
        .accessibilityLabel(text)
        .onChange(of: text) { _, _ in
            clockStart = Date()
            textWidth = 0
        }
        .onChange(of: textWidth) { old, new in
            // First real measure — start the pause clock from here, not view appear.
            if old < 1, new > 1 { clockStart = Date() }
        }
        .onChange(of: reduceMotion) { _, _ in
            clockStart = Date()
        }
    }

    private var staticBody: some View {
        GeometryReader { geo in
            label
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in containerWidth = w }
        }
        .clipped()
    }

    /// Frame-driven offset — avoids `withAnimation` + `Task.sleep` desync jank.
    private var scrollingBody: some View {
        let cycle = textWidth + spacing
        let scrollDuration = Double(cycle / max(speed, 1))
        let period = max(startDelay, 0) + max(scrollDuration, 0.05)

        return TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let offset = Self.offset(
                at: context.date,
                since: clockStart,
                cycle: cycle,
                startDelay: startDelay,
                scrollDuration: scrollDuration,
                period: period)

            GeometryReader { geo in
                HStack(spacing: spacing) {
                    label
                    label
                }
                .offset(x: offset)
                .frame(width: cycle * 2 - spacing, alignment: .leading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in containerWidth = w }
            }
        }
    }

    /// Hold at 0, ease linearly across one copy, then loop (dual labels make the wrap seamless).
    private static func offset(
        at date: Date,
        since start: Date,
        cycle: CGFloat,
        startDelay: TimeInterval,
        scrollDuration: TimeInterval,
        period: TimeInterval
    ) -> CGFloat {
        guard cycle > 0, period > 0 else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(start))
        let t = elapsed.truncatingRemainder(dividingBy: period)
        if t < startDelay { return 0 }
        let progress = min(max((t - startDelay) / scrollDuration, 0), 1)
        return -cycle * progress
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(widthProbe)
    }

    /// Measures the rendered text width without affecting layout.
    private var widthProbe: some View {
        GeometryReader { geo in
            Color.clear
                .preference(key: MarqueeTextWidthKey.self, value: geo.size.width)
        }
        .onPreferenceChange(MarqueeTextWidthKey.self) { textWidth = $0 }
    }

    private var heightProbe: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .accessibilityHidden(true)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: MarqueeTextHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(MarqueeTextHeightKey.self) { lineHeight = $0 }
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MarqueeTextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
