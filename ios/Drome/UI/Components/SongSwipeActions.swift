import SwiftUI

/// Shared swipe actions for any song row in a List:
/// - Trailing: Play Next (first in queue), Add to Queue (last)
struct SongSwipeModifier: ViewModifier {
    let song: Song

    @EnvironmentObject private var player: PlayerEngine
    /// Bumping this recreates the row so the swipe actions snap shut after a tap.
    @State private var swipeEpoch = 0

    func body(content: Content) -> some View {
        content
            .id(swipeEpoch)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    player.addToQueue(song)
                    collapseSwipe()
                } label: {
                    Label("Queue", systemImage: "text.append")
                }
                .tint(DromeTheme.elevated2)

                Button {
                    player.playNext(song)
                    collapseSwipe()
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(DromeTheme.accent)
            }
    }

    private func collapseSwipe() {
        var transaction = Transaction(animation: .easeOut(duration: 0.12))
        transaction.disablesAnimations = false
        withTransaction(transaction) {
            swipeEpoch += 1
        }
    }
}

extension View {
    func songSwipeActions(for song: Song) -> some View {
        modifier(SongSwipeModifier(song: song))
    }
}
