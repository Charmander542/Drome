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

/// Wide, short fallback image so the template bubble is not a tall square cover.
enum MessageCardImage {
    static let art: CGFloat = 56
    static let height: CGFloat = 64
    static let width: CGFloat = 248

    static func render(cover: UIImage?, title: String, artist: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { _ in
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            UIColor.black.setFill()
            UIRectFill(bounds)

            let artRect = CGRect(x: 4, y: 4, width: art, height: art)
            UIGraphicsGetCurrentContext()?.saveGState()
            UIBezierPath(roundedRect: artRect, cornerRadius: 7).addClip()
            if let cover, cover.size.width > 0, cover.size.height > 0 {
                let scale = max(art / cover.size.width, art / cover.size.height)
                let w = cover.size.width * scale
                let h = cover.size.height * scale
                cover.draw(in: CGRect(x: artRect.midX - w / 2, y: artRect.midY - h / 2, width: w, height: h))
            } else {
                UIColor(white: 0.18, alpha: 1).setFill()
                UIBezierPath(rect: artRect).fill()
            }
            UIGraphicsGetCurrentContext()?.restoreGState()

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let artistAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(0.7),
            ]
            (title as NSString).draw(in: CGRect(x: 68, y: 14, width: width - 76, height: 18), withAttributes: titleAttrs)
            if !artist.isEmpty {
                (artist as NSString).draw(in: CGRect(x: 68, y: 32, width: width - 76, height: 16), withAttributes: artistAttrs)
            }
        }
    }
}
