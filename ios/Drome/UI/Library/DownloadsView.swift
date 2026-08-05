import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: PlayerEngine

    private var active: [DownloadRecord] {
        downloads.records.filter {
            $0.state == "downloading" || $0.state == "queued" || $0.state == "failed"
        }
    }

    /// Completed downloads grouped by album name, sorted for browsing.
    private var albumSections: [(name: String, songs: [Song])] {
        let done = downloads.records.filter { $0.state == "done" }
        let grouped = Dictionary(grouping: done) {
            $0.albumName.isEmpty ? "Tracks" : $0.albumName
        }
        return grouped.keys.sorted().compactMap { name in
            let songs = (grouped[name] ?? []).compactMap(song(from:))
            guard !songs.isEmpty else { return nil }
            return (name: name, songs: songs)
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Storage used")
                    Spacer()
                    Text(Formatters.fileSize(downloads.totalBytesUsed))
                        .foregroundStyle(DromeTheme.muted)
                }
                if !albumSections.isEmpty {
                    Button(role: .destructive) {
                        downloads.removeAll()
                    } label: {
                        Label("Remove All Downloads", systemImage: "trash")
                    }
                }
            }
            .listRowBackground(DromeTheme.elevated)

            if !active.isEmpty {
                Section("In progress") {
                    ForEach(active, id: \.songId) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: record)).font(DromeTheme.rowTitle)
                                Text(record.state.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
                            Spacer()
                            if let progress = downloads.progress[record.songId] {
                                ProgressView(value: progress)
                                    .frame(width: 60)
                            }
                            Button {
                                downloads.cancel(songId: record.songId)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(DromeTheme.muted)
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowBackground(DromeTheme.background)
                    }
                }
            }

            ForEach(albumSections, id: \.name) { section in
                Section {
                    Button {
                        player.play(
                            section.songs, startAt: 0,
                            context: PlaybackContext(label: section.name, kind: .mix))
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DromeTheme.accent)
                    .foregroundStyle(.white)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    ForEach(Array(section.songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(
                            song: song,
                            showAlbum: false,
                            trailing: AnyView(
                                Button(role: .destructive) {
                                    downloads.remove(songId: song.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            )
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(
                                section.songs, startAt: index,
                                context: PlaybackContext(label: section.name, kind: .mix))
                        }
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                } header: {
                    Text(section.name)
                }
            }

            if downloads.records.isEmpty {
                EmptyStateView(title: "No downloads yet",
                               systemImage: "arrow.down.circle",
                               message: "Download albums or playlists from their detail screens for offline listening.")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
        .navigationTitle("Downloads")
    }

    private func song(from record: DownloadRecord) -> Song? {
        try? JSONDecoder().decode(Song.self, from: Data(record.songJSON.utf8))
    }

    private func title(for record: DownloadRecord) -> String {
        song(from: record)?.title ?? record.songId
    }
}
