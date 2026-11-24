import SwiftUI
import UIKit

private enum NPFocus: Hashable {
    /// Whole-screen focus while ambient idle — any press brings controls back.
    case surface
    case scrubber, prev, play, next
    case shuffle, repeatMode, autoplay, queue, lyricsToggle, star(Int)
}

/// Now Playing — Aura-inspired: blurred cover across the room, controls + lyrics
/// side by side, ambient idle after a few seconds of no remote input.
struct TVNowPlayingView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var ratings: RatingsStore
    @EnvironmentObject private var chrome: TVChromeState

    @Namespace private var playerFocus
    @FocusState private var focus: NPFocus?
    @State private var idle = false
    @State private var lastInput = Date()
    @State private var showLyrics = true
    @State private var showQueue = false
    @State private var isScrubbing = false
    @State private var armedQueueID: UUID?
    @State private var showConnect = false
    @State private var hasLyricsDocument = false

    private static let idleDelay: TimeInterval = 5
    private static let queueWidth: CGFloat = 720

    var body: some View {
        ZStack {
            if let song = player.current?.song {
                playerStage(song)
            } else {
                TVTheme.canvas.ignoresSafeArea()
                VStack(spacing: 14) {
                    Text("Nothing playing")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    Text("Choose something from Home or Library.")
                        .font(.title2)
                        .foregroundStyle(TVTheme.dim)
                }
            }
        }
        .focusScope(playerFocus)
        .onPlayPauseCommand {
            poke()
            player.playPause()
        }
        .sheet(isPresented: $showConnect) {
            if let connect = session.connect {
                ConnectDevicePicker(connect: connect)
            }
        }
        .onChange(of: focus) { _, new in
            if new != nil, new != .surface { poke() }
            syncTabBarChrome()
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing {
                poke()
            } else if idle {
                poke()
            }
        }
        .onChange(of: showQueue) { _, open in
            if !open {
                poke()
                focus = .queue
            }
            syncTabBarChrome()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !idle, !showQueue, !isScrubbing,
                   player.isPlaying,
                   Date().timeIntervalSince(lastInput) > Self.idleDelay {
                    idle = true
                    focus = .surface
                    syncTabBarChrome()
                }
            }
        }
        .onAppear {
            if focus == nil { focus = .play }
            syncTabBarChrome()
        }
        .onDisappear {
            chrome.hidesTabBar = false
        }
        .onChange(of: player.current?.id) { _, _ in
            hasLyricsDocument = false
            syncTabBarChrome()
        }
        .task(id: player.current?.song.id) {
            guard let song = player.current?.song else {
                hasLyricsDocument = false
                return
            }
            let doc = await session.lyricsService.lyrics(for: song)
            hasLyricsDocument = !(doc?.lines.isEmpty ?? true)
        }
        .animation(.easeInOut(duration: 0.55), value: idle)
        .animation(.easeInOut(duration: 0.35), value: showQueue)
        .animation(.easeInOut(duration: 0.35), value: showLyrics)
    }

    private func syncTabBarChrome() {
        chrome.hidesTabBar = (idle || showQueue) && player.current != nil
    }

    private func poke() {
        lastInput = Date()
        guard idle else { return }
        idle = false
        focus = .play
        syncTabBarChrome()
    }

    private var lyricsVisible: Bool {
        showLyrics && hasLyricsDocument && !showQueue
    }

    private func playerStage(_ song: Song) -> some View {
        ZStack {
            TVArtworkBackdrop(url: session.artworkURL(for: song, size: 600))

            HStack(alignment: .center, spacing: 100) {
                controls(song)
                if lyricsVisible {
                    TVLyricsStage(song: song)
                        .frame(width: 820, height: 640)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, showQueue ? Self.queueWidth : 0)
            .disabled(showQueue)

            if showQueue {
                TVUpNextPanel(
                    armedQueueID: $armedQueueID,
                    onClose: { showQueue = false })
                    .frame(width: Self.queueWidth)
                    .frame(maxHeight: .infinity)
                    .background(.black.opacity(0.55))
                    .background(.ultraThinMaterial)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing))
                    .focusSection()
                    .onExitCommand { showQueue = false }
            }
        }
        .focusable(idle)
        .focused($focus, equals: .surface)
        .focusEffectDisabled()
        .onTapGesture { poke() }
        .onMoveCommand { _ in poke() }
    }

    private func controls(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            cover(song, side: 520)
                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                .id(song.id)

            VStack(alignment: .leading, spacing: 6) {
                Text(song.title)
                    .font(.system(size: 40, weight: .bold))
                    .lineLimit(2)
                Text(song.displayArtist)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(width: 520, alignment: .leading)

            if !idle {
                TVScrubBar(isScrubbing: $isScrubbing, interactive: true, itemFocus: $focus)
                    .frame(width: 520)
                    .transition(.opacity)

                HStack(spacing: 8) {
                    transport("quote.bubble", .lyricsToggle, on: showLyrics && hasLyricsDocument) {
                        showLyrics.toggle()
                    }
                    transport("shuffle", .shuffle, on: player.shuffleMode != .off) {
                        player.cycleShuffleMode()
                    }
                    transport("backward.fill", .prev) { player.previous() }
                    playPauseButton
                    transport("forward.fill", .next) { player.next() }
                    transport(
                        player.repeatMode == .one ? "repeat.1" : "repeat",
                        .repeatMode,
                        on: player.repeatMode != .off)
                    {
                        player.cycleRepeatMode()
                    }
                    transport("list.bullet", .queue) { showQueue = true }
                }
                .transition(.opacity)

                HStack(spacing: 14) {
                    TVModeControl(
                        system: "infinity",
                        label: AutoplayMode.label,
                        active: player.autoplayEnabled)
                    {
                        poke()
                        player.autoplayEnabled.toggle()
                    }
                    .focused($focus, equals: .autoplay)

                    if session.connect != nil {
                        TVTransportIcon(
                            system: session.connect?.isRemote == true
                                ? "speaker.wave.2.fill" : "hifispeaker",
                            size: 22,
                            hit: 64,
                            tint: session.connect?.isRemote == true
                                ? TVTheme.accent : .white.opacity(0.7))
                        {
                            poke()
                            showConnect = true
                        }
                    }

                    ratingRow(for: song)
                }
                .transition(.opacity)
            }
        }
        .focusSection()
        .prefersDefaultFocus(!idle, in: playerFocus)
    }

    private func cover(_ song: Song, side: CGFloat) -> some View {
        RemoteImage(
            url: session.artworkURL(for: song, size: 900),
            placeholderSymbol: "music.note",
            holdImageWhileLoading: true)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var playPauseButton: some View {
        Button {
            poke()
            player.playPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 34, weight: .semibold))
                .frame(width: 80, height: 80)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(TVAmbientButtonStyle())
        .focused($focus, equals: .play)
        .prefersDefaultFocus(true, in: playerFocus)
    }

    private func transport(
        _ system: String,
        _ item: NPFocus,
        on: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            poke()
            action()
        } label: {
            Image(systemName: system)
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 60, height: 60)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(TVAmbientButtonStyle(dimmed: on == false))
        .focused($focus, equals: item)
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
                    poke()
                    ratings.setRating(star == current ? 0 : star, for: song)
                }
                .focused($focus, equals: .star(star))
            }
        }
    }
}

