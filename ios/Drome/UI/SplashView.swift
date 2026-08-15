import SwiftUI

/// System splash shows the brand `LaunchLogo`. This overlay starts on that
/// still at the same size, then dissolves into the bar animation + chime,
/// and finally fades out over the home UI.
struct SplashScreenView: View {
    var onFinished: () -> Void = {}

    @State private var startDate = Date()
    @State private var showStill = true
    @State private var overlayOpacity: Double = 1

    /// Brand mark size — 10% larger than the original 200pt splash.
    private static let logoSize: CGFloat = 220

    /// Animated bars stay at their own mark size (unrelated to the logo).
    private static let markSize: CGFloat = 200

    private let bars: [LogoBar] = [
        .capsule(60),
        .circle(27),
        .capsule(100),
        .capsule(120),
        .capsule(60),
        .circle(23),
    ]
    private let barWidth: CGFloat = 17
    private let barSpacing: CGFloat = 7

    private let angularSpeed: Double = 2.4
    private let phaseStep: Double = 1.6
    private let minScale: CGFloat = 0.35
    private let totalDuration: Double = 2.05
    private let stillHold: Double = 0.04
    private let stillFade: Double = 0.22
    private let exitFade: Double = 0.55
    /// Shared so the brand still and live bars stay locked together.
    private let markOffsetY: CGFloat = -20

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZStack {
                TimelineView(.animation) { timeline in
                    let t = max(0, timeline.date.timeIntervalSince(startDate))
                    let ramp = smoothstep(
                        from: stillHold,
                        to: stillHold + stillFade + 0.12,
                        t: t)

                    HStack(spacing: barSpacing) {
                        ForEach(bars.indices, id: \.self) { i in
                            let phase = Double(i) * phaseStep
                            let wave = 0.55 + 0.45 * sin(t * angularSpeed - phase)
                            let live = max(minScale, wave)
                            let scale = 1 + (live - 1) * ramp
                            bars[i].shape(width: barWidth, scale: scale)
                        }
                    }
                    .frame(width: Self.markSize, height: Self.markSize)
                    .offset(y: markOffsetY)
                }

                Image("LaunchLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: Self.logoSize, height: Self.logoSize)
                    .offset(y: markOffsetY)
                    .opacity(showStill ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .opacity(overlayOpacity)
        .allowsHitTesting(overlayOpacity > 0.05)
        .task {
            startDate = Date()
            try? await Task.sleep(nanoseconds: UInt64(stillHold * 1_000_000_000))
            BootChime.shared.play()
            withAnimation(.easeOut(duration: stillFade)) {
                showStill = false
            }
            let remaining = max(0, totalDuration - stillHold)
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            withAnimation(.easeInOut(duration: exitFade)) {
                overlayOpacity = 0
            }
            try? await Task.sleep(nanoseconds: UInt64(exitFade * 1_000_000_000))
            onFinished()
        }
    }

    private func smoothstep(from: Double, to: Double, t: Double) -> CGFloat {
        guard to > from else { return t >= to ? 1 : 0 }
        let x = min(1, max(0, (t - from) / (to - from)))
        return CGFloat(x * x * (3 - 2 * x))
    }
}

private enum LogoBar {
    case capsule(CGFloat)
    case circle(CGFloat)

    @ViewBuilder
    func shape(width: CGFloat, scale: CGFloat) -> some View {
        switch self {
        case .capsule(let height):
            Capsule()
                .fill(Color.white)
                .frame(width: width, height: height * scale)
        case .circle(let diameter):
            Circle()
                .fill(Color.white)
                .frame(width: diameter * scale, height: diameter * scale)
        }
    }
}

#Preview {
    SplashScreenView()
}
