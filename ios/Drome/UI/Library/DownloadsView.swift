import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Storage used")
                    Spacer()
                    Text(Formatters.fileSize(downloads.totalBytesUsed))
                        .foregroundStyle(DromeTheme.muted)
                }
                if !downloads.records.filter({ $0.state == "done" }).isEmpty {
                    Button(role: .destructive) {
                        downloads.removeAll()
                    } label: {
                        Label("Remove All Downloads", systemImage: "trash")
                    }
                }
            }
            .listRowBackground(DromeTheme.elevated)

            let active = downloads.records.filter { $0.state == "downloading" || $0.state == "queued" || $0.state == "failed" }
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

            let done = Dictionary(grouping: downloads.records.filter { $0.state == "done" },
                                  by: { $0.albumName.isEmpty ? "Tracks" : $0.albumName })
            ForEach(done.keys.sorted(), id: \.self) { album in
                Section(album) {
                    ForEach(done[album] ?? [], id: \.songId) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: record)).font(DromeTheme.rowTitle)
                                Text(Formatters.fileSize(record.fileSize))
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                downloads.remove(songId: record.songId)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowBackground(DromeTheme.background)
                    }
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

    private func title(for record: DownloadRecord) -> String {
        if let song = try? JSONDecoder().decode(Song.self, from: Data(record.songJSON.utf8)) {
            return song.title
        }
        return record.songId
    }
}
