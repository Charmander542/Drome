import SwiftUI
import UIKit

private enum NPFocus: Hashable {
    case cinema, picker, scrubber, prev, play, next
    case shuffle, repeatMode, autoplay, star(Int)
}

struct TVNowPlayingView: View {
    private enum Pane: String, CaseIterable {
        case song = "Song"
        case lyrics = "Lyrics"
        case queue = "Up Next"
    }

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var ratings: RatingsStore

    @Namespace private var playerFocus
    @FocusState private var focus: NPFocus?
    @State private var pane: Pane = .song
    @State private var cinemaMode = false
    @State private var cinemaReturnFocus: NPFocus = .play
    @State private var idleTick = 0
    @State private var isScrubbing = false
    @State private var armedQueueID: UUID?

    var body: some View {
        ZStack {
            TVTheme.canvas.ignoresSafeArea()
            if let song = player.current?.song {
                playerStage(song)
            } else {
                VStack(spacing: 14) {
                    Text("Nothing playing")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    Text("Choose a record from Home or Library.")
                        .font(.title2)
                        .foregroundStyle(TVTheme.dim)
                }
            }
        }
        .focusScope(playerFocus)
        .onPlayPauseCommand { player.playPause() }
        .onChange(of: focus) { _, new in
            if new == .cinema {
                cinemaMode = true
            } else if new != nil {
                idleTick += 1
            }
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing {
                idleTick += 1
            } else if cinemaMode {
                leaveCinema()
            }
        }
        .task(id: idleTick) {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            guard player.isPlaying, pane == .song, !isScrubbing, !cinemaMode else { return }
            enterCinema()
        }
        .onAppear {
            if focus == nil { focus = .picker }
        }
    }

    private func enterCinema(from source: NPFocus? = nil) {
        if let source {
            cinemaReturnFocus = source
        } else if let focus, focus != .cinema {
            cinemaReturnFocus = focus
        }
        cinemaMode = true
        focus = .cinema
    }

    private func leaveCinema() {
        let restore = cinemaReturnFocus
        cinemaMode = false
        Task { @MainActor in
            focus = restore
        }
    }

