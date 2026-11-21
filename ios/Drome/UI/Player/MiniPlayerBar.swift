import SwiftUI
import UIKit

struct MiniPlayerBar: View {
    var onOpen: () -> Void

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var session: AppSession

    /// Stable 3-slot strip (prev / current / next) — same pattern as NP art swipe.
    @State private var chromePages: [ChromePage] = []
    @State private var dragX: CGFloat = 0
    @State private var isDragging = false
    @State private var swipeAnimating = false
    @State private var swipeGeneration = 0
    @State private var slotWidth: CGFloat = 200
    @State private var washColor: Color = DromeTheme.accent
    @State private var showOutput = false

    var body: some View {
        if let current = player.current {
            let remote = session.connect?.isRemote == true
            let center = chromePages.count == 3 ? chromePages[1] : nil
            let a11yTitle = center?.title ?? cleaned(current.song.title) ?? "Unknown Title"
            let a11yArtist = center?.artist ?? displayArtist(for: current.song)

            HStack(spacing: 4) {
                chromeStrip
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .gesture(swipeGesture)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("drome.music.mini.open")
                    .accessibilityLabel("\(a11yTitle), \(a11yArtist)")
                    .accessibilityHint("Swipe left or right to change tracks. Double tap to open now playing.")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onOpen() }
                    .accessibilityAction(named: "Next") {
                        completeSwipe(goingNext: true)
                    }
                    .accessibilityAction(named: "Previous") {
                        completeSwipe(goingNext: false)
                    }

                Button {
                    if remote {
                        let playing = session.connect?.remoteSession?.isPlaying == true
                        Task {
                            await session.connect?.sendRemote(
                                playing ? ConnectCommandType.pause : ConnectCommandType.play)
                        }
                    } else {
                        player.playPause()
                    }
                } label: {
                    Image(systemName: transportPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(transportPlaying ? "Pause" : "Play")

                Button {
                    showOutput = true
                } label: {
                    Image(systemName: remote ? "speaker.wave.2.fill" : "hifispeaker.2.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(remote ? DromeTheme.accent : .white)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.connect != nil ? "Connect and AirPlay" : "AirPlay")
                .accessibilityIdentifier("drome.music.mini.output")
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
            .background {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: DromeTheme.Radius.md, style: .continuous)
                        .fill(DromeTheme.elevated.opacity(0.94))
                    RoundedRectangle(cornerRadius: DromeTheme.Radius.md, style: .continuous)
                        .fill(washColor.opacity(remote ? 0.42 : 0.28))
                    RoundedRectangle(cornerRadius: DromeTheme.Radius.md, style: .continuous)
                        .stroke(
                            remote ? DromeTheme.accent.opacity(0.55) : Color.white.opacity(0.06),
                            lineWidth: 1
                        )

                    // Spotify-style progress hairline along the bottom edge.
                    miniProgressHairline
                }
                .clipShape(RoundedRectangle(cornerRadius: DromeTheme.Radius.md, style: .continuous))
                .animation(.easeInOut(duration: 0.85), value: washColor)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .onAppear { reloadPages(keepingDrag: false) }
            .onChange(of: current.song.id) { _, _ in
                guard !swipeAnimating else { return }
                reloadPages(keepingDrag: false)
            }
            .onChange(of: player.userQueue.count) { _, _ in
                guard !swipeAnimating else { return }
                reloadPages(keepingDrag: true)
            }
            .onChange(of: player.contextQueue.count) { _, _ in
                guard !swipeAnimating else { return }
                reloadPages(keepingDrag: true)
            }
            .onChange(of: player.history.count) { _, _ in
                guard !swipeAnimating else { return }
                reloadPages(keepingDrag: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("music-mini-player")
            .accessibilityHint(remote ? "Playing on another Connect device." : "")
            .sheet(isPresented: $showOutput) {
                AudioOutputSheet()
                    .environmentObject(session)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Strip

    private var chromeStrip: some View {
        GeometryReader { geo in
            let slot = max(geo.size.width, 80)
            let drag = dragX.isFinite ? dragX : 0

            // ZStack + page-id identity keeps the incoming cover's RemoteImage
            // alive across the rotate (no remount → no black flash).
            ZStack(alignment: .leading) {
                ForEach(Array(chromePages.enumerated()), id: \.element.id) { index, page in
                    chromeSlot(page: page)
                        .frame(width: slot, alignment: .leading)
                        .offset(x: CGFloat(index - 1) * slot + drag)
                }
            }
            .frame(width: slot, alignment: .leading)
            .clipped()
            .onAppear { slotWidth = slot }
            .onChange(of: geo.size.width) { _, w in slotWidth = max(w, 80) }
        }
        .frame(height: 48)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isDragging, !swipeAnimating, abs(dragX) < 4 else { return }
            onOpen()
        }
    }

    private func chromeSlot(page: ChromePage) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DromeTheme.elevated)

                if let url = page.artURL {
                    RemoteImage(url: url, holdImageWhileLoading: true)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(page.title.isEmpty ? "Unknown Title" : page.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(page.artist)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 4)
    }

    /// Thin bottom progress track — read-only, like Spotify’s mini player.
    /// `TimelineView` interpolates between engine ticks so the fill glides.
    private var miniProgressHairline: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !clock.isPlaying)) { context in
            let progress = progressFraction(at: context.date)
            GeometryReader { geo in
                let width = max(0, geo.size.width)
                let filled = width * min(max(progress, 0), 1)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                    Rectangle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: filled)
                }
            }
        }
        .frame(height: 2)
        .opacity(clock.duration > 0 ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard !swipeAnimating else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 0.65 else { return }
                isDragging = true

                var limited = dx
                if dx < 0, !canSwipeNext {
                    limited = -rubberBand(-dx, limit: slotWidth * 0.28)
                } else if dx > 0, !canSwipePrevious {
                    limited = rubberBand(dx, limit: slotWidth * 0.28)
                }

                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) { dragX = limited }
            }
            .onEnded { value in
                guard !swipeAnimating else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                let predicted = value.predictedEndTranslation.width
                let threshold = min(48, slotWidth * 0.26)

                let goNext = abs(dx) > abs(dy) * 0.65
                    && (dx < -threshold || predicted < -threshold * 1.35)
                    && canSwipeNext
                let goPrev = abs(dx) > abs(dy) * 0.65
                    && (dx > threshold || predicted > threshold * 1.35)
                    && canSwipePrevious

                if goNext {
                    completeSwipe(goingNext: true)
                } else if goPrev {
                    completeSwipe(goingNext: false)
                } else {
                    withAnimation(.easeOut(duration: 0.22)) {
                        dragX = 0
                    }
                    isDragging = false
                }
            }
    }

