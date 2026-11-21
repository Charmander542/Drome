import SwiftUI
import UIKit

/// Compact right-edge A–Z scrubber. Live drags only report the letter —
/// the list should `scrollTo` without extra `@State` work so it stays in
/// lockstep with the finger.
struct AlphabetScrubber: View {
    let letters: [String]
    var onSelect: (String) -> Void
    var onEnded: ((String) -> Void)? = nil

    @State private var activeLetter: String?
    @State private var haptic = UISelectionFeedbackGenerator()

    /// Gap between glyphs so A–Z/# don’t crowd each other.
    private let letterSpacing: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let count = max(letters.count, 1)
            let available = max(0, geo.size.height - letterSpacing * CGFloat(count - 1))
            // Prefer readable spacing; allow a taller stack when there’s room.
            let letterHeight = min(16, max(10, available / CGFloat(count)))
            let fontSize = min(11, max(8, letterHeight * 0.78))
            let stackHeight = letterHeight * CGFloat(count) + letterSpacing * CGFloat(count - 1)

            VStack(spacing: letterSpacing) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(activeLetter == letter
                                         ? DromeTheme.accent
                                         : Color.white.opacity(0.45))
                        .frame(width: geo.size.width, height: letterHeight)
                }
            }
            .frame(width: geo.size.width, height: stackHeight, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard !letters.isEmpty else { return }
                        let top = (geo.size.height - stackHeight) / 2
                        let y = value.location.y - top
                        let stride = letterHeight + letterSpacing
                        let idx = min(max(Int(y / stride), 0), letters.count - 1)
                        let letter = letters[idx]
                        guard activeLetter != letter else { return }
                        activeLetter = letter
                        haptic.selectionChanged()
                        haptic.prepare()
                        onSelect(letter)
                    }
                    .onEnded { _ in
                        if let activeLetter {
                            onEnded?(activeLetter)
                        }
                    }
            )
            .onAppear { haptic.prepare() }
        }
        .frame(width: 26)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Section index")
        .accessibilityAdjustableAction { direction in
            guard !letters.isEmpty else { return }
            let current = activeLetter.flatMap { letters.firstIndex(of: $0) } ?? 0
            let next: Int
            switch direction {
            case .increment: next = min(current + 1, letters.count - 1)
            case .decrement: next = max(current - 1, 0)
            @unknown default: return
            }
            let letter = letters[next]
            activeLetter = letter
            onSelect(letter)
            onEnded?(letter)
        }
    }
}
