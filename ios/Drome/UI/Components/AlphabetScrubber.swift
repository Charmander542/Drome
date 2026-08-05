import SwiftUI

/// Compact right-edge A–Z scrubber (Apple Music style — tiny stacked letters).
struct AlphabetScrubber: View {
    let letters: [String]
    var onSelect: (String) -> Void

    @State private var draggingLetter: String?

    private let letterHeight: CGFloat = 11
    private let fontSize: CGFloat = 8

    var body: some View {
        let totalHeight = letterHeight * CGFloat(max(letters.count, 1))

        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(draggingLetter == letter ? DromeTheme.accent : Color.white.opacity(0.5))
                    .frame(width: 14, height: letterHeight)
            }
        }
        .frame(width: 14, height: totalHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let idx = min(max(Int(value.location.y / letterHeight), 0), letters.count - 1)
                    guard letters.indices.contains(idx) else { return }
                    let letter = letters[idx]
                    if draggingLetter != letter {
                        draggingLetter = letter
                        onSelect(letter)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
                .onEnded { _ in draggingLetter = nil }
        )
    }
}
