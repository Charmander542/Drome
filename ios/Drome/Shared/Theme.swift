import SwiftUI

enum DromeTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let elevated = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let elevated2 = Color(red: 0.16, green: 0.16, blue: 0.17)
    /// Soft system blue — used for accents across the app.
    static let accent = Color(red: 0.25, green: 0.55, blue: 0.98)
    static let muted = Color(white: 0.62)
    static let divider = Color(white: 0.22)

    static let titleFont = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let headlineFont = Font.system(.title2, design: .rounded).weight(.bold)
    static let rowTitle = Font.system(.body, design: .default).weight(.semibold)
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        switch cleaned.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        default:
            r = 0.2; g = 0.2; b = 0.22
        }
        self.init(red: r, green: g, blue: b)
    }
}

extension View {
    func dromeScreen() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DromeTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

    /// Clears space above the floating mini player + tab bar.
    func dromeMiniPlayerClearance(_ height: CGFloat = 84) -> some View {
        safeAreaInset(edge: .bottom) { Color.clear.frame(height: height) }
    }
}
