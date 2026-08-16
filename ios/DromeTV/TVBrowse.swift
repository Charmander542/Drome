import SwiftUI

struct TVAlbumDetailView: View {
    let albumID: String
    let name: String

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @State private var album: AlbumWithSongs?
    @State private var error: String?

    var body: some View {
        TVSongList(
            title: album?.name ?? name,
            subtitle: album?.artist,
            coverArt: album?.coverArt ?? albumID,
            songs: album?.songs ?? [],
            error: error,
            onPlay: { index in
                guard let album, !album.songs.isEmpty else { return }
                player.play(album.songs, startAt: index,
                            context: PlaybackContext(label: album.name, kind: .album(id: album.id)))
                NowPlayingPresenter.open()
            })
        .task {
            do { album = try await session.client.album(id: albumID) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct TVPlaylistDetailView: View {
    let playlistID: String
    let name: String

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @State private var playlist: PlaylistWithSongs?
    @State private var error: String?

    var body: some View {
        TVSongList(
            title: playlist?.name ?? name,
            subtitle: Playlist.songCountLabel(playlist?.songs.count ?? playlist?.songCount),
            coverArt: playlist?.coverArt ?? playlistID,
            songs: playlist?.songs ?? [],
            error: error,
            onPlay: { index in
                guard let playlist, !playlist.songs.isEmpty else { return }
                player.play(playlist.songs, startAt: index,
                            context: PlaybackContext(label: playlist.name, kind: .playlist(id: playlist.id)))
                NowPlayingPresenter.open()
            })
        .task {
            do { playlist = try await session.client.playlist(id: playlistID) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct TVArtistDetailView: View {
    let artistID: String
    let name: String

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @State private var artist: ArtistWithAlbums?
    @State private var topSongs: [Song] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                HStack(alignment: .bottom, spacing: 32) {
                    RemoteImage(
                        url: session.artworkURL(id: artist?.coverArt ?? artistID, size: 500),
                        placeholderSymbol: "person.fill")
                        .frame(width: 260, height: 260)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 16) {
                        Text(artist?.name ?? name)
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                        if !topSongs.isEmpty {
                            Button("Play top songs") {
                                player.play(topSongs, startAt: 0,
                                            context: PlaybackContext(label: name, kind: .artist(id: artistID)))
                                NowPlayingPresenter.open()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, TVTheme.gutter)

                if let error {
                    Text(error).foregroundStyle(.red).padding(.horizontal, TVTheme.gutter)
                }

                if !topSongs.isEmpty {
                    TVSongList(
                        title: "Top songs",
                        subtitle: nil,
                        coverArt: artist?.coverArt ?? artistID,
                        songs: Array(topSongs.prefix(12)),
                        error: nil,
                        compact: true,
                        onPlay: { index in
                            player.play(topSongs, startAt: index,
                                        context: PlaybackContext(label: name, kind: .artist(id: artistID)))
                            NowPlayingPresenter.open()
                        })
                }

                if let albums = artist?.albums, !albums.isEmpty {
                    TVRail(title: "Albums", items: albums) { album in
                        TVPosterLink(
                            title: album.name,
                            subtitle: album.year.map(String.init),
                            coverArt: album.coverArt,
                            fallbackId: album.id)
                        {
                            TVAlbumDetailView(albumID: album.id, name: album.name)
                        }
                    }
                }
            }
            .padding(.vertical, 36)
        }
        .background(TVTheme.canvas.ignoresSafeArea())
        .task {
            do {
                artist = try await session.client.artist(id: artistID)
                topSongs = (try? await session.client.topSongs(artistName: name)) ?? []
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct TVSongList: View {
    let title: String
    var subtitle: String?
    let coverArt: String
    let songs: [Song]
    var error: String?
    var compact: Bool = false
    var onPlay: (Int) -> Void

    @EnvironmentObject private var session: AppSession

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            if !compact {
                VStack(alignment: .leading, spacing: 18) {
                    RemoteImage(
                        url: session.artworkURL(id: coverArt, size: 800),
                        placeholderSymbol: "music.note")
                        .frame(width: 360, height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    if let subtitle {
                        Text(subtitle).font(.title3).foregroundStyle(TVTheme.dim)
                    }
                    if !songs.isEmpty {
                        Button("Play") { onPlay(0) }
                            .buttonStyle(.plain)
                    }
                }
                .frame(width: 380, alignment: .leading)
                .padding(.leading, TVTheme.gutter)
                .padding(.top, 28)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if compact {
                        Text(title)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .padding(.bottom, 8)
                    }
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        Button {
                            onPlay(index)
                        } label: {
                            HStack(spacing: 20) {
                                Text("\(index + 1)")
                                    .font(.title3.monospacedDigit())
                                    .foregroundStyle(TVTheme.dim)
                                    .frame(width: 44, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(song.title).font(.title3.weight(.semibold))
                                    Text(song.displayArtist)
                                        .font(.body)
                                        .foregroundStyle(TVTheme.dim)
                                }
                                Spacer()
                                Text(song.durationText)
                                    .foregroundStyle(TVTheme.dim)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, compact ? TVTheme.gutter : 12)
                .padding(.vertical, 28)
            }
        }
        .background(TVTheme.canvas.ignoresSafeArea())
    }
}
