import SwiftUI
import UIKit

/// Full-bleed atmospheric wash from a dominant artwork color.
struct ArtworkWash: View {
    var color: Color
    var intensity: Double = 0.55

    var body: some View {
        ZStack {
            DromeTheme.background
            LinearGradient(
                colors: [
                    color.opacity(intensity),
                    color.opacity(intensity * 0.35),
                    DromeTheme.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Extracts a dominant color from cover art for washes / accents.
@MainActor
enum ArtworkPalette {
    static func dominantColor(from image: UIImage?) -> Color? {
        guard let image, let cg = image.cgImage else { return nil }
        let width = 16
        let height = 16
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var rSum = 0, gSum = 0, bSum = 0, count = 0
        for i in 0..<(width * height) {
            let o = i * 4
            let a = Int(ptr[o + 3])
            guard a > 32 else { continue }
            rSum += Int(ptr[o])
            gSum += Int(ptr[o + 1])
            bSum += Int(ptr[o + 2])
            count += 1
        }
        guard count > 0 else { return nil }
        return Color(
            red: Double(rSum) / Double(count) / 255,
            green: Double(gSum) / Double(count) / 255,
            blue: Double(bSum) / Double(count) / 255
        )
    }
}

/// SoundCloud-style bold media card with optional overlay title.
struct DromeArtCard: View {
    let title: String
    var subtitle: String? = nil
    var coverURL: URL? = nil
    var overlayTint: Color? = nil
    var badge: QualityBadge.Kind? = nil
    var width: CGFloat = 156
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: DromeTheme.Space.sm) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: coverURL, placeholderSymbol: "music.note")
                        .aspectRatio(1, contentMode: .fill)
                        .frame(width: width, height: width)
                        .clipped()

                    if let overlayTint {
                        LinearGradient(
                            colors: [.clear, overlayTint.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }

                    if let badge {
                        QualityBadge(kind: badge, compact: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: DromeTheme.Radius.md, style: .continuous))

                Text(title)
                    .font(DromeTheme.rowTitle)
                    .foregroundStyle(DromeTheme.ink)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(DromeTheme.captionFont)
                        .foregroundStyle(DromeTheme.muted)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

/// Section rail chrome used on Home.
struct DromeRail<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DromeTheme.Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DromeTheme.headlineFont)
                    .foregroundStyle(DromeTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(DromeTheme.captionFont)
                        .foregroundStyle(DromeTheme.muted)
                }
            }
            .padding(.horizontal, DromeTheme.Space.lg)
            content()
        }
    }
}

#if DEBUG
/// Living styleguide for Listening Club tokens (DEBUG only).
struct DromeDesignSystemGuide: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Listening Club")
                    .font(DromeTheme.brandFont)
                Text("Design tokens")
                    .font(DromeTheme.overlineFont)
                    .tracking(1.4)
                    .foregroundStyle(DromeTheme.accent)

                HStack(spacing: 12) {
                    swatch("bg", DromeTheme.background)
                    swatch("surface", DromeTheme.surface)
                    swatch("raised", DromeTheme.surfaceRaised)
                    swatch("accent", DromeTheme.accent)
                }

                HStack(spacing: 8) {
                    QualityBadge(kind: .lossless)
                    QualityBadge(kind: .compressed)
                    QualityBadge(kind: .cached)
                }

                DromeArtCard(
                    title: "Daily Mix",
                    subtitle: "Sample card",
                    overlayTint: MoodVibe.hype.wash,
                    badge: .lossless,
                    width: 140
                )
            }
            .padding(20)
        }
        .dromeScreen()
        .navigationTitle("Design System")
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .frame(width: 56, height: 56)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DromeTheme.divider, lineWidth: 1)
                }
            Text(label).font(.caption2).foregroundStyle(DromeTheme.muted)
        }
    }
}
#endif
