import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Listening Club design tokens. Existing `background` / `elevated` / `accent`
/// aliases stay so call sites keep compiling while components migrate.
enum DromeTheme {
    // MARK: - Surfaces

    static let background = Color(red: 0.05, green: 0.05, blue: 0.055)
    static let elevated = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let elevated2 = Color(red: 0.16, green: 0.16, blue: 0.17)
    static var surface: Color { elevated }
    static var surfaceRaised: Color { elevated2 }

    /// App accent — defaults to warm amber; user can change it in Settings.
    static var accent: Color { AccentStore.cachedColor }
    static var accentWash: Color { AccentStore.cachedColor.opacity(0.18) }
    static let ink = Color.white
    static let muted = Color(white: 0.62)
    static let divider = Color(white: 0.22)

    // MARK: - Type

    /// Display — slightly condensed geometric feel without a custom font file.
    static let titleFont = Font.system(.largeTitle, design: .default).weight(.bold)
    static let brandFont = Font.system(size: 28, weight: .heavy, design: .default)
    static let headlineFont = Font.system(.title2, design: .default).weight(.bold)
    static let sectionFont = Font.system(.title3, design: .default).weight(.semibold)
    static let rowTitle = Font.system(.body, design: .default).weight(.semibold)
    static let captionFont = Font.system(.caption, design: .default).weight(.medium)
    static let overlineFont = Font.system(.caption2, design: .default).weight(.bold)

    // MARK: - Space / radius

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let xl: CGFloat = 22
        static let pill: CGFloat = 999
    }

    // MARK: - Motion

    enum Motion {
        static let vibeBreathe = Animation.easeInOut(duration: 2.4).repeatForever(autoreverses: true)
        static let colorCrossfade = Animation.easeInOut(duration: 0.45)
        static let expand = Animation.spring(response: 0.38, dampingFraction: 0.84)
    }

    /// Contrast-safe text/icon color on a wash derived from artwork.
    static func contrastingInk(on wash: Color) -> Color {
        #if os(iOS)
        let ui = UIColor(wash)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.55 ? Color.black.opacity(0.88) : Color.white
        #else
        return .white
        #endif
    }
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

/// Kept for call sites / future overlays. Bottom chrome is laid out as a sibling
/// of tab content in `MainTabView`, so Lists cannot paint under the mini player.
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
    static let clearanceHeight: CGFloat = 76
}

extension View {
    func dromeScreen() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DromeTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

    func dromeMiniPlayerClearance(_ height: CGFloat? = nil) -> some View {
        self
    }
}

extension View {
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
