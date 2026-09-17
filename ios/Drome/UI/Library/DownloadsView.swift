import SwiftUI

struct DownloadsView: View {
    var isOfflineMode: Bool = false

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: PlayerEngine

    private var active: [DownloadRecord] {
        downloads.records.filter {
            $0.state == "downloading" || $0.state == "queued" || $0.state == "failed"
        }
    }

    private var downloadedSongs: [Song] {
        downloads.records
            .filter { $0.state == "done" }
            .compactMap(song(from:))
            .sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    private var playbackContext: PlaybackContext {
        PlaybackContext(label: isOfflineMode ? "Offline Library" : "Downloaded", kind: .mix)
    }

    var body: some View {
        List {
            if !active.isEmpty {
                Section("In progress") {
                    ForEach(active, id: \.songId) { record in
                        ActiveDownloadRow(record: record, progress: downloads.liveProgress) {
                            downloads.cancel(songId: record.songId)
                        }
                        .listRowBackground(DromeTheme.background)
                    }
                }
            }

            Section {
                downloadsHeader
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))

                HStack(spacing: 12) {
                    Button {
                        player.play(downloadedSongs, startAt: 0, context: playbackContext)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DromeTheme.accent)
                    .foregroundStyle(.white)
                    .disabled(downloadedSongs.isEmpty)

                    Button {
                        player.playShuffled(downloadedSongs, context: playbackContext)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(downloadedSongs.isEmpty)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                if !isOfflineMode, !downloadedSongs.isEmpty {
                    Button(role: .destructive) {
                        downloads.removeAll()
                    } label: {
                        Label("Remove All Downloads", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowBackground(DromeTheme.elevated)
                }
            }

            Section {
                if downloadedSongs.isEmpty {
                    EmptyStateView(
                        title: isOfflineMode ? "No downloads available" : "No downloads yet",
                        systemImage: "arrow.down.circle",
                        message: isOfflineMode
                            ? "Connect to your server, then download albums or playlists for offline listening."
                            : "Download albums or playlists from their detail screens for offline listening.")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(downloadedSongs.enumerated()), id: \.element.id) { index, song in
                        SongRow(
                            song: song,
                            showAlbum: true,
                            trailing: isOfflineMode ? nil : AnyView(
                                Button(role: .destructive) {
                                    downloads.remove(songId: song.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            ),
                            onPlay: {
                                player.play(
                                    downloadedSongs, startAt: index,
                                    context: playbackContext)
                            }
                        )
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(isOfflineMode ? "Offline Library" : "Downloaded")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var downloadsHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DromeTheme.elevated2)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(DromeTheme.accent)
            }
            .frame(width: 180, height: 180)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)

            VStack(spacing: 6) {
                Text(isOfflineMode ? "Offline Library" : "Downloaded")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
            }
        }
    }

    private var headerSubtitle: String {
        let count = downloadedSongs.count
        let songs = count == 1 ? "1 song" : "\(count) songs"
        let size = Formatters.fileSize(downloads.totalBytesUsed)
        return count == 0 ? size : "\(songs) · \(size)"
    }

    private func song(from record: DownloadRecord) -> Song? {
        downloads.song(forDownloadedId: record.songId)
            ?? (try? JSONDecoder().decode(Song.self, from: Data(record.songJSON.utf8)))
    }
}

private struct ActiveDownloadRow: View {
    let record: DownloadRecord
    @ObservedObject var progress: DownloadProgressStore
    let onCancel: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DromeTheme.rowTitle)
                Text(record.state.capitalized)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
            }
            Spacer()
            if let value = progress.values[record.songId] {
                ProgressView(value: value)
                    .frame(width: 60)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DromeTheme.muted)
            }
            .buttonStyle(.plain)
        }
    }

    private var title: String {
        (try? JSONDecoder().decode(Song.self, from: Data(record.songJSON.utf8)))?.title
            ?? record.songId
    }
}
