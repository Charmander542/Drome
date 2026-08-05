import SwiftUI

struct GenreDetailView: View {
    let genre: NormalizedGenre

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var ratings: RatingsStore

    @State private var albums: [Album] = []
    @State private var songs: [Song] = []
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading && albums.isEmpty && songs.isEmpty {
                LoadingStateView()
            } else if let error, albums.isEmpty {
                ErrorStateView(message: error) { Task { await load() } }
            } else {
                List {
                    if !songs.isEmpty {
                        Section {
                            HStack(spacing: 12) {
                                Button {
                                    player.play(songs, startAt: 0,
                                                context: PlaybackContext(label: genre.displayName, kind: .genre))
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(DromeTheme.accent)
                                .foregroundStyle(.black)

                                Button {
                                    player.playShuffled(songs,
                                                        context: PlaybackContext(label: genre.displayName, kind: .genre))
                                } label: {
                                    Label("Shuffle", systemImage: "shuffle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(.white)
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }

                        Section("Songs") {
                            ForEach(Array(songs.prefix(40).enumerated()), id: \.element.id) { index, song in
                                SongRow(song: song, showAlbum: true)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        player.play(songs, startAt: index,
                                                    context: PlaybackContext(label: genre.displayName, kind: .genre))
                                    }
                                    .listRowBackground(DromeTheme.background)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            }
                        }
                    }

                    if !albums.isEmpty {
                        Section("Albums") {
                            ForEach(albums) { album in
                                NavigationLink {
                                    AlbumDetailView(albumID: album.id, placeholder: album)
                                } label: {
                                    HStack(spacing: 12) {
                                        RemoteImage(url: session.client.coverArtURL(id: album.coverArt ?? album.id, size: 120))
                                            .frame(width: 48, height: 48)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.name).font(DromeTheme.rowTitle)
                                            Text(album.artist ?? "")
                                                .font(.caption)
                                                .foregroundStyle(DromeTheme.muted)
                                        }
                                    }
                                }
                                .listRowBackground(DromeTheme.background)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
            }
        }
        .navigationTitle(genre.displayName)
        .task(id: genre.id) { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        let tags = genre.rawTags.isEmpty ? [genre.displayName] : genre.rawTags
        let client = session.client
        var albumByID: [String: Album] = [:]
        var songByID: [String: Song] = [:]
        var lastError: Error?

        await withTaskGroup(of: (albums: [Album], songs: [Song], error: Error?).self) { group in
            for tag in tags {
                group.addTask {
                    do {
                        async let a = client.albumList(type: .byGenre, size: 100, genre: tag)
                        async let s = client.songsByGenre(tag, count: 100)
                        let (albums, songs) = try await (a, s)
                        return (albums, songs, nil)
                    } catch {
                        return ([], [], error)
                    }
                }
            }
            for await result in group {
                for album in result.albums { albumByID[album.id] = album }
                for song in result.songs { songByID[song.id] = song }
                if let err = result.error { lastError = err }
            }
        }

        albums = albumByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        songs = songByID.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        ratings.ingest(songs)

        if albums.isEmpty && songs.isEmpty, let lastError {
            self.error = lastError.localizedDescription
        }
    }
}
