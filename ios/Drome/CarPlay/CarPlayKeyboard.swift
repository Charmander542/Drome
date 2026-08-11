import CarPlay
import UIKit

/// Full-screen QWERTY-style pad for CarPlay using `CPGridTemplate`.
///
/// Audio apps cannot use Apple Maps’ system keyboard. CarPlay only allows one
/// grid of up to 8 buttons — stacking two grids isn’t supported — so we page
/// through letter banks of 8 with a More key.
@MainActor
final class CarPlayKeyboard {
    private(set) var query: String = ""
    private weak var grid: CPGridTemplate?
    private var bankIndex = 0
    private var onSearch: ((String) -> Void)?

    /// Letter banks in QWERTY order — 7 letters + More/Back under the 8-button cap.
    private let letterBanks: [[String]] = [
        ["Q", "W", "E", "R", "T", "Y", "U", "›"],
        ["I", "O", "P", "A", "S", "D", "F", "›"],
        ["G", "H", "J", "K", "L", "Z", "X", "›"],
        ["C", "V", "B", "N", "M", "'", "-", "›"],
        ["0", "1", "2", "3", "4", "5", "6", "›"],
        ["7", "8", "9", ".", ",", "!", "?", "‹"]
    ]

    func makeTemplate(onSearch: @escaping (String) -> Void) -> CPGridTemplate {
        self.onSearch = onSearch
        query = ""
        bankIndex = 0

        let grid = CPGridTemplate(title: titleText, gridButtons: buttons(for: 0))
        grid.leadingNavigationBarButtons = [clearBarButton()]
        grid.trailingNavigationBarButtons = [
            deleteBarButton(),
            spaceBarButton(),
            searchBarButton()
        ]
        self.grid = grid
        return grid
    }

    func reset() {
        query = ""
        bankIndex = 0
        refresh()
    }

    // MARK: - Grid

    private func buttons(for bank: Int) -> [CPGridButton] {
        let keys = letterBanks[bank]
        return keys.map { key in
            let image = Self.keyImage(for: key)
            return CPGridButton(titleVariants: [Self.displayTitle(for: key)], image: image) { [weak self] _ in
                self?.handleKey(key)
            }
        }
    }

    private func handleKey(_ key: String) {
        switch key {
        case "›":
            bankIndex = min(bankIndex + 1, letterBanks.count - 1)
            refresh()
        case "‹":
            bankIndex = max(bankIndex - 1, 0)
            refresh()
        default:
            query.append(contentsOf: key.lowercased())
            refresh()
        }
    }

    private func refresh() {
        guard let grid else { return }
        grid.updateTitle(titleText)
        grid.updateGridButtons(buttons(for: bankIndex))
    }

    private var titleText: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Type a search" : trimmed
    }

    // MARK: - Bar buttons

    private func deleteBarButton() -> CPBarButton {
        if let image = UIImage(systemName: "delete.left") {
            return CPBarButton(image: image) { [weak self] _ in
                guard let self, !self.query.isEmpty else { return }
                self.query.removeLast()
                self.refresh()
            }
        }
        return CPBarButton(title: "Delete") { [weak self] _ in
            guard let self, !self.query.isEmpty else { return }
            self.query.removeLast()
            self.refresh()
        }
    }

    private func spaceBarButton() -> CPBarButton {
        CPBarButton(title: "Space") { [weak self] _ in
            self?.query.append(" ")
            self?.refresh()
        }
    }

    private func searchBarButton() -> CPBarButton {
        CPBarButton(title: "Search") { [weak self] _ in
            guard let self else { return }
            let trimmed = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.onSearch?(trimmed)
        }
    }

    private func clearBarButton() -> CPBarButton {
        CPBarButton(title: "Clear") { [weak self] _ in
            self?.query = ""
            self?.bankIndex = 0
            self?.refresh()
        }
    }

    // MARK: - Art

    private static func displayTitle(for key: String) -> String {
        switch key {
        case "›": return "More"
        case "‹": return "Back"
        default: return key
        }
    }

    private static func keyImage(for key: String) -> UIImage {
        let size = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 18)
            UIColor(white: 0.20, alpha: 1).setFill()
            path.fill()
            UIColor(white: 0.40, alpha: 1).setStroke()
            path.lineWidth = 3
            path.stroke()

            let label: String
            let fontSize: CGFloat
            switch key {
            case "›":
                label = "›"
                fontSize = 48
            case "‹":
                label = "‹"
                fontSize = 48
            default:
                label = key
                fontSize = 44
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = (label as NSString).size(withAttributes: attrs)
            let point = CGPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2 - 2)
            (label as NSString).draw(at: point, withAttributes: attrs)
        }
    }
}
