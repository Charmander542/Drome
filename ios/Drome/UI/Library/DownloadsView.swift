import SwiftUI

private enum DownloadsGroupMode: String, CaseIterable, Identifiable {
    case album = "Album"
    case artist = "Artist"
    case playlist = "Playlist"

    var id: String { rawValue }
}

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: PlayerEngine

    @State private var groupMode: DownloadsGroupMode = .album

    private var active: [DownloadRecord] {
        downloads.records.filter {
            $0.state == "downloading" || $0.state == "queued" || $0.state == "failed"
        }
    }

    private var doneRecords: [DownloadRecord] {
        downloads.records.filter { $0.state == "done" }
    }

    private var sections: [(id: String, name: String, songs: [Song])] {
        switch groupMode {
        case .album:
            return groupByAlbum()
        case .artist:
            return groupByArtist()
        case .playlist:
            return groupByPlaylist()
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Group by", selection: $groupMode) {
                    ForEach(DownloadsGroupMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                HStack {
                    Text("Storage used")
                    Spacer()
                    Text(Formatters.fileSize(downloads.totalBytesUsed))
                        .foregroundStyle(DromeTheme.muted)
                }
                if !doneRecords.isEmpty {
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

            ForEach(sections, id: \.id) { section in
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
                            showAlbum: groupMode != .album,
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

    // MARK: - Grouping

    private func groupByAlbum() -> [(id: String, name: String, songs: [Song])] {
        let grouped = Dictionary(grouping: doneRecords) {
            $0.albumName.isEmpty ? "Tracks" : $0.albumName
        }
        return grouped.keys.sorted().compactMap { name in
            let songs = (grouped[name] ?? []).compactMap(song(from:))
            guard !songs.isEmpty else { return nil }
            return (id: "album:\(name)", name: name, songs: songs)
        }
    }

    private func groupByArtist() -> [(id: String, name: String, songs: [Song])] {
        let grouped = Dictionary(grouping: doneRecords) {
            $0.artist.isEmpty ? "Unknown Artist" : $0.artist
        }
        return grouped.keys.sorted().compactMap { name in
            let songs = (grouped[name] ?? []).compactMap(song(from:))
            guard !songs.isEmpty else { return nil }
            return (id: "artist:\(name)", name: name, songs: songs)
        }
    }

    private func groupByPlaylist() -> [(id: String, name: String, songs: [Song])] {
        let doneById = Dictionary(uniqueKeysWithValues: doneRecords.map { ($0.songId, $0) })
        let memberships = downloads.playlistMemberships
        let byPlaylist = Dictionary(grouping: memberships) { $0.playlistId }

        var sections: [(id: String, name: String, songs: [Song])] = byPlaylist.keys.compactMap { playlistId in
            let rows = byPlaylist[playlistId] ?? []
            let name = rows.first?.playlistName.isEmpty == false
                ? (rows.first?.playlistName ?? "Playlist")
                : "Playlist"
            let songs = rows.compactMap { membership -> Song? in
                guard let record = doneById[membership.songId] else { return nil }
                return song(from: record)
            }
            guard !songs.isEmpty else { return nil }
            return (id: "playlist:\(playlistId)", name: name, songs: songs)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let memberSongIDs = Set(memberships.map(\.songId))
        let ungrouped = doneRecords
            .filter { !memberSongIDs.contains($0.songId) }
            .compactMap(song(from:))
        if !ungrouped.isEmpty {
            sections.append((id: "playlist:__none__", name: "Not in a playlist", songs: ungrouped))
        }
        return sections
    }

    private func song(from record: DownloadRecord) -> Song? {
        try? JSONDecoder().decode(Song.self, from: Data(record.songJSON.utf8))
    }

    private func title(for record: DownloadRecord) -> String {
        song(from: record)?.title ?? record.songId
    }
}
