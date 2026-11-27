import SwiftUI

/// Synced lyrics with duet left/right alignment.
/// Layout stays fixed (same font size for every line) so highlighting and
/// auto-scroll never shove neighboring lines around.
struct LyricsView: View {
    let song: Song

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var document: LyricsDocument?
    @State private var isLoading = true
    @State private var error: String?
    @State private var activeIndex: Int = 0
    /// Scroll can lead the sung line so the coming line is already centered
    /// (Apple Music / Spotify feel). Word lighting still keys off `activeIndex`.
    @State private var scrollIndex: Int = 0
    @State private var userOffsetMs: Int = 0
    /// Last presentation time, kept off `@State` so a 60 Hz poll does not
    /// rebuild the lyric sheet. Only a line change writes view state.
    @State private var playhead = PlayheadScratch()
    @State private var userScrolling = false
    @State private var reenableFollowTask: Task<Void, Never>?
    @State private var lastScrolledIndex: Int = -1
    /// How far ahead of a line stamp we start scrolling it into place.
    private let scrollLeadMs = 320
    /// True after a scrub/seek jump — auto-scroll snaps once without animating
    /// through every line between the old and new playhead.
    @State private var scrubSuppressScroll = false
    @State private var wasSeekInFlight = false
    /// Bumped when a seek settles so we re-anchor even if `activeIndex` was
    /// already updated while scroll was suppressed.
    @State private var seekSnapToken = 0

    private enum LineState {
        case past, active, upcoming
    }

    /// Presentation time plus the listener’s nudge. No output-latency term —
    /// `karaokeElapsed()` is already when the sample is heard.
    private func syncElapsedMs() -> Int {
        LyricsClock.syncMilliseconds(
            presentationSeconds: player.karaokeElapsed(),
            userOffsetMs: userOffsetMs)
    }

    /// Holds the previous playhead without publishing a SwiftUI update.
    private final class PlayheadScratch {
        var lastMs: Int = -1
    }

