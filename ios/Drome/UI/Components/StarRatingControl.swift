import SwiftUI
import UIKit

/// Interactive 1…5 star control. Filled stars use the color for the current
/// rating level (red at 1 → yellow at 5). Tap the active star again to clear.
struct StarRatingControl: View {
    let rating: Int
    var size: CGFloat = 18
    var onRate: ((Int) -> Void)?

    private var clamped: Int { min(5, max(0, rating)) }
    private var tint: Color { RatingStyle.color(for: max(clamped, 1)) }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    let next = clamped == star ? 0 : star
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onRate?(next)
                } label: {
                    Image(systemName: star <= clamped ? "star.fill" : "star")
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(star <= clamped ? tint : DromeTheme.muted)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: size + 10, height: size + 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy(duration: 0.18), value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(clamped == 0 ? "Unrated" : "\(clamped) of 5 stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onRate?(min(5, clamped + 1))
            case .decrement:
                onRate?(max(0, clamped - 1))
            @unknown default:
                break
            }
        }
    }
}
