import AVFoundation
import UIKit

enum PreviewClip {
    /// Best-effort 30s AAC written next to the extension so `MSMessageTemplateLayout.mediaFileURL`
    /// can ship playable audio to people who do not have Drome installed.
    static func export(from streamURL: URL) async -> URL? {
        let asset = AVURLAsset(url: streamURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("drome-preview-\(UUID().uuidString).m4a")
        session.outputURL = out
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 30, preferredTimescale: 600))
        session.shouldOptimizeForNetworkUse = true
        let finished: Bool = await withCheckedContinuation { cont in
            var resumed = false
            let finish: (Bool) -> Void = { ok in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: ok)
            }
            session.exportAsynchronously {
                finish(session.status == .completed)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                if session.status == .exporting || session.status == .waiting {
                    session.cancelExport()
                }
            }
        }
        return finished && FileManager.default.fileExists(atPath: out.path) ? out : nil
    }
}

enum CoverImage {
    static func uiImage(from data: Data?) -> UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
    }
}

/// Tall art-on-top card for people without Drome (template layout).
enum MessageCardImage {
    static let side: CGFloat = 300
    static let textHeight: CGFloat = 76

    static func render(cover: UIImage?, title: String, artist: String) -> UIImage {
        let size = CGSize(width: side, height: side + textHeight)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            let artRect = CGRect(x: 0, y: 0, width: side, height: side)
            if let cover, cover.size.width > 0, cover.size.height > 0 {
                let scale = max(side / cover.size.width, side / cover.size.height)
                let w = cover.size.width * scale
                let h = cover.size.height * scale
                cover.draw(in: CGRect(x: artRect.midX - w / 2, y: artRect.midY - h / 2, width: w, height: h))
            } else {
                UIColor(white: 0.16, alpha: 1).setFill()
                UIRectFill(artRect)
            }

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let artistAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(0.7),
            ]
            let textX: CGFloat = 16
            let textW = side - 32
            (title as NSString).draw(in: CGRect(x: textX, y: side + 14, width: textW, height: 22), withAttributes: titleAttrs)
            if !artist.isEmpty {
                (artist as NSString).draw(in: CGRect(x: textX, y: side + 38, width: textW, height: 20), withAttributes: artistAttrs)
            }
        }
    }
}
