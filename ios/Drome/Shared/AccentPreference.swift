import SwiftUI
import Combine

/// Ready-made accents plus a system colour picker (Aura-style).
enum DromeAccentColor: String, CaseIterable, Identifiable {
    case amber = "Amber"
    case pink = "Pink"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case teal = "Teal"
    case blue = "Blue"
    case indigo = "Indigo"
    case purple = "Purple"
    case custom = "Custom"

    var id: String { rawValue }

    /// Presets shown as swatches (excludes custom).
    static var presets: [DromeAccentColor] { allCases.filter { $0 != .custom } }

    static let `default`: DromeAccentColor = .amber

    /// First-open custom picker colour — warm amber, matching Drome’s default.
    static let defaultCustomRGB: [Double] = [0.95, 0.65, 0.22]

    func color(customRGB: [Double]) -> Color {
        switch self {
        case .custom:
            let rgb = customRGB.count == 3 ? customRGB : Self.defaultCustomRGB
            return Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2])
        case .amber: return Color(red: 0.95, green: 0.65, blue: 0.22)
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        }
    }
}

/// Persisted accent selection. Views that need live updates observe this store
/// (or remount via `revision`); `DromeTheme.accent` reads `cachedColor`.
final class AccentStore: ObservableObject {
    static let shared = AccentStore()

    private static let presetKey = "drome.accent.preset"
    private static let rgbKey = "drome.accent.customRGB"

    /// Snapshot for `DromeTheme.accent` from any isolation domain.
    nonisolated(unsafe) private(set) static var cachedColor: Color =
        DromeAccentColor.default.color(customRGB: DromeAccentColor.defaultCustomRGB)

    @Published private(set) var preset: DromeAccentColor
    @Published private(set) var customRGB: [Double]
    /// Bumped when the whole UI should rebuild after an accent change.
    @Published private(set) var revision: UInt64 = 0
    /// True when preset/RGB changed since the last remount (Settings defers remount).
    private var needsRemount = false

    var color: Color { preset.color(customRGB: customRGB) }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.presetKey) ?? DromeAccentColor.default.rawValue
        preset = DromeAccentColor(rawValue: raw) ?? .default
        if let stored = UserDefaults.standard.array(forKey: Self.rgbKey) as? [Double], stored.count == 3 {
            customRGB = stored.map { min(max($0, 0), 1) }
        } else {
            customRGB = DromeAccentColor.defaultCustomRGB
        }
        Self.cachedColor = color
    }

    func setPreset(_ value: DromeAccentColor) {
        guard value != .custom else {
            if preset != .custom {
                preset = .custom
                needsRemount = true
                persist()
            }
            return
        }
        guard value != preset else { return }
        preset = value
        needsRemount = true
        persist()
        // Remount is deferred to Settings.onDisappear so the sheet stays up.
    }

    func setCustomRGB(_ rgb: [Double]) {
        guard rgb.count == 3 else { return }
        let next = rgb.map { min(max($0, 0), 1) }
        guard next != customRGB || preset != .custom else { return }
        customRGB = next
        if preset != .custom { preset = .custom }
        needsRemount = true
        persist()
        // Don’t remount while the system colour picker is open — tint updates live.
        objectWillChange.send()
    }

    /// Remount the root tree so `DromeTheme.accent` call sites pick up a new colour.
    func bumpRevision() {
        needsRemount = false
        revision &+= 1
    }

    /// Remount only if Appearance changed — avoids wiping Home/tabs on every Settings dismiss.
    func bumpRevisionIfNeeded() {
        guard needsRemount else { return }
        bumpRevision()
    }

    private func persist() {
        UserDefaults.standard.set(preset.rawValue, forKey: Self.presetKey)
        UserDefaults.standard.set(customRGB, forKey: Self.rgbKey)
        Self.cachedColor = color
    }
}

private struct DromeAccentKey: EnvironmentKey {
    static let defaultValue: Color = DromeAccentColor.default.color(
        customRGB: DromeAccentColor.defaultCustomRGB)
}

extension EnvironmentValues {
    var dromeAccent: Color {
        get { self[DromeAccentKey.self] }
        set { self[DromeAccentKey.self] = newValue }
    }
}