    private func playerStage(_ song: Song) -> some View {
        GeometryReader { geo in
            let cinemaSide = min(geo.size.width - 120, geo.size.height - 220)
            ZStack {
                HStack(alignment: .center, spacing: 48) {
                    cover(song, side: 460)
                        .shadow(color: .black.opacity(0.45), radius: 20, y: 16)
                    controlColumn(song)
                }
                .padding(.horizontal, TVTheme.gutter)
                .padding(.vertical, 28)
                .opacity(cinemaMode ? 0 : 1)
                .allowsHitTesting(!cinemaMode)

                if cinemaMode {
                    VStack(spacing: 24) {
                        Spacer(minLength: 0)
                        cover(song, side: cinemaSide)
                            .shadow(color: .black.opacity(0.45), radius: 36, y: 16)
                        VStack(spacing: 8) {
                            Text(song.title)
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(song.displayArtist)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(TVTheme.dim)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 80)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($focus, equals: .cinema)
                    .focusEffectDisabled()
                    .onMoveCommand { direction in
                        if direction == .right { leaveCinema() }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .transaction { $0.animation = nil }
        }
    }

    private func controlColumn(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            panePicker
                .focused($focus, equals: .picker)
                .prefersDefaultFocus(true, in: playerFocus)
            switch pane {
            case .song:
                songControls(song)
            case .lyrics:
                TVLyricsStage(song: song)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .queue:
                queuePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .focusSection()
    }

    private var panePicker: some View {
        Picker("Page", selection: $pane) {
            ForEach(Pane.allCases, id: \.self) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 720)
    }

    private func cover(_ song: Song, side: CGFloat) -> some View {
        RemoteImage(
            url: session.artworkURL(for: song, size: 900),
            placeholderSymbol: "music.note",
            holdImageWhileLoading: true)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func songControls(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let context = player.context?.label {
                Text(context.uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            Text(song.title)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            Text(song.displayArtist)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(TVTheme.dim)
                .lineLimit(1)

            TVScrubBar(isScrubbing: $isScrubbing, interactive: true, itemFocus: $focus)

            HStack(spacing: 18) {
                TVTransportIcon(system: "backward.fill", size: 28, hit: 72) {
                    player.previous()
                }
                .focused($focus, equals: .prev)
                .onMoveCommand { direction in
                    moveSongFocus(direction, from: .prev)
                }

                TVPlayButton(isPlaying: player.isPlaying) {
                    player.playPause()
                }
                .focused($focus, equals: .play)
                .onMoveCommand { direction in
                    moveSongFocus(direction, from: .play)
                }

                TVTransportIcon(system: "forward.fill", size: 28, hit: 72) {
                    player.next()
                }
                .focused($focus, equals: .next)
                .onMoveCommand { direction in
                    moveSongFocus(direction, from: .next)
                }
            }
            .padding(.top, 4)

            HStack(spacing: 14) {
                TVTransportIcon(
                    system: "shuffle",
                    size: 22,
                    hit: 64,
                    tint: player.shuffleMode == .off ? .white.opacity(0.7) : TVTheme.accent,
                    badge: player.shuffleMode == .smart ? "star.fill" : nil)
                {
                    player.cycleShuffleMode()
                }
                .focused($focus, equals: .shuffle)
                .onMoveCommand { direction in
                    moveSongFocus(direction, from: .shuffle)
                }

                TVTransportIcon(
                    system: player.repeatMode == .one ? "repeat.1" : "repeat",
                    size: 22,
                    hit: 64,
                    tint: player.repeatMode == .off ? .white.opacity(0.7) : TVTheme.accent)
                {
                    player.cycleRepeatMode()
                }
                .focused($focus, equals: .repeatMode)
                .onMoveCommand { direction in
                    moveSongFocus(direction, from: .repeatMode)
                }

                TVTransportIcon(
                    system: "infinity",
                    size: 22,
                    hit: 64,
                    tint: player.autoplayEnabled ? TVTheme.accent : .white.opacity(0.7))
                {
                    player.autoplayEnabled.toggle()
                }
                .focused($focus, equals: .autoplay)
                .onMoveCommand { direction in
                    moveSongFocus(direction, from: .autoplay)
                }
            }

            ratingRow(for: song)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .focusSection()
    }

    private func moveSongFocus(_ direction: MoveCommandDirection, from: NPFocus) {
        switch (from, direction) {
        case (.scrubber, .up): focus = .picker
        case (.scrubber, .down): focus = .play
        case (.prev, .left): enterCinema(from: .prev)
        case (.prev, .right): focus = .play
        case (.prev, .up): focus = .scrubber
        case (.prev, .down): focus = .shuffle
        case (.play, .left): focus = .prev
        case (.play, .right): focus = .next
        case (.play, .up): focus = .scrubber
        case (.play, .down): focus = .repeatMode
        case (.next, .left): focus = .play
        case (.next, .up): focus = .scrubber
        case (.next, .down): focus = .autoplay
        case (.shuffle, .left): enterCinema(from: .shuffle)
        case (.shuffle, .right): focus = .repeatMode
        case (.shuffle, .up): focus = .prev
        case (.shuffle, .down): focus = .star(1)
        case (.repeatMode, .left): focus = .shuffle
        case (.repeatMode, .right): focus = .autoplay
        case (.repeatMode, .up): focus = .play
        case (.repeatMode, .down): focus = .star(3)
        case (.autoplay, .left): focus = .repeatMode
        case (.autoplay, .up): focus = .next
        case (.autoplay, .down): focus = .star(5)
        case (.star(let n), .left) where n == 1: enterCinema(from: .star(1))
        case (.star(let n), .left) where n > 1: focus = .star(n - 1)
        case (.star(let n), .right) where n < 5: focus = .star(n + 1)
        case (.star, .up): focus = .shuffle
        default: break
        }
    }

    private func ratingRow(for song: Song) -> some View {
        let current = ratings.rating(for: song)
        return HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { star in
                TVTransportIcon(
                    system: star <= current ? "star.fill" : "star",
                    size: 20,
                    hit: 52,
                    tint: star <= current ? TVTheme.accent : .white.opacity(0.35))
                {
                    ratings.setRating(star == current ? 0 : star, for: song)
                }
                .focused($focus, equals: .star(star))
                .onMoveCommand { direction in
                    moveSongFocus(direction, from: .star(star))
                }
            }
        }
    }

    private var queuePane: some View {
        let upcoming = player.userQueue + player.contextQueue
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("Click to play  ·  Left, then click the trash to remove")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(TVTheme.dim)
                    .padding(.bottom, 4)
                if upcoming.isEmpty {
                    Text("Queue is empty")
                        .font(.title2)
                        .foregroundStyle(TVTheme.dim)
                        .padding(.top, 12)
                }
                ForEach(upcoming) { item in
                    TVQueueRow(item: item, armed: armedQueueID == item.id) {
                        if armedQueueID == item.id {
                            player.removeFromQueue(item)
                            armedQueueID = nil
                        } else {
                            player.jump(to: item)
                        }
                    } onArm: {
                        armedQueueID = item.id
                    } onDisarm: {
                        if armedQueueID == item.id { armedQueueID = nil }
                    }
                }
            }
            .padding(.trailing, 24)
        }
        .onChange(of: pane) { _, _ in
            armedQueueID = nil
        }
    }
}

private struct TVQueueRow: View {
    let item: QueueItem
    let armed: Bool
    let onSelect: () -> Void
    let onArm: () -> Void
    let onDisarm: () -> Void

    var body: some View {
        Button(action: onSelect) {
            TVQueueRowLabel(item: item, armed: armed)
        }
        .buttonStyle(TVQuietButtonStyle())
        .focusEffectDisabled()
        .onMoveCommand { direction in
            if direction == .left { onArm() }
            if direction == .right { onDisarm() }
        }
        .background {
            TVFocusLost(onLost: onDisarm)
        }
    }
}

private struct TVQueueRowLabel: View {
    let item: QueueItem
    let armed: Bool
    @EnvironmentObject private var session: AppSession
    @Environment(\.isFocused) private var focused

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 22) {
                RemoteImage(
                    url: session.artworkURL(for: item.song, size: 120),
                    placeholderSymbol: "music.note")
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.song.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.song.displayArtist)
                        .foregroundStyle(Color.white.opacity(focused ? 0.78 : 0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(item.song.durationText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.trailing, armed ? 8 : 16)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.red)
                Image(systemName: "trash.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: armed ? 88 : 0, height: 80)
            .opacity(armed ? 1 : 0)
            .clipped()
            .padding(.trailing, armed ? 12 : 0)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(focused ? Color.white.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(focused ? Color.white.opacity(0.9) : Color.clear, lineWidth: 3)
        )
        .animation(.easeOut(duration: 0.18), value: armed)
    }
}

private struct TVFocusLost: View {
    let onLost: () -> Void
    @Environment(\.isFocused) private var focused

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: focused) { _, on in
                if !on { onLost() }
            }
    }
}

private struct TVPlayButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVPlayGlyph(isPlaying: isPlaying)
        }
        .buttonStyle(TVQuietButtonStyle())
    }
}

