import SwiftUI

struct AlbumCard: View {
    let album: Album
    @Environment(\.session) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: session?.client.coverArtURL(id: album.coverArt ?? album.id, size: 300))
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 4) {
                Text(album.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let rating = album.userRating, rating > 0 {
                    RatingBadge(rating: rating, size: 10)
                }
            }
            Text(album.artist ?? "Unknown Artist")
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
        }
        // Keep covers flat — system hover / parallax lift looks like a weird 3D drag.
        .hoverEffectDisabled()
        .transaction { $0.animation = nil }
    }
}

struct HorizontalAlbumRail: View {
    let title: String
    let albums: [Album]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(DromeTheme.headlineFont)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(albumID: album.id, placeholder: album)
                        } label: {
                            AlbumCard(album: album)
                                .frame(width: 148)
                        }
                        .buttonStyle(.plain)
                        .hoverEffectDisabled()
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    @Environment(\.session) private var session
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: session?.client.coverArtURL(id: playlist.coverArt ?? playlist.id, size: 300),
                        placeholderSymbol: "music.note.list")
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 4) {
                Text(playlist.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if downloads.isPlaylistFullyDownloaded(
                    playlistId: playlist.id,
                    expectedCount: playlist.songCount ?? 0)
                {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(DromeTheme.accent)
                }
            }
            Text(playlist.songCount.map { "\($0) songs" } ?? "Playlist")
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
        }
        .hoverEffectDisabled()
        .transaction { $0.animation = nil }
    }
}

struct HorizontalPlaylistRail: View {
    let title: String
    let playlists: [Playlist]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(DromeTheme.headlineFont)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlistID: playlist.id)
                        } label: {
                            PlaylistCard(playlist: playlist)
                                .frame(width: 148)
                        }
                        .buttonStyle(.plain)
                        .hoverEffectDisabled()
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DromeTheme.headlineFont)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(DromeTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

struct LoadingStateView: View {
    var message: String = "Loading…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(DromeTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(DromeTheme.muted)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(DromeTheme.muted)
                .padding(.horizontal, 32)
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(DromeTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let title: String
    var systemImage: String = "music.note"
    var message: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        }
        .foregroundStyle(DromeTheme.muted)
    }
}
