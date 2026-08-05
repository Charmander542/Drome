import SwiftUI

/// Compact filled star tinted by rating level (1★ red → 5★ yellow).
struct RatingBadge: View {
    let rating: Int
    var size: CGFloat = 11

    private var clamped: Int { min(5, max(0, rating)) }

    var body: some View {
        Group {
            if clamped > 0 {
                Image(systemName: "star.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(RatingStyle.color(for: clamped))
                    .accessibilityLabel("\(clamped) of 5 stars")
            }
        }
    }
}
