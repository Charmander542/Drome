import SwiftUI

/// Shared swipe actions for any song row in a List:
/// - Trailing (swipe left): Play Next + Queue
/// - Full swipe left commits Queue (first action)
///
/// Do not remount the row after a tap (e.g. via `.id`). That collapses the
/// swipe panel by destroying the cell and often shifts List hit-testing to the
/// row below — which can look like the wrong song was queued (and may even
/// trigger play on the neighbor, clearing the queue you just built).
struct SongSwipeModifier: ViewModifier {
    let song: Song

    @EnvironmentObject private var player: PlayerEngine

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                // First = full-swipe action (far left swipe → add to queue).
                Button {
                    player.addToQueue(song)
                } label: {
                    Label("Queue", systemImage: "text.append")
                }
                .tint(DromeTheme.elevated2)

                Button {
                    player.playNext(song)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(DromeTheme.accent)
            }
    }
}

extension View {
    func songSwipeActions(for song: Song) -> some View {
        modifier(SongSwipeModifier(song: song))
    }
}
