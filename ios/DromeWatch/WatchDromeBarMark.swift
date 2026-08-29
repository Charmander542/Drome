import SwiftUI

/// Six-bar Drome mark (same silhouette as LaunchLogo / widget).
struct WatchDromeBarMark: View {
    var size: CGFloat = 18
    var color: Color = .white

    private static let glyphs: [(kind: Int, height: CGFloat)] = [
        (0, 10), (1, 4.5), (0, 16.5), (0, 20), (0, 10), (1, 3.8),
    ]

    var body: some View {
        let barW = size * 0.16
        let spacing = size * 0.08
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<Self.glyphs.count, id: \.self) { i in
                let g = Self.glyphs[i]
                if g.kind == 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: barW, height: size * (g.height / 22))
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: size * (g.height / 22), height: size * (g.height / 22))
                }
            }
        }
        .frame(width: size * 1.35, height: size)
        .accessibilityLabel("Drome")
    }
}
