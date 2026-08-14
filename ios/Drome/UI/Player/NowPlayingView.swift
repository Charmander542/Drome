import SwiftUI


/// One cover in the Now Playing art strip. `id` is the song id so SwiftUI
/// reuses the same RemoteImage when a cover moves from next → current.
private struct ArtStripPage: Identifiable, Equatable {
    let id: String
    let url: URL?
}

/// Spotify-style full-screen Now Playing.
/// All sizing is derived from the local GeometryReader so content always fits
/// the visible phone width (no UIScreen / overflow clipping).
struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var ratings: RatingsStore
    @EnvironmentObject private var rotation: RotationManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Pane = .song
    @State private var showQueue = false
    @State private var showAddToPlaylist = false
    @State private var isSeeking = false
    @State private var seekElapsed: Double = 0
    /// Brief override so skip/restart can glide the scrubber to 0.
    @State private var scrubAnimElapsed: Double?
    @State private var lastScrubDisplayed: Double = 0
    @State private var dismissDrag: CGFloat = 0
    @State private var flashMessage: String?
    /// Always [previous, current, next] — center is index 1 when drag is 0.
    @State private var artPages: [ArtStripPage] = []
    @State private var artDragX: CGFloat = 0
    @State private var artSwipeAnimating = false
    @State private var artContainerWidth: CGFloat = 390
    @State private var showMoreSheet = false

    private enum Pane: String, CaseIterable {
        case song = "Song"
        case lyrics = "Lyrics"
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                background
                    .frame(width: width, height: height)
                    .clipped()

                VStack(spacing: 0) {
                    grabber

                    sharePlayBanner
                        .padding(.bottom, 8)

                    panePicker
                        .frame(maxWidth: min(280, width - 48))
                        .padding(.bottom, 8)

                    Group {
                        switch tab {
                        case .song:
                            songPane(width: width, height: height - 72)
                        case .lyrics:
                            lyricsPane
                                // Match song pane's remaining height so the
                                // Lyrics tab doesn't sit lower than Song.
                                .frame(width: width, height: height - 72, alignment: .top)
                        }
                    }
                    .frame(width: width)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(width: width, height: height)
            }
            .frame(width: width, height: height)
            .offset(y: max(0, dismissDrag))
            .transaction { txn in
                if dismissDrag > 0 { txn.animation = nil }
            }
            // Song pane only — lyrics scrolling must not pull the sheet closed.
            .modifier(ConditionalDismissGesture(enabled: tab == .song, gesture: dismissGesture))
        }
        .ignoresSafeArea(edges: .bottom)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .dromeSession(session)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let song = player.current?.song {
                NavigationStack {
                    AddToPlaylistView(song: song)
                        .dromeSession(session)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showAddToPlaylist = false }
                            }
                        }
                }
                .preferredColorScheme(.dark)
            }
        }
        .sheet(isPresented: $showMoreSheet) {
            if let song = player.current?.song {
                NowPlayingMoreSheet(song: song, isPresented: $showMoreSheet) {
                    showAddToPlaylist = true
                }
                .dromeSession(session)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .overlay(alignment: .top) {
            if let flashMessage {
                Text(flashMessage)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 56)
                    .transition(.opacity)
            }
        }
        .onChange(of: player.sharePlayNotice) { _, message in
            guard let message, !message.isEmpty else { return }
            flash(message)
            player.sharePlayNotice = nil
        }
        .animation(.easeInOut(duration: 0.2), value: flashMessage)
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    private var grabber: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.white.opacity(0.45))
                .frame(width: 36, height: 5)
            Text(player.context.map { "Playing from \($0.label)" } ?? " ")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
                .frame(height: 16)
                .opacity(player.context == nil ? 0 : 1)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // Always allow dismiss from the grabber, including on the Lyrics pane.
        .simultaneousGesture(dismissGesture)
    }

    private var sharePlayBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "shareplay")
                .font(.caption.weight(.bold))
            Text(sharePlayBannerTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if player.sharePlayActive {
                Button("Leave") {
                    player.leaveSharePlay()
                }
                .font(.caption.weight(.bold))
            } else {
                Text(player.isEligibleForSharePlay ? "Join" : "Start")
                    .font(.caption.weight(.bold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            (player.sharePlayActive || player.isEligibleForSharePlay
             ? DromeTheme.accent.opacity(0.85)
             : Color.white.opacity(0.16)),
            in: Capsule()
        )
        .padding(.horizontal, 20)
        .opacity(player.current == nil && !player.isEligibleForSharePlay && !player.sharePlayActive ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !player.sharePlayActive else { return }
            player.startSharePlay()
        }
        .disabled(player.current == nil && !player.isEligibleForSharePlay && !player.sharePlayActive)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(player.sharePlayActive ? [] : .isButton)
        .accessibilityLabel(player.sharePlayActive ? "Jam" : (player.isEligibleForSharePlay ? "Join Jam" : "Start Jam"))
        .accessibilityAction {
            if player.sharePlayActive {
                player.leaveSharePlay()
            } else {
                player.startSharePlay()
            }
        }
    }

    private var sharePlayBannerTitle: String {
        if player.sharePlayActive {
            return player.sharePlayParticipantCount > 1
                ? "Jam on each phone · \(player.sharePlayParticipantCount)"
                : "Waiting — they tap Join in Drome"
        }
        if player.isEligibleForSharePlay {
            return "On FaceTime · tap Join"
        }
        return "Start a Jam on FaceTime"
    }

    private var panePicker: some View {
        Picker("", selection: $tab) {
            ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var background: some View {
        ZStack {
            Color.black
            // Prefer the strip's centered cover so the blur doesn't jump ahead
            // of the art swipe animation.
            if let url = artPages.count > 1 ? artPages[1].url : artPages.first?.url {
                RemoteImage(url: url, holdImageWhileLoading: true)
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(0.4)
                    .allowsHitTesting(false)
            }
            LinearGradient(
                colors: [.black.opacity(0.1), .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                // Only track mostly-vertical pulls; ignore diagonal noise.
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) * 1.15
                else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dismissDrag = value.translation.height
                }
            }
            .onEnded { value in
                let shouldDismiss = value.translation.height > 140
                    || value.predictedEndTranslation.height > 220
                if shouldDismiss {
                    dismiss()
                    dismissDrag = 0
                } else {
                    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.9)) {
                        dismissDrag = 0
                    }
                }
            }
    }

    private var swipeUpToLyricsGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard value.translation.height < -70,
                      abs(value.translation.height) > abs(value.translation.width) * 1.2
                else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    tab = .lyrics
                }
            }
    }

    // MARK: - Song pane

    private func songPane(width: CGFloat, height: CGFloat) -> some View {
        let horizontalPad: CGFloat = 24
        let contentWidth = max(0, width - horizontalPad * 2)
        let artSide = min(contentWidth, max(180, height * 0.38))

        return VStack(spacing: 0) {
            Spacer(minLength: 4)

            artwork(side: artSide, containerWidth: width)

            Spacer(minLength: 16)

            metadataBlock
                .frame(width: contentWidth, alignment: .leading)
                .id(player.current?.id)

            Spacer(minLength: 10)

            ratingBlock
                .frame(width: contentWidth, alignment: .leading)
                .id(player.current?.id)

            Spacer(minLength: 12)

            scrubber
                .frame(width: contentWidth)

            Spacer(minLength: 8)

            transport
                .frame(width: contentWidth)

            Spacer(minLength: 10)

            bottomBar
                .frame(width: contentWidth)
                .padding(.bottom, 24)
        }
        .frame(width: width, height: height)
    }

    private func artwork(side: CGFloat, containerWidth: CGFloat) -> some View {
        let stride = containerWidth

        return ZStack {
            ForEach(Array(artPages.enumerated()), id: \.element.id) { index, page in
                coverCard(url: page.url, side: side)
                    // Fixed center slot = index 1. Neighbors live at ±stride.
                    .offset(x: CGFloat(index - 1) * stride + artDragX)
            }
        }
        .frame(width: containerWidth, height: side)
        .clipped()
        .contentShape(Rectangle())
        .onAppear { artContainerWidth = containerWidth }
        .onChange(of: containerWidth) { _, width in artContainerWidth = width }
        .gesture(artSwipeGesture(containerWidth: containerWidth))
        .simultaneousGesture(swipeUpToLyricsGesture)
        .onChange(of: player.current?.song.id) { _, _ in
            guard !artSwipeAnimating else { return }
            reloadArtPages(keepingDrag: false)
            animateScrubToStart()
        }
        .onChange(of: player.userQueue.count) { _, _ in
            guard !artSwipeAnimating else { return }
            reloadArtPages(keepingDrag: false)
        }
        .onChange(of: player.contextQueue.count) { _, _ in
            guard !artSwipeAnimating else { return }
            reloadArtPages(keepingDrag: false)
        }
        .onChange(of: player.history.count) { _, _ in
            guard !artSwipeAnimating else { return }
            reloadArtPages(keepingDrag: false)
        }
        .onAppear { reloadArtPages(keepingDrag: false) }
    }

    private func coverCard(url: URL?, side: CGFloat) -> some View {
        RemoteImage(url: url, holdImageWhileLoading: true)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
    }

    private func makeArtPages() -> [ArtStripPage] {
        let currentSong = player.current?.song
        let prevSong = player.artSwipePreviousSong
        let nextSong = player.artSwipeNextSong

        let prev: ArtStripPage = {
            if let prevSong, prevSong.id != currentSong?.id {
                return ArtStripPage(id: prevSong.id, url: session.artworkURL(for: prevSong, size: 800))
            }
            return ArtStripPage(id: "placeholder-prev", url: nil)
        }()
        let current: ArtStripPage = {
            if let currentSong {
                return ArtStripPage(id: currentSong.id, url: session.artworkURL(for: currentSong, size: 800))
            }
            return ArtStripPage(id: "placeholder-current", url: nil)
        }()
        let next: ArtStripPage = {
            if let nextSong, nextSong.id != currentSong?.id, nextSong.id != prevSong?.id {
                return ArtStripPage(id: nextSong.id, url: session.artworkURL(for: nextSong, size: 800))
            }
            return ArtStripPage(id: "placeholder-next", url: nil)
        }()

        let pages = [prev, current, next]
        ImageLoader.shared.prefetch(pages.compactMap(\.url))
        return pages
    }

    private func reloadArtPages(keepingDrag: Bool) {
        artPages = makeArtPages()
        if !keepingDrag {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { artDragX = 0 }
        }
    }

    private var canSwipeArtPrevious: Bool {
        guard artPages.count == 3 else { return false }
        return !artPages[0].id.hasPrefix("placeholder")
    }

    private var canSwipeArtNext: Bool {
        guard artPages.count == 3 else { return false }
        return !artPages[2].id.hasPrefix("placeholder")
    }

    private func artSwipeGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !artSwipeAnimating else { return }
                guard abs(value.translation.width) > abs(value.translation.height) * 0.7 else { return }
                var dx = value.translation.width
                if dx > 0, !canSwipeArtPrevious {
                    dx = rubberBand(dx, limit: containerWidth * 0.22)
                } else if dx < 0, !canSwipeArtNext {
                    dx = -rubberBand(-dx, limit: containerWidth * 0.22)
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { artDragX = dx }
            }
            .onEnded { value in
                guard !artSwipeAnimating else { return }
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let threshold = min(110, containerWidth * 0.22)
                let goNext = (dx < -threshold || predicted < -threshold * 1.4) && canSwipeArtNext
                let goPrevious = (dx > threshold || predicted > threshold * 1.4) && canSwipeArtPrevious

                if goNext {
                    completeArtSwipe(goingNext: true, containerWidth: containerWidth)
                } else if goPrevious {
                    completeArtSwipe(goingNext: false, containerWidth: containerWidth)
                } else {
                    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                        artDragX = 0
                    }
                }
            }
    }

    private func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        return (1 - (1 / ((value * 0.55 / limit) + 1))) * limit
    }

    private func skipNextWithArt() {
        guard !artSwipeAnimating else { return }
        if canSwipeArtNext {
            completeArtSwipe(goingNext: true, containerWidth: artContainerWidth)
        } else {
            animateScrubToStart()
            player.next()
        }
    }

    private func skipPreviousWithArt() {
        guard !artSwipeAnimating else { return }
        // Match hardware/previous button: restart if we're >3s in.
        if player.elapsed > 3 {
            animateScrubToStart()
            player.previous()
            return
        }
        if canSwipeArtPrevious {
            completeArtSwipe(goingNext: false, containerWidth: artContainerWidth)
        } else {
            player.previous(preferPreviousTrack: true)
        }
    }

    /// Glide the scrubber thumb to 0 so skips don't hard-jump the playhead UI.
    private func animateScrubToStart() {
        let from = isSeeking ? seekElapsed : (scrubAnimElapsed ?? lastScrubDisplayed)
        guard from > 0.35 else {
            scrubAnimElapsed = nil
            return
        }
        scrubAnimElapsed = from
        withAnimation(.easeOut(duration: 0.28)) {
            scrubAnimElapsed = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            scrubAnimElapsed = nil
        }
    }

    private func completeArtSwipe(goingNext: Bool, containerWidth: CGFloat) {
        guard artPages.count == 3 else { return }
        artSwipeAnimating = true
        let exitX = goingNext ? -containerWidth : containerWidth

        // Snapshot before anything moves / playback changes.
        let prev = artPages[0]
        let current = artPages[1]
        let next = artPages[2]

        withAnimation(.easeInOut(duration: 0.28)) {
            artDragX = exitX
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            // At exitX the neighbor is already visually centered:
            //   next swipe → index 2 at offset 0
            //   prev swipe → index 0 at offset 0
            // Snap pages + drag together so that same song-id stays on-center
            // at index 1 with drag 0. Do this BEFORE touching the player so a
            // published track change can't rebuild the strip one frame early.
            let rotated: [ArtStripPage] = goingNext
                ? [current, next, ArtStripPage(id: "placeholder-next-pending", url: nil)]
                : [ArtStripPage(id: "placeholder-prev-pending", url: nil), prev, current]

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                artPages = rotated
                artDragX = 0
            }

            player.advanceFromArtSwipe(goingNext: goingNext)

            // Fill the new off-screen neighbor; center (index 1) stays put.
            var filled = artPages
            if goingNext {
                if let song = player.artSwipeNextSong, song.id != filled[1].id {
                    filled[2] = ArtStripPage(
                        id: song.id,
                        url: session.artworkURL(for: song, size: 800)
                    )
                } else {
                    filled[2] = ArtStripPage(id: "placeholder-next", url: nil)
                }
            } else if let song = player.artSwipePreviousSong, song.id != filled[1].id {
                filled[0] = ArtStripPage(
                    id: song.id,
                    url: session.artworkURL(for: song, size: 800)
                )
            } else {
                filled[0] = ArtStripPage(id: "placeholder-prev", url: nil)
            }
            withTransaction(transaction) {
                artPages = filled
            }
            ImageLoader.shared.prefetch(filled.compactMap(\.url))
            artSwipeAnimating = false
        }
    }

    private var metadataBlock: some View {
        let song = player.current?.song
        let title = cleaned(song?.title) ?? "Unknown Title"
        let isDownloaded = song.map { downloads.isDownloaded($0.id) } ?? false

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                // Tap title → album (when we know the album id).
                HStack(alignment: .center, spacing: 6) {
                    Group {
                        if let song, let albumId = song.albumId, !albumId.isEmpty {
                            NavigationLink {
                                AlbumDetailView(
                                    albumID: albumId,
                                    placeholder: Album(
                                        id: albumId,
                                        name: song.album ?? title,
                                        artist: song.artist,
                                        artistId: song.artistId,
                                        coverArt: song.coverArt,
                                        songCount: nil, duration: nil, playCount: nil,
                                        created: nil, year: nil, genre: nil, userRating: nil
                                    )
                                )
                            } label: {
                                Text(title)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(title)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                    .layoutPriority(1)

                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DromeTheme.accent)
                            .accessibilityLabel("Downloaded")
                    }

                    Spacer(minLength: 0)
                }

                // Each credited artist name is independently tappable.
                if let song {
                    SongArtistLinks(
                        song: song,
                        font: .subheadline,
                        color: Color.white.opacity(0.7)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Unknown Artist")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                }

                if let badge = song?.qualityBadge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DromeTheme.accent.opacity(0.95))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 48, alignment: .leading)

            if song != nil {
                Button {
                    showMoreSheet = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var ratingBlock: some View {
        Group {
            if let song = player.current?.song {
                StarRatingControl(rating: ratings.rating(for: song), size: 22) { newRating in
                    ratings.setRating(newRating, for: song)
                    if newRating == 0 {
                        flash("Rating cleared")
                    } else {
                        flash("Rated \(newRating)★")
                    }
                }
                .id("\(song.id)-\(ratings.revision)")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // Menu content moved to NowPlayingMoreSheet to avoid Menu flicker on playhead ticks.

    private var scrubber: some View {
        let total = stableDuration
        let live = min(max(0, clock.elapsed), total)
        let displayed: Double = {
            if isSeeking { return seekElapsed }
            if let scrubAnimElapsed { return scrubAnimElapsed }
            return live
        }()

        return VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { displayed },
                    set: { newValue in
                        scrubAnimElapsed = nil
                        seekElapsed = newValue
                        if !isSeeking { isSeeking = true }
                    }
                ),
                in: 0...max(total, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        scrubAnimElapsed = nil
                        if !isSeeking {
                            seekElapsed = min(max(0, clock.elapsed), total)
                        }
                        isSeeking = true
                    } else {
                        let target = min(max(0, seekElapsed), total)
                        seekElapsed = target
                        player.seek(to: target)
                        // Hold the scrubbed time until AVPlayer finishes seeking.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            isSeeking = false
                        }
                    }
                }
            )
            .tint(.white)
            .onChange(of: displayed) { old, value in
                guard scrubAnimElapsed == nil else { return }
                // Preserve the pre-skip position when the playhead hard-jumps to 0.
                if value < 0.25, old > 1 {
                    lastScrubDisplayed = old
                } else {
                    lastScrubDisplayed = value
                }
            }

            HStack {
                Text(Formatters.playbackTime(displayed))
                    .frame(minWidth: 40, alignment: .leading)
                Spacer()
                Text(Formatters.playbackTime(total))
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.7))
        }
        .frame(height: 44)
    }

    private var transport: some View {
        HStack {
            Button { player.cycleShuffleMode() } label: {
                Image(systemName: "shuffle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(shuffleColor)
                    .frame(width: 40, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if player.shuffleMode == .smart {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(DromeTheme.accent)
                                .offset(x: -2, y: 8)
                        }
                    }
            }

            Spacer(minLength: 0)

            Button { skipPreviousWithArt() } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .disabled(artSwipeAnimating)

            Button { player.playPause() } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 62, height: 62)
                }
            }
            .buttonStyle(ScaleButtonStyle())

            Button { skipNextWithArt() } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .disabled(artSwipeAnimating)

            Spacer(minLength: 0)

            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(player.repeatMode == .off ? Color.white.opacity(0.45) : DromeTheme.accent)
                    .frame(width: 40, height: 44)
            }
        }
        .frame(height: 68)
    }

    private var bottomBar: some View {
        HStack {
            AirPlayRoutePicker()
                .frame(width: 44, height: 44)
                .accessibilityLabel("Audio output")

            Spacer()

            Button {
                player.autoplayEnabled.toggle()
            } label: {
                Image(systemName: "infinity")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(player.autoplayEnabled ? DromeTheme.accent : Color.white.opacity(0.45))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Autoplay")

            Spacer()

            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Queue")
        }
        .frame(height: 44)
    }

    private var lyricsPane: some View {
        Group {
            if let song = player.current?.song {
                LyricsView(song: song)
            } else {
                EmptyStateView(title: "Nothing playing")
            }
        }
    }

    private var stableDuration: Double {
        let live = clock.duration
        if live.isFinite, live > 0.5 { return live }
        if let meta = player.current?.song.duration, meta > 0 { return Double(meta) }
        return max(live, 0.1)
    }

    private var shuffleColor: Color {
        switch player.shuffleMode {
        case .off: return Color.white.opacity(0.45)
        case .smart, .random: return DromeTheme.accent
        }
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func flash(_ message: String) {
        flashMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if flashMessage == message { flashMessage = nil }
        }
    }
}