/// Blurred cover filling the TV — Aura-style room ambience behind the player.
private struct TVArtworkBackdrop: View {
    let url: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TVTheme.canvas
                RemoteImage(
                    url: url,
                    placeholderSymbol: "music.note",
                    holdImageWhileLoading: true)
                    .scaledToFill()
                    .frame(width: geo.size.width * 1.35, height: geo.size.height * 1.35)
                    .blur(radius: 90)
                    .saturation(1.25)
                    .id(url?.absoluteString)
                Color.black.opacity(0.48)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

/// Bare glyph transport — circle only under focus so the cover and lyrics read first.
private struct TVAmbientButtonStyle: ButtonStyle {
    var dimmed = false
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(focused ? 1 : dimmed ? 0.3 : 0.65))
            .background(Circle().fill(.white.opacity(focused ? 0.18 : 0)))
            .scaleEffect(configuration.isPressed ? 0.94 : focused ? 1.1 : 1)
            .animation(.easeOut(duration: 0.2), value: focused)
    }
}

/// Up Next slides in from the right over the lyrics.
private struct TVUpNextPanel: View {
    @Binding var armedQueueID: UUID?
    let onClose: () -> Void

    @EnvironmentObject private var player: PlayerEngine

    private var upcoming: [QueueItem] {
        player.userQueue + player.contextQueue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Text("Up Next")
                    .font(.system(size: 44, weight: .bold))
                Spacer()
                Button("Close", action: onClose)
            }
            Text("Click to play  ·  Left, then click trash to remove")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(TVTheme.dim)