private struct TVPlayGlyph: View {
    let isPlaying: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        ZStack {
            Circle()
                .fill(focused ? Color.white : Color.white.opacity(0.12))
                .frame(width: 88, height: 88)
            Circle()
                .stroke(Color.white, lineWidth: focused ? 0 : 3)
                .frame(width: 88, height: 88)
            if focused {
                Circle()
                    .stroke(TVTheme.accent, lineWidth: 5)
                    .frame(width: 104, height: 104)
            }
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(focused ? Color.black : Color.white)
                .offset(x: isPlaying ? 0 : 2)
        }
        .frame(width: 112, height: 112)
    }
}

private struct TVTransportIcon: View {
    let system: String
    var size: CGFloat = 24
    var hit: CGFloat = 64
    var tint: Color = .white
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVTransportGlyph(system: system, size: size, hit: hit, tint: tint, badge: badge)
        }
        .buttonStyle(TVQuietButtonStyle())
        .focusEffectDisabled()
    }
}

private struct TVTransportGlyph: View {
    let system: String
    var size: CGFloat
    var hit: CGFloat
    var tint: Color
    var badge: String?
    @Environment(\.isFocused) private var focused

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(focused ? 0.16 : 0))
                .frame(width: hit - 4, height: hit - 4)
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
            if let badge {
                Image(systemName: badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TVTheme.accent)
                    .offset(x: 12, y: -12)
            }
        }
        .frame(width: hit, height: hit)
    }
}

