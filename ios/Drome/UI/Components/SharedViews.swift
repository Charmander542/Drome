import SwiftUI

enum LibraryPlayback {
    @MainActor
    static func play(album: Album, session: AppSession) {
        Task {
            if let full = try? await session.client.album(id: album.id), !full.songs.isEmpty {
                LibraryDetailCache.store(album: full)
                session.player.play(
                    full.songs, startAt: 0,
                    context: PlaybackContext(label: album.name, kind: .album(id: album.id)))
            }
        }
    }
}

struct AlbumCard: View {
    let album: Album
    @Environment(\.session) private var session
    @Environment(\.songNavigator) private var songNavigator

    var body: some View {
        Button(action: play) {
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
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded {
                            songNavigator?.viewAlbum(album)
                        })
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("View album \(album.name)")
                    if let rating = album.userRating, rating > 0 {
                        RatingBadge(rating: rating, size: 10)
                    }
                }
                Text(album.artist ?? "Unknown Artist")
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded {
                        openArtist()
                    })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("View \(album.artist ?? "artist")")
            }
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
        .transaction { $0.animation = nil }
        .accessibilityHint("Plays the album. Album and artist names open their pages.")
    }

    private func play() {
        guard let session else { return }
        LibraryPlayback.play(album: album, session: session)
    }

    private func openArtist() {
        if let id = album.artistId, !id.isEmpty {
            songNavigator?.viewArtist(id: id, name: album.artist ?? "")
            return
        }
        guard let session, let name = album.artist, !name.isEmpty else { return }
        Task { @MainActor in
            if let id = await SongArtistLinks.resolveArtistID(name: name, client: session.client) {
                songNavigator?.viewArtist(id: id, name: name)
            }
        }
    }
}

/// List/search album row: cover & empty space play; album/artist names navigate.
struct AlbumMediaRow: View {
    let album: Album
    var subtitle: String? = nil
    var artistTappable: Bool = true
    var showsChevron: Bool = false
    var coverSize: CGFloat = 56
    var trailing: AnyView? = nil

    @Environment(\.session) private var session
    @Environment(\.songNavigator) private var songNavigator

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                RemoteImage(url: session?.client.coverArtURL(id: album.coverArt ?? album.id, size: 120))
                    .frame(width: coverSize, height: coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(DromeTheme.rowTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded {
                            songNavigator?.viewAlbum(album)
                        })
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("View album \(album.name)")

                    Text(subtitle ?? album.artist ?? "Unknown Artist")
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded {
                            guard artistTappable else { return }
                            openArtist()
                        })
                        .accessibilityAddTraits(artistTappable ? .isButton : [])
                }

                Spacer(minLength: 0)

                if let trailing {
                    trailing
                } else if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DromeTheme.muted.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays the album. Album and artist names open their pages.")
    }

    private func play() {
        guard let session else { return }
        LibraryPlayback.play(album: album, session: session)
    }

    private func openArtist() {
        if let id = album.artistId, !id.isEmpty {
            songNavigator?.viewArtist(id: id, name: album.artist ?? "")
            return
        }
        guard let session, let name = album.artist, !name.isEmpty else { return }
        Task { @MainActor in
            if let id = await SongArtistLinks.resolveArtistID(name: name, client: session.client) {
                songNavigator?.viewArtist(id: id, name: name)
            }
        }
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
                        AlbumCard(album: album)
                            .frame(width: 148)
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
