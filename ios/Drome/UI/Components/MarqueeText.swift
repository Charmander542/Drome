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
    @State private var offset: CGFloat = 0
    /// Bumped to cancel an in-flight loop when text / size / motion changes.
    @State private var loopGeneration = 0
    /// Cycle length the active loop was started with — avoids preference-key thrash restarts.
    @State private var activeCycle: CGFloat = 0

    private var needsScroll: Bool {
        textWidth > 0 && containerWidth > 0 && textWidth > containerWidth + 1
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                if needsScroll && !reduceMotion {
                    HStack(spacing: spacing) {
                        label
                        label
                    }
                    .offset(x: offset)
                    .frame(width: textWidth * 2 + spacing, alignment: .leading)
                } else {
                    label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Keep glyphs vertically centered inside the measured line box.
            .frame(width: width, height: geo.size.height, alignment: .leading)
            .clipped()
            .onAppear { containerWidth = width }
            .onChange(of: width) { _, newValue in
                containerWidth = newValue
                restartIfNeeded()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: lineHeight > 0 ? lineHeight : nil, alignment: .center)
        .background(heightProbe)
        .accessibilityLabel(text)
        .onChange(of: text) { _, _ in
            stopLoop(resetOffset: true)
            restartIfNeeded()
        }
        .onChange(of: textWidth) { _, _ in restartIfNeeded() }
        .onChange(of: containerWidth) { _, _ in restartIfNeeded() }
        .onChange(of: reduceMotion) { _, _ in
            stopLoop(resetOffset: true)
            restartIfNeeded()
        }
        .onDisappear {
            stopLoop(resetOffset: false)
        }
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

    private func stopLoop(resetOffset: Bool) {
        loopGeneration += 1
        activeCycle = 0
        if resetOffset {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) { offset = 0 }
        }
    }

    private func restartIfNeeded() {
        guard needsScroll, !reduceMotion else {
            stopLoop(resetOffset: true)
            return
        }

        let cycle = textWidth + spacing
        // Already looping this width — don’t restart on preference-key chatter.
        if activeCycle > 0, abs(activeCycle - cycle) < 0.5 {
            return
        }

        loopGeneration += 1
        let generation = loopGeneration
        activeCycle = cycle

        let duration = Double(cycle / max(speed, 1))
        let pauseNanos = UInt64(max(startDelay, 0) * 1_000_000_000)
        let scrollNanos = UInt64(max(duration, 0.05) * 1_000_000_000)

        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) { offset = 0 }

        Task { @MainActor in
            // Pause at start → scroll one cycle → snap to start → pause → …
            while generation == loopGeneration {
                try? await Task.sleep(nanoseconds: pauseNanos)
                guard generation == loopGeneration else { return }

                withAnimation(.linear(duration: duration)) {
                    offset = -cycle
                }
                try? await Task.sleep(nanoseconds: scrollNanos)
                guard generation == loopGeneration else { return }

                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { offset = 0 }
            }
        }
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