/// Focus highlights the knob. Left/right skip 10s. Click, then swipe for fine scrubbing.
private struct TVScrubBar: View {
    @EnvironmentObject private var player: PlayerEngine
    @Binding var isScrubbing: Bool
    var interactive: Bool
    var itemFocus: FocusState<NPFocus?>.Binding

    @State private var fineScrub = false
    @State private var preview: TimeInterval?
    @State private var dragOrigin: TimeInterval?

    var body: some View {
        Group {
            if interactive {
                Button {
                    toggleFineScrub()
                } label: {
                    bar
                }
                .buttonStyle(.plain)
                .focused(itemFocus, equals: .scrubber)
                .onMoveCommand { direction in
                    let current = preview ?? player.accurateElapsed()
                    let step: TimeInterval = fineScrub ? 1 : 10
                    if direction == .left {
                        applySeek(max(0, current - step), throttle: false)
                    } else if direction == .right {
                        applySeek(min(duration, current + step), throttle: false)
                    } else if direction == .up {
                        itemFocus.wrappedValue = .picker
                    } else if direction == .down {
                        itemFocus.wrappedValue = .play
                    }
                }
                .modifier(TVScrubExitFine(enabled: fineScrub, exit: endFineScrub))
            } else {
                bar
            }
        }
        .frame(maxWidth: 560)
        .onChange(of: itemFocus.wrappedValue) { _, new in
            let on = new == .scrubber
            if !on { endFineScrub() }
            isScrubbing = on || fineScrub
        }
    }

    private var focused: Bool { itemFocus.wrappedValue == .scrubber }

    private var bar: some View {
        TimelineView(.periodic(from: .now, by: fineScrub ? 0.05 : 0.25)) { _ in
            let total = duration
            let elapsed = preview ?? player.accurateElapsed()
            let fraction = min(max(elapsed / max(total, 0.1), 0), 1)
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    let knob: CGFloat = fineScrub ? 28 : (focused && interactive ? 22 : 14)
                    let track: CGFloat = focused && interactive ? 8 : 5
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .frame(height: track)
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(knob / 2, geo.size.width * fraction), height: track)
                        Circle()
                            .fill(Color.white)
                            .frame(width: knob, height: knob)
                            .overlay {
                                Circle()
                                    .stroke(
                                        fineScrub ? TVTheme.accent : Color.white.opacity(focused ? 0.95 : 0.35),
                                        lineWidth: fineScrub ? 4 : (focused ? 2 : 1))
                            }
                            .shadow(color: .black.opacity(focused ? 0.45 : 0.15), radius: focused ? 8 : 2)
                            .offset(x: max(0, min(geo.size.width - knob, geo.size.width * fraction - knob / 2)))
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .overlay {
                        if fineScrub {
                            TVTouchPadPan(
                                onTranslation: { dx in
                                    if dragOrigin == nil {
                                        dragOrigin = preview ?? player.accurateElapsed()
                                    }
                                    let delta = (dx / max(geo.size.width, 1)) * total
                                    applySeek(min(max(0, (dragOrigin ?? 0) + delta), total), throttle: true)
                                },
                                onEnd: {
                                    dragOrigin = nil
                                    if let preview {
                                        applySeek(preview, throttle: false)
                                    }
                                })
                        }
                    }
                }
                .frame(height: 36)
                HStack {
                    Text(Formatters.playbackTime(elapsed))
                    Spacer()
                    if interactive, focused {
                        Text(fineScrub ? "Swipe to scrub  ·  click to exit" : "Click to scrub")
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    Spacer()
                    Text(Formatters.playbackTime(total))
                }
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.65))
            }
        }
    }

    private func toggleFineScrub() {
        if fineScrub {
            endFineScrub()
        } else {
            fineScrub = true
            preview = player.accurateElapsed()
            isScrubbing = true
        }
    }

    private func endFineScrub() {
        fineScrub = false
        dragOrigin = nil
        if let preview {
            player.seek(to: preview)
        }
        if !focused { self.preview = nil }
        isScrubbing = focused
    }

    private var duration: TimeInterval {
        let live = player.duration
        if live.isFinite, live > 0.5 { return live }
        if let meta = player.current?.song.duration, meta > 0 { return TimeInterval(meta) }
        return max(live, 1)
    }

    private func applySeek(_ time: TimeInterval, throttle: Bool) {
        let clamped = min(max(0, time), duration)
        preview = clamped
        isScrubbing = true
        // Live seeks while the touchpad is moving tear Apple TV's decoder.
        // Move the knob only; commit once on release (or on L/R skip).
        if throttle { return }
        player.seek(to: clamped)
    }
}