    private func completeSwipe(goingNext: Bool) {
        guard chromePages.count == 3, !swipeAnimating else { return }
        let slot = max(slotWidth, 80)
        guard slot > 0 else { return }

        swipeAnimating = true
        swipeGeneration += 1
        let generation = swipeGeneration
        let exitX = goingNext ? -slot : slot

        let prev = chromePages[0]
        let current = chromePages[1]
        let next = chromePages[2]

        withAnimation(.easeInOut(duration: 0.26)) {
            dragX = exitX
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 270_000_000)
            guard generation == swipeGeneration else { return }

            // Neighbor is centered at exitX — rotate so that page stays on-center
            // at drag 0 before advancing playback (avoids a live-rebuild jump).
            let rotated: [ChromePage] = goingNext
                ? [current, next, ChromePage.placeholder(suffix: "next-pending")]
                : [ChromePage.placeholder(suffix: "prev-pending"), prev, current]

            var txn = Transaction(animation: nil)
            txn.disablesAnimations = true
            withTransaction(txn) {
                chromePages = rotated
                dragX = 0
            }

            let remote = session.connect?.isRemote == true
            if remote {
                Task {
                    await session.connect?.sendRemote(
                        goingNext ? ConnectCommandType.next : ConnectCommandType.previous)
                }
            } else {
                player.advanceFromArtSwipe(goingNext: goingNext)
            }
            guard generation == swipeGeneration else { return }

            var filled = chromePages
            if goingNext {
                filled[2] = makeNeighborPage(
                    song: player.artSwipeNextSong,
                    excluding: filled[1].id,
                    side: "next")
            } else {
                filled[0] = makeNeighborPage(
                    song: player.artSwipePreviousSong,
                    excluding: filled[1].id,
                    side: "prev")
            }
            withTransaction(txn) {
                chromePages = filled
            }
            ImageLoader.shared.prefetch(filled.compactMap(\.artURL))
            refreshWash(from: filled[1].artURL)

            swipeAnimating = false
            isDragging = false
        }
    }

    // MARK: - Pages

    private struct ChromePage: Equatable, Identifiable {
        var id: String
        var title: String
        var artist: String
        var artURL: URL?

        static func placeholder(suffix: String) -> ChromePage {
            ChromePage(id: "placeholder-\(suffix)", title: "", artist: "", artURL: nil)
        }

        var isPlaceholder: Bool { id.hasPrefix("placeholder") }
    }

    private var canSwipePrevious: Bool {
        guard chromePages.count == 3 else { return false }
        return !chromePages[0].isPlaceholder
    }

    private var canSwipeNext: Bool {
        guard chromePages.count == 3 else { return false }
        return !chromePages[2].isPlaceholder
    }

    private func makePages() -> [ChromePage] {
        let currentSong = player.current?.song
        let prevSong = player.artSwipePreviousSong
        let nextSong = player.artSwipeNextSong

        let prev: ChromePage = {
            if let prevSong, prevSong.id != currentSong?.id {
                return page(from: prevSong)
            }
            return .placeholder(suffix: "prev")
        }()
        let current: ChromePage = {
            if let currentSong {
                return page(from: currentSong)
            }
            return .placeholder(suffix: "current")
        }()
        let next: ChromePage = {
            if let nextSong, nextSong.id != currentSong?.id, nextSong.id != prevSong?.id {
                return page(from: nextSong)
            }
            return .placeholder(suffix: "next")
        }()

        let pages = [prev, current, next]
        ImageLoader.shared.prefetch(pages.compactMap(\.artURL))
        return pages
    }

    private func page(from song: Song) -> ChromePage {
        ChromePage(
            id: song.id,
            title: cleaned(song.title) ?? "Unknown Title",
            artist: displayArtist(for: song),
            artURL: session.artworkURL(for: song, size: 120)
        )
    }

    private func makeNeighborPage(song: Song?, excluding id: String, side: String) -> ChromePage {
        if let song, song.id != id {
            return page(from: song)
        }
        return .placeholder(suffix: side)
    }

    private func reloadPages(keepingDrag: Bool) {
        chromePages = makePages()
        if let url = chromePages.count == 3 ? chromePages[1].artURL : nil {
            refreshWash(from: url)
        }
        if !keepingDrag {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) { dragX = 0 }
        }
    }

    // MARK: - Helpers

    private func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        return (1 - (1 / ((value * 0.55 / limit) + 1))) * limit
    }

    private func refreshWash(from url: URL?) {
        guard let url else {
            withAnimation(.easeInOut(duration: 0.85)) {
                washColor = DromeTheme.accent
            }
            return
        }
        Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let image = UIImage(data: data),
                  let color = ArtworkPalette.dominantColor(from: image) else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.95)) {
                    washColor = color
                }
            }
        }
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func displayArtist(for song: Song) -> String {
        let artist = (song.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if artist.isEmpty { return "Unknown Artist" }
        return song.displayArtist.isEmpty ? artist : song.displayArtist
    }

    private var transportPlaying: Bool {
        if session.connect?.isRemote == true {
            return session.connect?.remoteSession?.isPlaying == true
        }
        return player.isPlaying
    }

    private func progressFraction(at date: Date) -> CGFloat {
        let total = clock.duration
        guard total.isFinite, total > 0 else { return 0 }
        return CGFloat(min(max(clock.displayElapsed(at: date) / total, 0), 1))
    }
}
