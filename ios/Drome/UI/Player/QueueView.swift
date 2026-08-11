import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var songNavigator = SongNavigator()

    var body: some View {
        NavigationStack {
            List {
                if let current = player.current {
                    Section("Now playing") {
                        SongRow(song: current.song, showAlbum: true, enablesSwipeActions: false)
                            .listRowBackground(DromeTheme.elevated)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }

                if !player.userQueue.isEmpty {
                    Section("Next in queue") {
                        ForEach(player.userQueue) { item in
                            queueRow(item)
                        }
                    }
                }

                if !player.contextQueue.isEmpty {
                    Section {
                        ForEach(player.contextQueue) { item in
                            queueRow(item, showsAutoplay: true)
                        }
                    } header: {
                        Text(contextHeader)
                    }
                }

                if player.userQueue.isEmpty && player.contextQueue.isEmpty {
                    EmptyStateView(title: "Queue is empty",
                                   message: "Add songs with Play Next or Add to Queue.")
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DromeTheme.background)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { player.clearQueue() }
                        .disabled(player.userQueue.isEmpty && player.contextQueue.isEmpty)
                }
            }
            .navigationDestination(item: Binding(
                get: { songNavigator.albumRoute },
                set: { songNavigator.albumRoute = $0 }
            )) { route in
                AlbumDetailView(albumID: route.albumId, placeholder: route.album)
            }
            .navigationDestination(item: Binding(
                get: { songNavigator.artistRoute },
                set: { songNavigator.artistRoute = $0 }
            )) { route in
                ArtistDetailView(artistID: route.artistId, placeholderName: route.name)
            }
        }
        .environmentObject(songNavigator)
        .environment(\.songNavigator, songNavigator)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func queueRow(_ item: QueueItem, showsAutoplay: Bool = false) -> some View {
        HStack(spacing: 0) {
            SongRow(
                song: item.song,
                showAlbum: true,
                trailing: showsAutoplay && item.isAutoplay
                    ? AnyView(Image(systemName: "infinity")
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted))
                    : nil,
                enablesSwipeActions: false
            )
        }
        .contentShape(Rectangle())
        .onTapGesture { player.jump(to: item) }
        .listRowBackground(DromeTheme.background)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                player.removeFromQueue(item)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var contextHeader: String {
        if let label = player.context?.label {
            return "Next from: \(label)"
        }
        return "Next"
    }
}
