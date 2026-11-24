import SwiftUI

/// 1- or 4-up collage of cover art for mix thumbnails.
///
/// Adapted from Aura’s `MixCollageView` (GPL-3.0) — see NOTICE.
struct MixCollageView: View {
    let coverIDs: [String]
    var cornerRadius: CGFloat = 6

    @EnvironmentObject private var session: AppSession

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Group {
                if coverIDs.count >= 4 {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            tile(coverIDs[0], side: side / 2)
                            tile(coverIDs[1], side: side / 2)
                        }
                        HStack(spacing: 0) {
                            tile(coverIDs[2], side: side / 2)
                            tile(coverIDs[3], side: side / 2)
                        }
                    }
                    .frame(width: side, height: side)
                } else if let first = coverIDs.first {
                    tile(first, side: side)
                } else {
                    Color(DromeTheme.elevated2)
                        .frame(width: side, height: side)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func tile(_ id: String, side: CGFloat) -> some View {
        RemoteImage(url: session.artworkURL(id: id, size: 300), placeholderSymbol: "music.note")
            .frame(width: side, height: side)
            .clipped()
    }
}
