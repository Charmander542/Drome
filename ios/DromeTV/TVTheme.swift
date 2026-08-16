import SwiftUI

enum TVTheme {
    static let canvas = Color(red: 0.04, green: 0.04, blue: 0.045)
    static let ink = Color.white
    static let dim = Color.white.opacity(0.52)
    static let accent = DromeTheme.accent
    static let gutter: CGFloat = 80
    /// Square art matches the tvOS focus highlight.
    static let poster: CGFloat = 280
    static let hero: CGFloat = 400
    static let posterGap: CGFloat = 48
    static let posterPad: CGFloat = 28
    static var posterCell: CGFloat { poster + posterPad * 2 }
    static let focusPad: CGFloat = 56
}

struct TVScreenTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 44, weight: .bold, design: .rounded))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(TVTheme.dim)
            }
        }
    }
}

struct TVPosterArt: View {
    var coverArt: String?
    var fallbackId: String
    var size: CGFloat = TVTheme.poster
    var placeholder: String = "music.note"

    @EnvironmentObject private var session: AppSession

    var body: some View {
        RemoteImage(
            url: session.artworkURL(id: coverArt ?? fallbackId, size: Int(size * 2)),
            placeholderSymbol: placeholder)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct TVPosterCaption: View {
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = TVTheme.poster

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(TVTheme.dim)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Square artwork is the focusable control; title sits under the highlight box.
struct TVPosterButton: View {
    let title: String
    var subtitle: String? = nil
    var coverArt: String?
    var fallbackId: String
    var size: CGFloat = TVTheme.poster
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: action) {
                TVPosterArt(coverArt: coverArt, fallbackId: fallbackId, size: size)
            }
            TVPosterCaption(title: title, subtitle: subtitle, width: size)
        }
        .frame(width: size, alignment: .leading)
        .padding(.horizontal, TVTheme.posterPad)
    }
}

struct TVPosterLink<Destination: View>: View {
    let title: String
    var subtitle: String? = nil
    var coverArt: String?
    var fallbackId: String
    var size: CGFloat = TVTheme.poster
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink(destination: destination) {
                TVPosterArt(coverArt: coverArt, fallbackId: fallbackId, size: size)
            }
            TVPosterCaption(title: title, subtitle: subtitle, width: size)
        }
        .frame(width: size, alignment: .leading)
        .padding(.horizontal, TVTheme.posterPad)
    }
}

struct TVRail<Item: Identifiable, Content: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder var content: (Item) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .padding(.horizontal, TVTheme.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: TVTheme.posterGap) {
                    ForEach(items) { item in
                        content(item)
                    }
                }
                .padding(.horizontal, TVTheme.gutter - TVTheme.posterPad)
                .padding(.vertical, TVTheme.focusPad)
            }
        }
    }
}

struct TVQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
