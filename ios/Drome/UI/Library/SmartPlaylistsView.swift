import SwiftUI

/// Rule-based auto playlists (Subsonify Pro–style smart playlists).
struct SmartPlaylistsView: View {
    private let definitions = SmartPlaylistCatalog.builtIn

    var body: some View {
        List {
            Section {
                Text("Auto playlists from your ratings, listening history, and downloads. They update as you listen.")
                    .font(.subheadline)
                    .foregroundStyle(DromeTheme.muted)
                    .listRowBackground(DromeTheme.background)
            }

            Section {
                ForEach(definitions) { definition in
                    NavigationLink {
                        SmartPlaylistDetailView(definition: definition)
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(DromeTheme.accent.opacity(0.22))
                                Image(systemName: definition.systemImage)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(DromeTheme.accent)
                            }
                            .frame(width: 52, height: 52)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(definition.name)
                                    .font(DromeTheme.rowTitle)
                                    .foregroundStyle(.white)
                                Text(definition.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
                        }
                    }
                    .listRowBackground(DromeTheme.background)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Smart Playlists")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SmartPlaylistDetailView: View {
    let definition: SmartPlaylistDefinition

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var downloads: DownloadManager

    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var keepDownloaded = false

    private var playbackContext: PlaybackContext {
        PlaybackContext(label: definition.name, kind: .mix)
    }

    var body: some View {
        Group {
            if isLoading && songs.isEmpty {
                LoadingStateView()
            } else if songs.isEmpty {
                EmptyStateView(
                    title: "Nothing here yet",
                    systemImage: definition.systemImage,
                    message: emptyMessage)
            } else {
                songsContent
            }
        }
        .navigationTitle(definition.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        player.play(songs, startAt: 0, context: playbackContext)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .accessibilityLabel("Play All")
                }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: keepDownloaded) { _, enabled in
            SmartPlaylistDownloadStore.setKeepDownloaded(enabled, for: definition.id)
            if enabled { downloads.download(songs) }
        }
    }

    private var songsContent: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Button {
                        player.play(songs, startAt: 0, context: playbackContext)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DromeTheme.accent)
                    .foregroundStyle(.white)

                    Button {
                        player.playShuffled(songs, context: playbackContext)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                Toggle(isOn: $keepDownloaded) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep downloaded")
                        Text("Auto-download matching tracks for offline (SubSonify-style).")
                            .font(.caption)
                            .foregroundStyle(DromeTheme.muted)
                    }
                }
                .tint(DromeTheme.accent)
                .listRowBackground(DromeTheme.elevated)

                Text("\(songs.count) song\(songs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, showAlbum: true) {
                        player.play(songs, startAt: index, context: playbackContext)
                    }
                    .listRowBackground(DromeTheme.background)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyMessage: String {
        switch definition.id {
        case "recently-played":
            return "Play some tracks and they’ll show up here for two weeks."
        case "unplayed-favorites":
            return "Rate tracks 4+ stars, then leave them alone for a month."
        case "five-star":
            return "Give tracks five stars on the Now Playing screen."
        case "downloaded":
            return "Download albums or playlists for offline listening."
        case "this-year":
            return "Tracks tagged with this calendar year will appear here."
        default:
            return "No matching tracks in your local library yet."
        }
    }

    private func reload() async {
        isLoading = songs.isEmpty
        defer { isLoading = false }
        keepDownloaded = SmartPlaylistDownloadStore.keepDownloaded(for: definition.id)
        let definition = self.definition
        let userKey = session.account.userKey
        let database = session.database
        let downloads = self.downloads
        songs = SmartPlaylistEngine.evaluate(
            definition: definition,
            userKey: userKey,
            database: database,
            downloads: downloads)
        if keepDownloaded, !songs.isEmpty {
            downloads.download(songs)
        }
    }
}

/// Persist “keep downloaded” flags for smart playlists (SubSonify Pro parity).
enum SmartPlaylistDownloadStore {
    private static let prefix = "drome.smartPlaylist.keepDownloaded."

    static func keepDownloaded(for id: String) -> Bool {
        UserDefaults.standard.bool(forKey: prefix + id)
    }

    static func setKeepDownloaded(_ value: Bool, for id: String) {
        UserDefaults.standard.set(value, forKey: prefix + id)
    }
}