    var body: some View {
        Group {
            if isLoading && document == nil {
                LoadingStateView(message: "Loading lyrics…")
            } else if let error, document == nil {
                ErrorStateView(message: error) { Task { await load(force: true) } }
            } else if let document, !document.lines.isEmpty {
                lyricsBody(document)
            } else if isLoading {
                LoadingStateView(message: "Loading lyrics…")
            } else {
                EmptyStateView(
                    title: "No lyrics yet",
                    systemImage: "text.quote",
                    message: "Checked Navidrome and LRCLIB. The background indexer fills this over time.")
            }
        }
        .task(id: song.id) {
            activeIndex = 0
            scrollIndex = 0
            lastScrolledIndex = -1
            userScrolling = false
            scrubSuppressScroll = false
            wasSeekInFlight = false
            playhead.lastMs = -1
            userOffsetMs = Self.loadOffset(songId: song.id)
            await load(force: false)
        }
        // AV often refines duration after the first buffer — re-align LRCLIB
        // stamps once the live length settles so mid-song words stay locked.
        .onChange(of: player.duration) { _, newDuration in
            guard newDuration > 1, let doc = document, doc.source.hasPrefix("lrclib") else { return }
            let aligned = realignToPlayhead(doc)
            if aligned.lines.map(\.startMs) != doc.lines.map(\.startMs)
                || aligned.matchedDurationSec != doc.matchedDurationSec {
                document = aligned
            }
        }
        .onChange(of: userOffsetMs) { _, _ in
            refreshLineIndex()
        }
        // Line changes only. Word lights live inside the current line so this
        // sheet is not rebuilt on every frame.
        .background {
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 60.0,
                    paused: !player.isPlaying && !player.isSeekInFlight)
            ) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, _ in
                        refreshLineIndex()
                    }
                    .onAppear { refreshLineIndex() }
            }
        }
    }

    private func refreshLineIndex() {
        let ms = syncElapsedMs()
        let seeking = player.isSeekInFlight
        let previous = playhead.lastMs
        if previous >= 0 {
            let jumpMs = abs(ms - previous)
            if seeking {
                scrubSuppressScroll = true
                wasSeekInFlight = true
            } else if wasSeekInFlight {
                // Seek finished — allow one instant re-anchor at the new line.
                wasSeekInFlight = false
                scrubSuppressScroll = false
                lastScrolledIndex = -1
                seekSnapToken &+= 1
            } else if jumpMs > 1_400 {
                // Large playhead jump without an in-flight seek flag (remote / clamp).
                scrubSuppressScroll = true
                lastScrolledIndex = -1
                reenableFollowTask?.cancel()
                reenableFollowTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    scrubSuppressScroll = false
                    lastScrolledIndex = -1
                    seekSnapToken &+= 1
                }
            }
        } else if seeking {
            scrubSuppressScroll = true
            wasSeekInFlight = true
        }
        playhead.lastMs = ms

        guard let document, document.synced else { return }
        let idx = activeLineIndex(at: ms, in: document)
        if idx != activeIndex {
            activeIndex = idx
        }
        let scrollTo = scrollLineIndex(at: ms, in: document)
        if scrollTo != scrollIndex {
            scrollIndex = scrollTo
        }
    }

    /// When LRCLIB’s timed master differs slightly from the file actually
    /// playing, re-scale once against `player.duration`.
    ///
    /// `matchedDurationSec` is the timebase the stamps already live on (master
    /// or a prior library-duration align) — never re-stretch from the raw
    /// LRCLIB length after `LyricsService` has already scaled.
    private func realignToPlayhead(_ document: LyricsDocument) -> LyricsDocument {
        guard document.source.hasPrefix("lrclib"),
              let fromSec = document.matchedDurationSec, fromSec > 0,
              player.duration > 1
        else { return document }
        let toSec = Int((player.duration).rounded())
        guard toSec > 0, abs(toSec - fromSec) > 0 else { return document }
        let scaled = LRCParser.scale(
            document.lines,
            fromDurationMs: fromSec * 1000,
            toDurationMs: toSec * 1000)
        guard scaled.map(\.startMs) != document.lines.map(\.startMs) else {
            // Within the no-op band — still remember the live duration so a
            // later duration refine doesn’t try to scale from a stale master.
            var copy = document
            copy.matchedDurationSec = toSec
            return copy
        }
        return LyricsDocument(
            lines: scaled,
            synced: document.synced,
            source: document.source,
            timingOffsetMs: document.timingOffsetMs,
            matchedDurationSec: toSec,
            wordTiming: document.wordTiming)
    }

    private func lyricsBody(_ document: LyricsDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // Eager VStack (not Lazy) keeps measured heights stable for smooth scrollTo.
                VStack(spacing: 0) {
                    ForEach(Array(document.lines.enumerated()), id: \.element.id) { index, line in
                        KaraokeLine(
                            line: line,
                            state: lineState(index: index, active: activeIndex, synced: document.synced),
                            userOffsetMs: userOffsetMs
                        )
                        .id(line.id)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            seekToLine(line, index: index)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 160)
                .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard !userScrolling else { return }
                        // Finger moving up through the list = reading ahead.
                        if value.translation.height < -8 || abs(value.translation.width) > 20 {
                            userScrolling = true
                            reenableFollowTask?.cancel()
                        }
                    }
                    .onEnded { _ in
                        guard userScrolling else { return }
                        reenableFollowTask?.cancel()
                        reenableFollowTask = Task {
                            try? await Task.sleep(nanoseconds: 2_800_000_000)
                            guard !Task.isCancelled else { return }
                            userScrolling = false
                            lastScrolledIndex = -1
                        }
                    }
            )
            .onChange(of: scrollIndex) { _, newValue in
                let animate = !scrubSuppressScroll && !player.isSeekInFlight
                scrollToActive(
                    proxy: proxy,
                    document: document,
                    index: newValue,
                    animated: animate)
            }
            .onChange(of: seekSnapToken) { _, _ in
                scrollToActive(
                    proxy: proxy,
                    document: document,
                    index: scrollIndex,
                    animated: false)
            }
            .onChange(of: document.lines.first?.id) { _, _ in
                // New document identity (reload) — keep current playhead line,
                // never snap to the top of the sheet.
                lastScrolledIndex = -1
                let ms = syncElapsedMs()
                let idx = document.synced
                    ? activeLineIndex(at: ms, in: document)
                    : activeIndex
                activeIndex = idx
                scrollIndex = document.synced ? scrollLineIndex(at: ms, in: document) : idx
                scrollToActive(proxy: proxy, document: document, index: scrollIndex, animated: false)
            }
            .onAppear {
                scrollToActive(proxy: proxy, document: document, index: scrollIndex, animated: false)
            }
        }
        .overlay(alignment: .bottom) {
            if document.synced {
                syncChrome(document)
            } else {
                Text(sourceLabel(document.source))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .padding(.bottom, 10)
            }
        }
    }

    private func syncChrome(_ document: LyricsDocument) -> some View {
        // Word-synced tracks need finer nudges; line karaoke stays at ±0.5s.
        let stepMs = document.wordTiming == .measured ? 100 : 500
        return HStack(spacing: 14) {
            Button {
                nudgeOffset(by: -stepMs)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            .accessibilityLabel("Running early")
            .accessibilityHint("Delay the highlight when lyrics appear ahead of the vocal")

            VStack(spacing: 2) {
                Text(offsetLabel)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.85))
                if let timing = timingLabel(document) {
                    Text(timing)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            document.wordTiming == .measured
                                ? DromeTheme.accent.opacity(0.9)
                                : Color.white.opacity(0.55))
                }
                Text(sourceLabel(document.source))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .onLongPressGesture {
                userOffsetMs = 0
                Self.saveOffset(0, songId: song.id)
                refreshLineIndex()
            }
            .accessibilityHint("Long press to reset sync")

            Button {
                nudgeOffset(by: stepMs)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            .accessibilityLabel("Running late")
            .accessibilityHint("Advance the highlight when lyrics lag behind the vocal")

            Button {
                Task { await load(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .accessibilityLabel("Reload lyrics")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 12)
    }

    private var offsetLabel: String {
        if userOffsetMs == 0 { return "Sync" }
        let seconds = Double(userOffsetMs) / 1000.0
        return String(format: "%+.1fs", seconds)
    }

    private func nudgeOffset(by delta: Int) {
        // Clamp to ±8s — beyond that the match is probably wrong.
        userOffsetMs = min(8_000, max(-8_000, userOffsetMs + delta))
        Self.saveOffset(userOffsetMs, songId: song.id)
        refreshLineIndex()
    }

    private func scrollToActive(proxy: ScrollViewProxy, document: LyricsDocument, index: Int, animated: Bool) {
        guard document.synced, !userScrolling else { return }
        // While scrubbing, update highlights but don't chase the list — a seek
        // that flickers through 0 would yank the sheet to the first line.
        if scrubSuppressScroll || player.isSeekInFlight {
            return
        }
        guard document.lines.indices.contains(index) else { return }
        guard index != lastScrolledIndex else { return }
        lastScrolledIndex = index
        let id = document.lines[index].id
        if animated {
            // Short ease — long `.smooth` scrolls felt sluggish vs Apple Music.
            withAnimation(.easeInOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.38))
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.38))
            }
        }
    }

    private func lineState(index: Int, active: Int, synced: Bool) -> LineState {
        guard synced else { return .upcoming }
        if index < active { return .past }
        if index == active { return .active }
        return .upcoming
    }

    /// Jump playback to the tapped line's stamp. Uses `seekExact` so streaming
    /// buffers can't clamp a mid-song lyric into a random early second.
    private func seekToLine(_ line: LRCParser.Line, index: Int) {
        let start = line.startMs ?? line.words.first?.startMs
        guard let start else { return }
        userScrolling = false
        lastScrolledIndex = index
        activeIndex = index
        scrollIndex = index
        // Undo the sync nudge so audio lands where this stamp was authored.
        let seekTo = max(0, Double(start - userOffsetMs) / 1000.0)
        if session.connect?.isRemote == true {
            Task {
                await session.connect?.sendRemote(ConnectCommandType.seek, seekTo: seekTo)
            }
        } else {
            player.seekExact(to: seekTo)
        }
    }

    private func activeLineIndex(at elapsedMs: Int, in document: LyricsDocument) -> Int {
        // Heard stamp + mid-break focus for scale / past-upcoming chrome.
        // Word lighting still waits on each cue’s start.
        LRCParser.currentLineIndex(lines: document.lines, atMs: elapsedMs)
    }

    /// Scroll target may lead the sung line so the next lyric is centered
    /// just before it starts — without advancing word karaoke early.
    private func scrollLineIndex(at elapsedMs: Int, in document: LyricsDocument) -> Int {
        let heard = LRCParser.activeLineIndex(lines: document.lines, atMs: elapsedMs)
        if heard + 1 < document.lines.count,
           let nextStart = document.lines[heard + 1].startMs,
           nextStart > elapsedMs,
           nextStart - elapsedMs <= scrollLeadMs {
            return heard + 1
        }
        return activeLineIndex(at: elapsedMs, in: document)
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "navidrome", "navidrome.v2", "navidrome.v3", "navidrome.v4", "navidrome.v5",
             "sidecar", "sidecar.v1", "offline", "offline.v1":
            return "From your library"
        case "lrclib", "lrclib.v2", "lrclib.v3", "lrclib.v4", "lrclib.v5":
            return "From LRCLIB"
        default: return ""
        }
    }

    private func timingLabel(_ document: LyricsDocument) -> String? {
        guard document.synced else { return nil }
        switch document.wordTiming {
        case .measured: return "Word-synced"
        case .approximated: return "Approx. word timing"
        case .none: return nil
        }
    }

    private func load(force: Bool) async {
        // Keep showing the current sheet while refreshing — blanking the view
        // reset scroll to the top and felt like the lyric connection "broke".
        let showSpinner = document == nil
        if showSpinner { isLoading = true }
        error = nil
        defer { isLoading = false }
        let fetched: LyricsDocument?
        if force {
            fetched = await session.lyricsService.refetch(for: song)
        } else {
            fetched = await session.lyricsService.lyrics(for: song)
        }
        if let fetched {
            let aligned = realignToPlayhead(fetched)
            if aligned.synced {
                let ms = syncElapsedMs()
                activeIndex = activeLineIndex(at: ms, in: aligned)
                scrollIndex = scrollLineIndex(at: ms, in: aligned)
            }
            lastScrolledIndex = -1
            document = aligned
        } else if document == nil {
            document = nil
        }
    }

    private static func offsetKey(songId: String) -> String {
        "drome.lyricsSyncOffset.\(songId)"
    }

    private static func loadOffset(songId: String) -> Int {
        UserDefaults.standard.integer(forKey: offsetKey(songId: songId))
    }

    private static func saveOffset(_ ms: Int, songId: String) {
        if ms == 0 {
            UserDefaults.standard.removeObject(forKey: offsetKey(songId: songId))
        } else {
            UserDefaults.standard.set(ms, forKey: offsetKey(songId: songId))
        }
    }

    // MARK: - Line

    private struct KaraokeLine: View {
        let line: LRCParser.Line
        let state: LineState
        let userOffsetMs: Int

        @EnvironmentObject private var player: PlayerEngine

        /// Same size for every line — only opacity / scale change, so neighbors don't jump.
        private let baseSize: CGFloat = 24

        var body: some View {
            VStack(alignment: stackAlignment, spacing: 3) {
                if let label = line.singerLabel {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(labelColor)
                        .opacity(state == .upcoming ? 0.35 : 1)
                }

                words
                    .frame(maxWidth: line.side == .group ? 300 : 270, alignment: frameAlignment)
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(.leading, line.side == .secondary ? 28 : 0)
            .padding(.trailing, line.side == .primary ? 28 : 0)
            // Scale does not affect layout — keeps scroll positions stable.
            // No spring: spring settle made the active line feel late vs the vocal.
            .scaleEffect(state == .active ? 1.05 : 1.0, anchor: scaleAnchor)
            .animation(nil, value: state == .active)
        }

        @ViewBuilder
        private var words: some View {
            if state == .active, !line.words.isEmpty {
                // Only this line tracks the display link. Neighbors stay one Text.
                TimelineView(
                    .animation(
                        minimumInterval: 1.0 / 60.0,
                        paused: !player.isPlaying && !player.isSeekInFlight)
                ) { _ in
                    wordRun(atMs: LyricsClock.syncMilliseconds(
                        presentationSeconds: player.karaokeElapsed(),
                        userOffsetMs: userOffsetMs))
                        .multilineTextAlignment(textAlignment)
                        .transaction { $0.animation = nil }
                }
            } else {
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: baseSize, weight: .semibold))
                    .foregroundStyle(baseColor)
                    .multilineTextAlignment(textAlignment)
            }
        }

        /// One `Text` so wrapping stays natural. Each word lights on its stamp
        /// (short post-attack ease) and stays lit — no trailing dim, no glyph sweep.
        private func wordRun(atMs: Int) -> Text {
            line.words.enumerated().reduce(Text("")) { partial, item in
                let word = item.element
                let gap = item.offset == 0 ? "" : " "
                let opacity = LyricsClock.wordOpacity(elapsedMs: word.elapsed(atMs: atMs))
                let piece = Text(gap + word.text)
                    .font(.system(
                        size: word.marker ? 15 : baseSize,
                        weight: word.marker ? .semibold : .semibold))
                    .foregroundColor(Color.white.opacity(opacity))
                return partial + piece
            }
        }

        private var stackAlignment: HorizontalAlignment {
            switch line.side {
            case .primary: return .leading
            case .secondary: return .trailing
            case .group: return .center
            }
        }

        private var frameAlignment: Alignment {
            switch line.side {
            case .primary: return .leading
            case .secondary: return .trailing
            case .group: return .center
            }
        }

        private var scaleAnchor: UnitPoint {
            switch line.side {
            case .primary: return .leading
            case .secondary: return .trailing
            case .group: return .center
            }
        }

        private var textAlignment: TextAlignment {
            switch line.side {
            case .primary: return .leading
            case .secondary: return .trailing
            case .group: return .center
            }
        }

        private var labelColor: Color {
            switch state {
            case .active: return DromeTheme.accent
            case .past: return Color.white.opacity(0.55)
            case .upcoming: return Color.white.opacity(0.35)
            }
        }

        private var baseColor: Color {
            switch state {
            case .active: return .white
            // Past stays clearly brighter than upcoming so finished lines read as done.
            case .past: return Color.white.opacity(0.58)
            case .upcoming: return Color.white.opacity(0.24)
            }
        }
    }
}