            if upcoming.isEmpty {
                Text("Nothing queued")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(upcoming) { item in
                            TVQueueRow(item: item, armed: armedQueueID == item.id) {
                                if armedQueueID == item.id {
                                    player.removeFromQueue(item)
                                    armedQueueID = nil
                                } else {
                                    player.jump(to: item)
                                    onClose()
                                }
                            } onArm: {
                                armedQueueID = item.id
                            } onDisarm: {
                                if armedQueueID == item.id { armedQueueID = nil }
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 56)
        .onDisappear { armedQueueID = nil }
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

private struct TVModeControl: View {
    let system: String
    let label: String
    var active: Bool = false
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                TVTransportGlyph(
                    system: system,
                    size: 22,
                    hit: 64,
                    tint: active ? TVTheme.accent : .white.opacity(0.7),
                    badge: badge)
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? TVTheme.accent : TVTheme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 92)
            }
        }
        .buttonStyle(TVQuietButtonStyle())
        .focusEffectDisabled()
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
                    Text("-\(Formatters.playbackTime(max(0, total - elapsed)))")
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
        let meta = TimeInterval(player.current?.song.duration ?? 0)
        let resolved = PlaybackResilience.reconciledDuration(
            metadata: meta,
            reported: player.duration,
            elapsed: player.accurateElapsed(),
            current: player.duration)
        return resolved > 0.5 ? resolved : max(player.duration, 1)
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

/// Karaoke beside the cover: sung line large and white, neighbors dim — scrolls with the song.
struct TVLyricsStage: View {
    let song: Song

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var document: LyricsDocument?
    @State private var currentIndex: Int?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let elapsedMs = Int(player.accurateElapsed() * 1000)
            stage(elapsedMs: elapsedMs)
        }
        .task(id: song.id) {
            currentIndex = nil
            document = await session.lyricsService.lyrics(for: song)
        }
    }

    @ViewBuilder
    private func stage(elapsedMs: Int) -> some View {
        if let document, !document.lines.isEmpty {
            let active = activeIndex(elapsedMs: elapsedMs, in: document)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        Spacer().frame(height: 160)
                        ForEach(Array(document.lines.enumerated()), id: \.offset) { index, line in
                            lineText(document, index: index, line: line, elapsedMs: elapsedMs, focus: active)
                                .id(index)
                        }
                        Spacer().frame(height: 200)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDisabled(true)
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                            .frame(height: 100)
                        Color.white
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 100)
                    }
                )
                .onChange(of: active) { _, new in
                    currentIndex = new
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.92)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func lineText(
        _ document: LyricsDocument,
        index: Int,
        line: LRCParser.Line,
        elapsedMs: Int,
        focus: Int
    ) -> some View {
        let distance = abs(index - focus)
        let isCurrent = distance == 0
        Group {
            if isCurrent, document.synced, !line.words.isEmpty {
                WrappingWords(words: line.words, elapsedMs: elapsedMs, leading: true)
            } else {
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(
                        size: isCurrent ? 56 : 32,
                        weight: isCurrent ? .bold : .semibold))
                    .foregroundStyle(.white.opacity(
                        isCurrent ? 1 : distance == 1 ? 0.32 : distance == 2 ? 0.12 : 0))
                    .scaleEffect(isCurrent ? 1 : 0.72, anchor: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.45, dampingFraction: 0.92), value: distance)
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
    var leading: Bool = false

    var body: some View {
        FlexibleWordRow(spacing: 14, lineSpacing: 10) {
            ForEach(words) { word in
                Text(word.text)
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(color(for: word))
            }
        }
        .frame(maxWidth: leading ? .infinity : 1000, alignment: leading ? .leading : .center)
        .multilineTextAlignment(leading ? .leading : .center)
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
