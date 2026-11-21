import SwiftUI

/// Accent row for Settings — ready-made swatches plus the system colour picker
/// (Aura’s AccentColourPicker pattern, adapted for Drome).
struct AccentColourPicker: View {
    @ObservedObject private var store = AccentStore.shared

    private static let swatch: CGFloat = 26
    /// Below this relative luminance an accent all but vanishes on near-black.
    private static let darkest = 0.06
    /// Above it, white labels on accent buttons stop reading.
    private static let lightest = 0.75

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accent colour")
            HStack(spacing: 0) {
                ForEach(DromeAccentColor.presets) { preset in
                    Button {
                        store.setPreset(preset)
                    } label: {
                        swatchView(
                            preset.color(customRGB: store.customRGB),
                            selected: store.preset == preset)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
                    .accessibilityLabel(preset.rawValue)
                    .accessibilityAddTraits(store.preset == preset ? .isSelected : [])
                }
                ColorPicker(selection: customBinding, supportsOpacity: false) {
                    Text("Custom colour")
                }
                .labelsHidden()
                .overlay {
                    if store.preset == .custom {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36)
                .accessibilityAddTraits(store.preset == .custom ? .isSelected : [])
            }
            if store.preset == .custom, let warning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drome.settings.accent")
    }

    private func swatchView(_ colour: Color, selected: Bool) -> some View {
        Circle()
            .fill(colour)
            .frame(width: Self.swatch, height: Self.swatch)
            .overlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }

    private var customBinding: Binding<Color> {
        Binding {
            Color(
                .sRGB,
                red: store.customRGB[0],
                green: store.customRGB[1],
                blue: store.customRGB[2])
        } set: { colour in
            let resolved = colour.resolve(in: EnvironmentValues())
            store.setCustomRGB([
                Double(resolved.red),
                Double(resolved.green),
                Double(resolved.blue),
            ])
        }
    }

    private var warning: String? {
        let luminance = Self.relativeLuminance(store.customRGB)
        if luminance < Self.darkest {
            return "This colour is hard to see on Drome’s dark background."
        }
        if luminance > Self.lightest {
            return "White labels are hard to read on this colour."
        }
        return nil
    }

    static func relativeLuminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { c in
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