private struct ConditionalDismissGesture<G: Gesture>: ViewModifier {
    let enabled: Bool
    let gesture: G

    func body(content: Content) -> some View {
        if enabled {
            content.simultaneousGesture(gesture)
        } else {
            content
        }
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Stable action sheet for Now Playing — avoids SwiftUI `Menu` flicker while
/// the playhead publishes updates.
struct NowPlayingMoreSheet: View {
    let song: Song
    @Binding var isPresented: Bool
    var onAddToPlaylist: () -> Void

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var rotation: RotationManager
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let albumId = song.albumId, !albumId.isEmpty {
                        NavigationLink {
                            AlbumDetailView(
                                albumID: albumId,
                                placeholder: Album(
                                    id: albumId,
                                    name: song.album ?? song.title,
                                    artist: song.artist,
                                    artistId: song.artistId,
                                    coverArt: song.coverArt,
                                    songCount: nil, duration: nil, playCount: nil,
                                    created: nil, year: nil, genre: nil, userRating: nil
                                )
                            )
                        } label: {
                            Label("View Album", systemImage: "square.stack")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    }

                    let artistRoutes = SongNavigation.artistRoutes(for: song)
                    if artistRoutes.count > 1 {
                        ForEach(artistRoutes) { route in
                            NavigationLink {
                                ArtistDetailView(artistID: route.artistId,
                                                 placeholderName: route.name)
                            } label: {
                                Label(route.name, systemImage: "person.wave.2")
                            }
                            .listRowBackground(DromeTheme.elevated)
                        }
                    } else if let route = artistRoutes.first ?? SongNavigation.artistRoute(for: song) {
                        NavigationLink {
                            ArtistDetailView(artistID: route.artistId,
                                             placeholderName: route.name)
                        } label: {
                            Label("View Artist", systemImage: "person.wave.2")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    }
                }

                Section {
                    Button {
                        isPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onAddToPlaylist()
                        }
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }
                    .listRowBackground(DromeTheme.elevated)

                    if downloads.isDownloaded(song.id) {
                        Button(role: .destructive) {
                            downloads.remove(songId: song.id)
                            isPresented = false
                        } label: {
                            Label("Remove Download", systemImage: "trash")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    } else if downloads.isBusy(song.id) {
                        Button(role: .destructive) {
                            downloads.cancel(songId: song.id)
                            isPresented = false
                        } label: {
                            Label("Cancel Download", systemImage: "xmark.circle")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    } else {
                        Button {
                            downloads.download([song])
                            isPresented = false
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    }

                    Button {
                        SongShare.present(song: song)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .listRowBackground(DromeTheme.elevated)

                    Button {
                        if player.sharePlayActive {
                            player.leaveSharePlay()
                        } else {
                            player.startSharePlay()
                        }
                        isPresented = false
                    } label: {
                        Label(
                            player.sharePlayActive ? "Leave Jam" : "Start a Jam (SharePlay)",
                            systemImage: "shareplay")
                    }
                    .listRowBackground(DromeTheme.elevated)

                    if rotation.contains(song.id) {
                        Button {
                            Task {
                                await rotation.remove(song, manual: true)
                                isPresented = false
                            }
                        } label: {
                            Label("Remove from Out of Rotation", systemImage: "lock.open")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    } else {
                        Button {
                            Task {
                                await rotation.add(song, manual: true)
                                isPresented = false
                            }
                        } label: {
                            Label("Add to Out of Rotation", systemImage: "lock")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    }

                    Button {
                        player.rerollAutoplayQueue()
                        isPresented = false
                    } label: {
                        Label("Reroll Autoplay", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .listRowBackground(DromeTheme.elevated)

                    Button {
                        player.autoplayEnabled.toggle()
                        isPresented = false
                    } label: {
                        Label(player.autoplayEnabled ? "Turn Autoplay Off" : "Turn Autoplay On",
                              systemImage: "infinity")
                    }
                    .listRowBackground(DromeTheme.elevated)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DromeTheme.background)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

