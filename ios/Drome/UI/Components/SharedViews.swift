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
        // NavigationLink stacks on top of an already-pushed artist page.
        // `songNavigator.viewAlbum` shares one root `navigationDestination(item:)`
        // slot and replaces the artist — back then skips to the player / tab root.
        NavigationLink {
            AlbumDetailView(albumID: album.id, placeholder: album)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RemoteImage(url: session?.artworkURL(id: album.coverArt ?? album.id, size: 300))
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DromeTheme.Radius.md, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: DromeTheme.Radius.md, style: .continuous))
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
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
        .transaction { $0.animation = nil }
        .accessibilityHint("Opens the album")
        .contextMenu {
            if album.artist?.isEmpty == false {
                Button(action: openArtist) {
                    Label("View Artist", systemImage: "person.wave.2")
                }
            }
        }
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

/// List/search album row: tap anywhere opens the album (List swallows nested Buttons).
struct AlbumMediaRow: View {
    let album: Album
    var subtitle: String? = nil
    var artistTappable: Bool = true
    var showsChevron: Bool = false
    var coverSize: CGFloat = 56
    var trailing: AnyView? = nil
    /// Extra work before navigation (e.g. remember a search hit).
    var onOpen: (() -> Void)? = nil

    @Environment(\.session) private var session
    @Environment(\.songNavigator) private var songNavigator

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: session?.artworkURL(id: album.coverArt ?? album.id, size: 120))
                .frame(width: coverSize, height: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(DromeTheme.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitle ?? album.artist ?? "Unknown Artist")
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { openAlbum() })
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("View album \(album.name)")
        .accessibilityHint("Opens the album")
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            guard let session else { return }
            LibraryPlayback.play(album: album, session: session)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        if artistTappable, album.artist?.isEmpty == false {
            Button(action: openArtist) {
                Label("View Artist", systemImage: "person.wave.2")
            }
        }
    }

    private func openAlbum() {
        onOpen?()
        songNavigator?.viewAlbum(album)
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
    /// Nil / empty hides the section title (Qobuz-style bare album strip).
    var title: String? = nil
    let albums: [Album]
    /// Optional year · type caption under each album (discography style).
    var showsReleaseMeta: Bool = false
    var cardWidth: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(DromeTheme.headlineFont)
                    .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        if showsReleaseMeta {
                            DiscographyAlbumCard(album: album)
                                .frame(width: cardWidth, alignment: .topLeading)
                        } else {
                            AlbumCard(album: album)
                                .frame(width: cardWidth, alignment: .topLeading)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// Square cover + title + "Year · Album" caption for artist discography rails.
struct DiscographyAlbumCard: View {
    let album: Album
    @Environment(\.session) private var session

    private var meta: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("Album")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        // Same as AlbumCard — push via NavigationLink so artist → album → back
        // returns to the artist (not the Now Playing sheet / tab root).
        NavigationLink {
            AlbumDetailView(albumID: album.id, placeholder: album)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RemoteImage(url: session?.artworkURL(id: album.coverArt ?? album.id, size: 300))
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DromeTheme.Radius.md, style: .continuous))
                Text(album.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
        .transaction { $0.animation = nil }
        .accessibilityHint("Opens the album")
    }
}

struct HorizontalArtistRail: View {
    let title: String
    let artists: [Artist]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(DromeTheme.headlineFont)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(artists) { artist in
                        // NavigationLink stacks correctly when already on an artist page
                        // (songNavigator.artistRoute would replace instead of push).
                        NavigationLink {
                            ArtistDetailView(artistID: artist.id, placeholderName: artist.name)
                        } label: {
                            VStack(spacing: 8) {
                                ArtistAvatar(
                                    artistId: artist.id,
                                    name: artist.name,
                                    size: 96,
                                    navidromeCoverArt: artist.coverArt,
                                    allowsSpotifyLookup: true)
                                Text(artist.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 96)
                                Text("Artist")
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
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
            cover
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DromeTheme.Radius.md, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DromeTheme.Radius.md, style: .continuous))
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
                        .foregroundStyle(DromeTheme.muted)
                }
            }
            Text(playlist.songCountLabel)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
        }
        .hoverEffectDisabled()
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private var cover: some View {
        if let session {
            PlaylistArtwork(
                playlistID: playlist.id,
                coverArt: playlist.coverArt,
                session: session,
                size: 300)
        } else {
            Color(white: 0.16)
        }
    }
}

/// Playlist cover from Navidrome (`getCoverArt` on the playlist id / coverArt).
/// Always hits the server image so custom uploads and mosaics load; never gates
/// on a local “remembered collage” flag that left Library/Home blank.
struct PlaylistArtwork: View {
    let playlistID: String
    var coverArt: String?
    let session: AppSession
    var size: Int = 300
    var cacheBust: TimeInterval = 0
    var placeholderSymbol: String = "music.note.list"

    private var coverID: String {
        PlaylistCoverStore.serverCoverID(coverArt: coverArt, playlistID: playlistID)
    }

    private var url: URL? {
        session.artworkURL(id: coverID, size: size)
    }

    var body: some View {
        RemoteImage(url: url, placeholderSymbol: placeholderSymbol)
            .id("\(playlistID)-\(coverID)-\(Int(cacheBust))-\(size)")
            .onAppear {
                if let url {
                    ImageLoader.shared.clearFailed(for: url)
                }
            }
    }
}

/// Fills a square from 1–4 album covers with no empty mosaic tiles.
/// Kept for detail fallbacks; list/home prefer `PlaylistArtwork`.
struct PlaylistCoverCollage: View {
    let coverIDs: [String]
    let session: AppSession

    var body: some View {
        let ids = Array(coverIDs.prefix(4))
        GeometryReader { geo in
            let side = geo.size.width
            let half = side / 2
            switch ids.count {
            case 0:
                Color(white: 0.16)
            case 1:
                tile(ids[0], width: side, height: side)
            case 2:
                HStack(spacing: 0) {
                    tile(ids[0], width: half, height: side)
                    tile(ids[1], width: half, height: side)
                }
            case 3:
                HStack(spacing: 0) {
                    tile(ids[0], width: half, height: side)
                    VStack(spacing: 0) {
                        tile(ids[1], width: half, height: half)
                        tile(ids[2], width: half, height: half)
                    }
                }
            default:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(ids[0], width: half, height: half)
                        tile(ids[1], width: half, height: half)
                    }
                    HStack(spacing: 0) {
                        tile(ids[2], width: half, height: half)
                        tile(ids[3], width: half, height: half)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func tile(_ id: String, width: CGFloat, height: CGFloat) -> some View {
        RemoteImage(
            url: session.artworkURL(id: id, size: 300),
            placeholderSymbol: "music.note")
            .frame(width: width, height: height)
            .clipped()
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
    /// When true (default), fills the parent so the error centers on full-screen
    /// placeholders. Pass false inside ScrollViews at accessibility sizes — a
    /// viewport-tall frame clips oversized Dynamic Type content.
    var expandsToFill: Bool = true
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
        .frame(maxWidth: .infinity, maxHeight: expandsToFill ? .infinity : nil)
        .padding(.vertical, expandsToFill ? 0 : 24)
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

/// Scrollable empty chrome for accessibility sizes so oversized
/// `ContentUnavailableView` text stays reachable above the mini player.
struct ScrollableEmptyState<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