private struct TVScrubExitFine: ViewModifier {
    let enabled: Bool
    let exit: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onExitCommand(perform: exit)
        } else {
            content
        }
    }
}

/// Siri Remote touchpad pan — DragGesture is not available on tvOS.
private struct TVTouchPadPan: UIViewRepresentable {
    var onTranslation: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTranslation: onTranslation, onEnd: onEnd)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTranslation = onTranslation
        context.coordinator.onEnd = onEnd
    }

    final class Coordinator: NSObject {
        var onTranslation: (CGFloat) -> Void
        var onEnd: () -> Void

        init(onTranslation: @escaping (CGFloat) -> Void, onEnd: @escaping () -> Void) {
            self.onTranslation = onTranslation
            self.onEnd = onEnd
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                onTranslation(gesture.translation(in: gesture.view).x)
            case .ended, .cancelled, .failed:
                onEnd()
            default:
                break
            }
        }
    }
}

/// Karaoke stays put: previous / current / next. Highlight follows `accurateElapsed()`.
struct TVLyricsStage: View {
    let song: Song

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var document: LyricsDocument?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let elapsedMs = Int(player.accurateElapsed() * 1000)
            stage(elapsedMs: elapsedMs)
        }
        .task(id: song.id) {
            document = await session.lyricsService.lyrics(for: song)
        }
    }

    @ViewBuilder
    private func stage(elapsedMs: Int) -> some View {
        if let document, !document.lines.isEmpty {
            let active = activeIndex(elapsedMs: elapsedMs, in: document)
            VStack(spacing: 22) {
                lineText(document, index: active - 1, elapsedMs: elapsedMs, role: .neighbor)
                lineText(document, index: active, elapsedMs: elapsedMs, role: .current)
                lineText(document, index: active + 1, elapsedMs: elapsedMs, role: .neighbor)
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Text("No lyrics yet")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("Checked your library and LRCLIB.")
                    .font(.title2)
                    .foregroundStyle(TVTheme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private enum Role { case current, neighbor }

    @ViewBuilder
    private func lineText(_ document: LyricsDocument, index: Int, elapsedMs: Int, role: Role) -> some View {
        if document.lines.indices.contains(index) {
            let line = document.lines[index]
            Group {
                if role == .current, document.synced, !line.words.isEmpty {
                    WrappingWords(words: line.words, elapsedMs: elapsedMs)
                } else {
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(
                            size: role == .current ? 54 : 30,
                            weight: role == .current ? .bold : .semibold,
                            design: .rounded))
                        .foregroundStyle(Color.white.opacity(role == .current ? 1 : 0.28))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            Text(" ")
                .font(.system(size: role == .current ? 54 : 30, weight: .bold, design: .rounded))
        }
    }

    private func activeIndex(elapsedMs: Int, in document: LyricsDocument) -> Int {
        let timed = document.lines.contains { $0.startMs != nil }
        if timed {
            var idx = 0
            for (i, line) in document.lines.enumerated() {
                guard let start = line.startMs else { continue }
                if start <= elapsedMs { idx = i } else { break }
            }
            return idx
        }
        let durationMs = Int(max(player.duration, TimeInterval(song.duration ?? 0)) * 1000)
        guard durationMs > 0, document.lines.count > 1 else { return 0 }
        let fraction = min(max(Double(elapsedMs) / Double(durationMs), 0), 0.999)
        return Int(fraction * Double(document.lines.count))
    }
}

private struct WrappingWords: View {
    let words: [LRCParser.Word]
    let elapsedMs: Int

    var body: some View {
        FlexibleWordRow(spacing: 14, lineSpacing: 10) {
            ForEach(words) { word in
                Text(word.text)
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundStyle(color(for: word))
            }
        }
        .frame(maxWidth: 1000)
        .multilineTextAlignment(.center)
    }

    private func color(for word: LRCParser.Word) -> Color {
        if elapsedMs < word.startMs { return Color.white.opacity(0.28) }
        if let end = word.endMs, elapsedMs >= end { return Color.white.opacity(0.72) }
        return .white
    }
}

private struct FlexibleWordRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 1000
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
