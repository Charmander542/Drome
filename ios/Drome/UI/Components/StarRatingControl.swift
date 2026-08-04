import SwiftUI

struct StarRatingControl: View {
    let rating: Int
    var size: CGFloat = 18
    var onRate: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    // Tap the current rating again to clear.
                    onRate?(rating == star ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(star <= rating ? Color.yellow : DromeTheme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) of 5 stars")
    }
}
