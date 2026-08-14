import SwiftUI
import UIKit

struct QueueView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var songNavigator = SongNavigator()
    @State private var drag: HandleDrag?

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
                        ForEach(Array(player.userQueue.enumerated()), id: \.element.id) { index, item in
                            queueRow(item, index: index, inUserQueue: true)
                        }
                    }
                }

                if !player.contextQueue.isEmpty {
                    Section {
                        ForEach(Array(player.contextQueue.enumerated()), id: \.element.id) { index, item in
                            queueRow(item, index: index, inUserQueue: false, showsAutoplay: true)
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
            .scrollDisabled(drag != nil)
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
    private func queueRow(_ item: QueueItem, index: Int, inUserQueue: Bool,
                          showsAutoplay: Bool = false) -> some View {
        HStack(spacing: 4) {
            Button {
                player.jump(to: item)
            } label: {
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
            .buttonStyle(.plain)

            ZStack {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DromeTheme.muted)
                QueueDragHandle(
                    onBegan: {
                        drag = HandleDrag(id: item.id, origin: index, inUserQueue: inUserQueue)
                    },
                    onChanged: { translationY in
                        guard let drag, drag.id == item.id else { return }
                        let count = drag.inUserQueue ? player.userQueue.count : player.contextQueue.count
                        guard count > 0 else { return }
                        let target = min(max(0, drag.origin + Int((translationY / 64).rounded())), count - 1)
                        player.moveQueueItem(id: drag.id, toIndex: target, inUserQueue: drag.inUserQueue)
                    },
                    onEnded: {
                        drag = nil
                    }
                )
            }
            .frame(width: 44, height: 48)
            .contentShape(Rectangle())
            .accessibilityLabel("Reorder")
        }
        .opacity(drag?.id == item.id ? 0.72 : 1)
        .listRowBackground(DromeTheme.background)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 4))
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

private struct HandleDrag {
    var id: UUID
    var origin: Int
    var inUserQueue: Bool
}

/// Vertical-only pan that beats the list scroll view, so the grip reorders
/// instead of scrolling. Horizontal pans fail immediately so swipe-to-delete
/// still works.
private struct QueueDragHandle: UIViewRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = AttachView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = true
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        context.coordinator.pan = pan
        view.onAttached = { [weak pan] host in
            guard let pan else { return }
            var node: UIView? = host.superview
            while let current = node {
                if let scroll = current as? UIScrollView {
                    scroll.panGestureRecognizer.require(toFail: pan)
                    break
                }
                node = current.superview
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: () -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: () -> Void
        weak var pan: UIPanGestureRecognizer?

        init(onBegan: @escaping () -> Void,
             onChanged: @escaping (CGFloat) -> Void,
             onEnded: @escaping () -> Void) {
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                onBegan()
            case .changed:
                onChanged(gesture.translation(in: gesture.view).y)
            default:
                onEnded()
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) > abs(velocity.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
    }
}

private final class AttachView: UIView {
    var onAttached: ((UIView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onAttached?(self)
        }
    }
}
