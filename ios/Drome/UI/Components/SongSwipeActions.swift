import SwiftUI

/// Shared swipe actions for any song row in a List:
/// - Trailing: Play Next (first in queue), Add to Queue (last)
struct SongSwipeModifier: ViewModifier {
    let song: Song

    @EnvironmentObject private var player: PlayerEngine

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
