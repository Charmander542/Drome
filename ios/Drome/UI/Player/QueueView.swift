import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

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
                        .onMove(perform: player.moveUserQueueItems)
                        .onDelete { offsets in
                            removeUserItems(at: offsets)
                        }
                    }
                }

                if !player.contextQueue.isEmpty {
                    Section {
                        ForEach(player.contextQueue) { item in
                            queueRow(item, showsAutoplay: true)
                        }
                        .onMove(perform: player.moveContextQueueItems)
                        .onDelete { offsets in
                            removeContextItems(at: offsets)
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
            .environment(\.editMode, .constant(.active))
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
        }
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
        // Explicit delete — List edit-mode minus + SongRow swipeActions conflicted,
        // so the red control never actually removed items.
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

    private func removeUserItems(at offsets: IndexSet) {
        let items = offsets.compactMap { player.userQueue.indices.contains($0) ? player.userQueue[$0] : nil }
        for item in items {
            player.removeFromQueue(item)
        }
    }

    private func removeContextItems(at offsets: IndexSet) {
        let items = offsets.compactMap { player.contextQueue.indices.contains($0) ? player.contextQueue[$0] : nil }
        for item in items {
            player.removeFromQueue(item)
        }
    }
}
