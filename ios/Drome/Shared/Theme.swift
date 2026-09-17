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

/// Extra bottom safe-area padding when the mini player is visible.
/// Nested `List`/`ScrollView` inside `TabView` + `NavigationStack` often ignore
/// the outer `safeAreaInset`, so tab content opts in via this environment value.
private struct MiniPlayerClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var miniPlayerClearance: CGFloat {
        get { self[MiniPlayerClearanceKey.self] }
        set { self[MiniPlayerClearanceKey.self] = newValue }
    }
}

enum MiniPlayerMetrics {
    /// Art (48) + vertical padding (16) + gap above the tab bar (4).
    static let clearanceHeight: CGFloat = 68
}

extension View {
    func dromeScreen() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DromeTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

    /// Adds bottom safe-area padding while the mini player is showing so the
    /// last list rows can scroll clear of it. No-op when clearance is 0.
    func dromeMiniPlayerClearance(_ height: CGFloat? = nil) -> some View {
        modifier(MiniPlayerClearanceModifier(overrideHeight: height))
    }

}

private struct MiniPlayerClearanceModifier: ViewModifier {
    var overrideHeight: CGFloat?
    @Environment(\.miniPlayerClearance) private var clearance

    func body(content: Content) -> some View {
        let amount = overrideHeight ?? clearance
        content.safeAreaPadding(.bottom, amount)
    }
}

extension View {
    /// Confirms before a play action that would replace an existing user queue.
    func confirmReplaceUserQueue(
        isPresented: Binding<Bool>,
        queueCount: Int,
        onClearAndPlay: @escaping () -> Void,
        onKeepAndPlay: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) -> some View {
        confirmationDialog(
            "Replace queue?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Clear Queue & Play") { onClearAndPlay() }
            Button("Keep Queue & Play") { onKeepAndPlay() }
            Button("Cancel", role: .cancel) { onCancel?() }
        } message: {
            Text(queueCount == 1
                  ? "You have 1 song queued. Clear it, or keep it and play this song now?"
                  : "You have \(queueCount) songs queued. Clear them, or keep them and play this song now?")
        }
    }
}
