import SwiftUI
import UIKit

/// A vinyl-style rotary picker for mood vibes. Drag to spin, tap the
/// spindle to play the vibe currently under the needle.
struct VibeWheel: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var angle: Double = 0
    @State private var dragOrigin: Double?
    @State private var spinning: MoodVibe?
    @State private var error: String?
    @State private var lastSnap: Int = 0

    private let vibes = MoodVibe.allCases
    private let haptic = UIImpactFeedbackGenerator(style: .soft)

    private var step: Double { (2 * Double.pi) / Double(vibes.count) }

    private var selectedIndex: Int {
        let n = vibes.count
        var i = Int((-angle / step).rounded()) % n
        if i < 0 { i += n }
        return i
    }

    private var selected: MoodVibe { vibes[selectedIndex] }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                wheel
                    .gesture(drag)
                needle
                spindle
            }
            .frame(width: 268, height: 268)
            .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                Text(selected.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(selected.blurb)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                Text("Drag to spin · tap to play")
                    .font(.caption2)
                    .foregroundStyle(DromeTheme.muted.opacity(0.75))
                    .padding(.top, 2)
            }
            .animation(.easeInOut(duration: 0.12), value: selectedIndex)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
        }
        .onAppear { haptic.prepare() }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = angle }
                let turn = Double(value.translation.width - value.translation.height) / 72
                angle = (dragOrigin ?? 0) + turn
                let idx = selectedIndex
                if idx != lastSnap {
                    lastSnap = idx
                    haptic.impactOccurred(intensity: 0.7)
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    angle = -Double(selectedIndex) * step
                }
            }
    }

    private var needle: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(DromeTheme.accent)
                .frame(width: 3, height: 16)
            Circle()
                .fill(DromeTheme.accent)
                .frame(width: 6, height: 6)
            Spacer()
        }
        .padding(.top, 4)
        .allowsHitTesting(false)
    }

    private var spindle: some View {
        Button {
            Task { await playSelected() }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.86))
                    .frame(width: 96, height: 96)
                    .overlay {
                        Circle().stroke(
                            LinearGradient(
                                colors: selected.colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing),
                            lineWidth: 3)
                    }
                if spinning != nil {
                    ProgressView().tint(.white)
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: selected.symbol)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(spinning != nil)
        .accessibilityLabel("Play \(selected.title)")
    }

    private var wheel: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.14), Color(white: 0.05)],
                        center: .center,
                        startRadius: 40,
                        endRadius: 140)
                )
                .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
            ForEach(3..<10, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(0.045), lineWidth: 1)
                    .padding(CGFloat(12 + i * 11))
            }
            ForEach(Array(vibes.enumerated()), id: \.element.id) { index, vibe in
                VibeWedge(vibe: vibe, index: index, count: vibes.count, wheelAngle: angle)
            }
        }
        .rotationEffect(.radians(angle))
    }

    private func playSelected() async {
        error = nil
        spinning = selected
        defer { spinning = nil }
        await MoodPlayer.play(selected, session: session)
        if player.current == nil {
            error = "Couldn't find tracks for that vibe — try another, or add more music."
        }
    }
}

private struct VibeWedge: View {
    let vibe: MoodVibe
    let index: Int
    let count: Int
    let wheelAngle: Double

    var body: some View {
        let step = (2 * Double.pi) / Double(count)
        let start = step * Double(index) - Double.pi / 2 - step / 2
        ZStack {
            WedgeShape(start: start, end: start + step)
                .fill(
                    AngularGradient(
                        colors: [vibe.colors[0].opacity(0.95), vibe.colors[1].opacity(0.8)],
                        center: .center,
                        startAngle: .radians(start),
                        endAngle: .radians(start + step))
                )
                .padding(8)
            Image(systemName: vibe.symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .offset(y: -98)
                .rotationEffect(.radians(step * Double(index)))
                .rotationEffect(.radians(-wheelAngle))
        }
    }
}

private struct WedgeShape: Shape {
    var start: Double
    var end: Double
    var innerRatio: CGFloat = 0.44

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var path = Path()
        path.addArc(
            center: center, radius: outer,
            startAngle: .radians(start), endAngle: .radians(end),
            clockwise: false)
        path.addArc(
            center: center, radius: inner,
            startAngle: .radians(end), endAngle: .radians(start),
            clockwise: true)
        path.closeSubpath()
        return path
    }
}
