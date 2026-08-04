import SwiftUI

/// Compact star whose fill fraction mirrors a 1…5 rating (e.g. 3★ → 60% filled).
struct RatingBadge: View {
    let rating: Int
    var size: CGFloat = 11

    private var clamped: Int { min(5, max(0, rating)) }
    private var fill: CGFloat { CGFloat(clamped) / 5 }

    var body: some View {
        Group {
            if clamped > 0 {
                ZStack(alignment: .leading) {
                    Image(systemName: "star")
                        .foregroundStyle(DromeTheme.muted)
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color.yellow)
                        .mask(alignment: .leading) {
                            GeometryReader { geo in
                                Rectangle()
                                    .frame(width: geo.size.width * fill)
                            }
                        }
                }
                .font(.system(size: size, weight: .semibold))
                .accessibilityLabel("\(clamped) of 5 stars")
            }
        }
    }
}
