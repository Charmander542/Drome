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

extension View {
    func dromeScreen() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DromeTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }
}
