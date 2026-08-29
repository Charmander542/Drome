import UIKit

/// Album-art wash colors for the live widget background.
enum WidgetArtWash {
    static func fromArtworkFile(_ file: String?) -> (r: Double, g: Double, b: Double) {
        guard let file,
              let url = WidgetRecentStore.artworkURL(for: file),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data),
              let sampled = sampleColor(from: image)
        else { return defaultWash }
        return soften(sampled)
    }

    static let defaultWash: (r: Double, g: Double, b: Double) = (0.52, 0.54, 0.58)

    /// Downsample and average so the wash reflects the cover, not a single pixel.
    private static func sampleColor(from image: UIImage) -> (r: Double, g: Double, b: Double)? {
        guard let cg = image.cgImage else { return nil }
        let sample = 24
        var pixels = [UInt8](repeating: 0, count: sample * sample * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: sample,
            height: sample,
            bitsPerComponent: 8,
            bytesPerRow: sample * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sample, height: sample))

        var rSum = 0.0, gSum = 0.0, bSum = 0.0, weight = 0.0
        for y in 0..<sample {
            for x in 0..<sample {
                let i = (y * sample + x) * 4
                let a = Double(pixels[i + 3]) / 255
                guard a > 0.12 else { continue }
                let w = a
                rSum += Double(pixels[i]) / 255 * w
                gSum += Double(pixels[i + 1]) / 255 * w
                bSum += Double(pixels[i + 2]) / 255 * w
                weight += w
            }
        }
        guard weight > 0 else { return nil }
        return (rSum / weight, gSum / weight, bSum / weight)
    }

    /// Lighten for legibility while keeping the art hue (avoid flat gray).
    static func soften(_ raw: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        var r = raw.r, g = raw.g, b = raw.b

        // Slightly boost saturation so muted covers still tint the widget.
        let gray = (r + g + b) / 3
        let satBoost = 1.35
        r = gray + (r - gray) * satBoost
        g = gray + (g - gray) * satBoost
        b = gray + (b - gray) * satBoost
        r = min(max(r, 0), 1)
        g = min(max(g, 0), 1)
        b = min(max(b, 0), 1)

        var lum = 0.299 * r + 0.587 * g + 0.114 * b
        let target = 0.56
        if lum < target {
            let scale = target / max(lum, 0.05)
            r = min(r * scale, 1)
            g = min(g * scale, 1)
            b = min(b * scale, 1)
            lum = 0.299 * r + 0.587 * g + 0.114 * b
        }
        if lum > 0.80 {
            let scale = 0.80 / lum
            r *= scale
            g *= scale
            b *= scale
        }
        return (r, g, b)
    }
}
