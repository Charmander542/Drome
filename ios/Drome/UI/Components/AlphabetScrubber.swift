import SwiftUI
import UIKit

/// Compact right-edge A–Z scrubber. Scales letter spacing so the full index
/// (#…Z) always fits in the available height — nothing clipped below G.
struct AlphabetScrubber: View {
    let letters: [String]
    var onSelect: (String) -> Void

    @State private var activeLetter: String?

    var body: some View {
        GeometryReader { geo in
            let count = max(letters.count, 1)
            let letterHeight = min(14, max(8, geo.size.height / CGFloat(count)))
            let fontSize = min(11, max(7, letterHeight * 0.85))

            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(activeLetter == letter
                                         ? DromeTheme.accent
                                         : Color.white.opacity(0.45))
                        .frame(width: geo.size.width, height: letterHeight)
                }
            }
            .frame(width: geo.size.width, height: letterHeight * CGFloat(count), alignment: .top)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard !letters.isEmpty else { return }
                        // Map against the centered stack.
                        let stackHeight = letterHeight * CGFloat(count)
                        let top = (geo.size.height - stackHeight) / 2
                        let y = value.location.y - top
                        let idx = min(max(Int(y / letterHeight), 0), letters.count - 1)
                        let letter = letters[idx]
                        guard activeLetter != letter else { return }
                        activeLetter = letter
                        onSelect(letter)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
            )
        }
        .frame(width: 22)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Section index")
    }
}
