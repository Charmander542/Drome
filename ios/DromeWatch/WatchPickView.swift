import SwiftUI

struct WatchPickView: View {
    @EnvironmentObject private var store: WatchSessionStore

    var body: some View {
        List {
            if !store.payload.recents.isEmpty {
                Section("Recent") {
                    ForEach(store.payload.recents.prefix(6)) { item in
                        Button {
                            playRecent(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .lineLimit(1)
                                Text(item.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            if !store.payload.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(store.payload.playlists) { playlist in
                        Button {
                            store.send(.playPlaylist, extras: [
                                WatchBridgeKey.playlistId: playlist.id,
                            ])
                        } label: {
                            HStack {
                                Text(playlist.name)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(playlist.songCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if store.payload.recents.isEmpty && store.payload.playlists.isEmpty {
                Text("Open Drome on iPhone to load playlists")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Play")
    }

    private func playRecent(_ item: WatchRecentItem) {
        store.send(.playContext, extras: {
            var extras: [String: Any] = [
                WatchBridgeKey.resumeKey: item.resumeKey,
                WatchBridgeKey.entryId: item.id,
            ]
            if item.id.hasPrefix("song:") {
                extras[WatchBridgeKey.songId] = String(item.id.dropFirst(5))
            }
            return extras
        }())
    }
}
