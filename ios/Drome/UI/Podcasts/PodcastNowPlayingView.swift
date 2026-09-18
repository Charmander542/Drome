import SwiftUI
import UIKit

/// Full-screen podcast Now Playing.
/// Progress is remaining-first (one time story) — inspired by Spotify’s long-form
/// center remaining, without stacking elapsed + −remaining + “X left”.
struct PodcastNowPlayingView: View {
    @EnvironmentObject private var podcastPlayer: PodcastPlayer
    @EnvironmentObject private var podcastManager: PodcastManager
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil

    @State private var isSeeking = false
    @State private var seekElapsed: Double = 0
    @State private var dismissY: CGFloat = 0
    @State private var isDismissDragging = false
    @State private var isDismissClosing = false
    @State private var sheetHeight: CGFloat = 800
    @State private var flashMessage: String?
    @State private var backdropFront = NowPlayingBackdrop.Layer()
    @State private var backdropBack = NowPlayingBackdrop.Layer()
    @State private var backdropFrontOpacity: Double = 1
    @State private var backdropGeneration = 0
    @State private var showSpeedPicker = false
    /// When true, show classic elapsed under the playhead while seeking / after tap.
    @State private var showPreciseTime = false
    @State private var showChapters = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let width = Self.finiteSize(geo.size.width)
                let height = Self.finiteSize(geo.size.height)
                let chromeReserve: CGFloat = 88
                let paneHeight = max(0, height - chromeReserve)

                ZStack {
                    background
                        .frame(width: width, height: height)
                        .clipped()

                    VStack(spacing: 0) {
                        dismissChrome
                            .modifier(PodcastDismissGesture(
                                enabled: !isDismissClosing && !showSpeedPicker && !showChapters,
                                gesture: dismissGesture))

                        episodePane(width: width, height: paneHeight)
                            .frame(width: width)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: width, height: height)
                }
                .frame(width: width, height: height)
                .onAppear {
                    if height > 0 { sheetHeight = height }
                }
                .onChange(of: height) { _, h in
                    if h > 0 { sheetHeight = height }
                }
            }
            .modifier(PodcastDismissGesture(
                enabled: !isDismissClosing && !showSpeedPicker && !showChapters,
                gesture: dismissGesture))
            .ignoresSafeArea(edges: .bottom)
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .containerBackground(.clear, for: .navigation)
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
            .animation(.easeInOut(duration: 0.2), value: flashMessage)
            .confirmationDialog("Playback speed", isPresented: $showSpeedPicker, titleVisibility: .visible) {
                ForEach(PodcastPlayer.speedPresets, id: \.self) { speed in
                    Button(speedLabel(speed)) {
                        podcastPlayer.setSpeed(speed)
                        flash(speedLabel(speed))
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showChapters) {
                chaptersSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .preferredColorScheme(.dark)
            }
            .preferredColorScheme(.dark)
            .background(Color.clear)
        }
        .offset(y: dismissY)
        .transaction { txn in
            if isDismissDragging && !isDismissClosing { txn.animation = nil }
        }
    }

    // MARK: - Chrome

    private var dismissChrome: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())

            Text(headerSubtitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.65))
                .lineLimit(1)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var headerSubtitle: String {
        if let show = currentShow {
            return show.title
        }
        return "Podcast"
    }

    private var currentShow: PodcastShow? {
        guard let episode = podcastPlayer.currentEpisode else { return nil }
        return podcastManager.subscribedShows.first(where: { $0.feedURL == episode.showID })
    }

    private var artworkURL: URL? {
        currentShow?.imageURL ?? podcastPlayer.currentEpisode?.imageURL
    }

    private var episodeIsStarred: Bool {
        guard let episode = podcastPlayer.currentEpisode else { return false }
        return episode.isStarred || podcastManager.isStarred(episode)
    }

    // MARK: - Background

    private var background: some View {
        NowPlayingBackdrop.Body(
            front: backdropFront,
            back: backdropBack,
            frontOpacity: backdropFrontOpacity
        )
        .onAppear { syncBackground(animated: false) }
        .onChange(of: artworkURL?.absoluteString) { _, _ in
            syncBackground(animated: true)
        }
    }

    private func syncBackground(animated: Bool) {
        let nextURL = artworkURL
        guard nextURL != backdropFront.url else { return }

        backdropGeneration += 1
        let generation = backdropGeneration

        Task { @MainActor in
            let wash = await NowPlayingBackdrop.washColor(for: nextURL)
            guard generation == backdropGeneration else { return }

            if !animated || backdropFront.url == nil {
                backdropBack = .init()
                backdropFront = .init(url: nextURL, wash: wash)
                backdropFrontOpacity = 1
                return
            }

            backdropBack = backdropFront
            backdropFront = .init(url: nextURL, wash: wash)
            backdropFrontOpacity = 0
            withAnimation(.easeInOut(duration: 0.85)) {
                backdropFrontOpacity = 1
            }
        }
    }

    // MARK: - Episode pane

    private func episodePane(width: CGFloat, height: CGFloat) -> some View {
        let horizontalPad: CGFloat = 28
        let contentWidth = max(0, width - horizontalPad * 2)
        let screenH = UIScreen.main.bounds.height
        let estimatedPane = max(400, (screenH.isFinite ? screenH : 800) - 200)
        let artSide = min(contentWidth, max(200, estimatedPane * 0.42))
        let paneHeight = max(0, height)

        return VStack(spacing: 0) {
            Spacer(minLength: 8)

            coverCard(url: artworkURL, side: artSide)

            Spacer(minLength: 20)

            metadataBlock
                .frame(width: contentWidth, alignment: .leading)
                .id(podcastPlayer.currentEpisode?.id)

            Spacer(minLength: 22)

            progressBlock
                .frame(width: contentWidth)

            Spacer(minLength: 18)

            transport
                .frame(width: contentWidth)
                .padding(.bottom, 28)
        }
        .frame(width: max(0, width), height: paneHeight)
        .overlay(alignment: .bottom) {
            if let message = podcastPlayer.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
    }

    private func coverCard(url: URL?, side: CGFloat) -> some View {
        let safeSide = Self.finiteSize(side)
        return RemoteImage(url: url, holdImageWhileLoading: true)
            .frame(width: safeSide, height: safeSide)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }

    private var metadataBlock: some View {
        let episode = podcastPlayer.currentEpisode
        let title = cleaned(episode?.title) ?? "Episode"
        let showName = cleaned(currentShow?.title) ?? "Podcast"

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(showName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)

                if let date = episode?.pubDate {
                    Text("·")
                        .foregroundStyle(Color.white.opacity(0.35))
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            if let chapter = podcastPlayer.currentChapter, podcastPlayer.chapters.count >= 2 {
                Text(chapter.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DromeTheme.accent.opacity(0.95))
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Progress (one time story)

    private var progressBlock: some View {
        let total = stableDuration
        let rawElapsed = podcastPlayer.elapsed.isFinite ? podcastPlayer.elapsed : 0
        let live = min(max(0, rawElapsed), total)
        let displayed: Double = {
            if isSeeking {
                return seekElapsed.isFinite ? min(max(0, seekElapsed), total) : live
            }
            return live
        }()
        let fraction = total > 0 ? displayed / total : 0
        let remaining = max(0, total - displayed)
        let percent = Int((fraction * 100).rounded(.down))

        return VStack(spacing: 10) {
            GeometryReader { geo in
                let width = max(0, geo.size.width)
                let fill = max(0, min(width, width * fraction))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 5)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(5, fill), height: 5)

                    // Chapter markers along the scrubber.
                    if total > 1 {
                        ForEach(podcastPlayer.chapters.dropFirst()) { chapter in
                            let x = CGFloat(chapter.startTime / total) * width
                            Capsule()
                                .fill(Color.white.opacity(0.55))
                                .frame(width: 2, height: 10)
                                .offset(x: max(0, min(width - 2, x - 1)))
                        }
                    }

                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: max(0, fill - 7))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            let x = min(max(0, value.location.x), width)
                            seekElapsed = (x / width) * total
                            if !isSeeking { isSeeking = true }
                        }
                        .onEnded { value in
                            guard width > 0 else { return }
                            let x = min(max(0, value.location.x), width)
                            let target = (x / width) * total
                            seekElapsed = target
                            podcastPlayer.seek(to: target)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                isSeeking = false
                            }
                        }
                )
            }
            .frame(height: 28)

            // Single primary readout — remaining in human words.
            // Tap toggles a precise elapsed peek (for scrubbing).
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    showPreciseTime.toggle()
                }
            } label: {
                VStack(spacing: 3) {
                    if isSeeking || showPreciseTime {
                        Text(Formatters.playbackTime(displayed))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    Text(friendlyRemaining(remaining))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    if total > 1 {
                        Text("\(percent)% through")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(friendlyRemaining(remaining)), \(percent) percent through. Tap for exact time.")

            if podcastPlayer.chapters.count >= 2 {
                Button {
                    showChapters = true
                } label: {
                    Label("\(podcastPlayer.chapters.count) chapters", systemImage: "list.bullet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private func friendlyRemaining(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(max(1, s)) sec left" }
        let minutes = (s + 30) / 60
        if minutes < 60 { return "\(minutes) min left" }
        let hours = minutes / 60
        let remMins = minutes % 60
        if remMins == 0 { return "\(hours) hr left" }
        return "\(hours) hr \(remMins) min left"
    }

    // MARK: - Transport

    private var transport: some View {
        HStack {
            Button {
                showSpeedPicker = true
            } label: {
                Text(speedLabel(podcastPlayer.playbackSpeed))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(podcastPlayer.playbackSpeed == 1.0
                                     ? Color.white.opacity(0.5)
                                     : DromeTheme.accent)
                    .frame(width: 48, height: 44)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(podcastPlayer.playbackSpeed == 1.0 ? 0.08 : 0.14))
                    )
            }
            .accessibilityLabel("Playback speed \(speedLabel(podcastPlayer.playbackSpeed))")

            Spacer(minLength: 0)

            Button {
                podcastPlayer.skipBackward(seconds: 15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }

            Button {
                podcastPlayer.playPause()
            } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 68, height: 68)
                    Image(systemName: podcastPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.black)
                        .offset(x: podcastPlayer.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(PodcastScaleButtonStyle())

            Button {
                podcastPlayer.skipForward(seconds: 30)
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }

            Spacer(minLength: 0)

            Button {
                toggleStar()
            } label: {
                Image(systemName: episodeIsStarred ? "star.fill" : "star")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(episodeIsStarred ? DromeTheme.accent : Color.white.opacity(0.55))
                    .frame(width: 48, height: 44)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .accessibilityLabel(episodeIsStarred ? "Remove star" : "Star episode")
        }
        .frame(height: 72)
    }

    private var chaptersSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(podcastPlayer.chapters.enumerated()), id: \.element.id) { index, chapter in
                    let isCurrent = PodcastChapterResolver.currentIndex(
                        in: podcastPlayer.chapters,
                        at: podcastPlayer.elapsed) == index
                    Button {
                        podcastPlayer.seek(to: chapter.startTime)
                        showChapters = false
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chapter.title)
                                    .font(.body.weight(isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? DromeTheme.accent : .primary)
                                    .multilineTextAlignment(.leading)
                                Text(chapter.startTimeText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if isCurrent {
                                Image(systemName: "waveform")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(DromeTheme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Chapters")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showChapters = false }
                }
            }
        }
    }

    private func toggleStar() {
        guard var episode = podcastPlayer.currentEpisode else { return }
        let next = podcastManager.toggleStar(episode)
        episode.isStarred = next
        podcastPlayer.currentEpisode = episode
        flash(next ? "Starred" : "Removed star")
    }

    // MARK: - Dismiss

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .onChanged { value in
                guard !isDismissClosing else { return }
                let dy = value.translation.height
                let dx = value.translation.width
                if !isDismissDragging {
                    guard dy > 14, dy >= abs(dx) else { return }
                    isDismissDragging = true
                }
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) {
                    dismissY = max(0, dy)
                }
            }
            .onEnded { value in
                guard !isDismissClosing else { return }
                finishDismiss(
                    translation: value.translation.height,
                    predicted: value.predictedEndTranslation.height)
            }
    }

    private func finishDismiss(translation: CGFloat, predicted: CGFloat) {
        guard !isDismissClosing else { return }
        let y = max(0, translation)
        let threshold = min(160, max(sheetHeight, 1) * 0.18)
        let flicked = predicted > threshold * 1.55 && y > 28
        if y > threshold || flicked {
            isDismissClosing = true
            isDismissDragging = false
            withAnimation(.easeIn(duration: 0.2)) {
                dismissY = sheetHeight + 40
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
            }
        } else {
            isDismissDragging = false
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                dismissY = 0
            }
        }
    }

    // MARK: - Helpers

    private var stableDuration: Double {
        let live = podcastPlayer.duration
        if live.isFinite, live > 0.5 { return live }
        if let meta = podcastPlayer.currentEpisode?.duration, meta > 0 {
            return meta
        }
        return 0.1
    }

    private func speedLabel(_ speed: Double) -> String {
        if speed == 1.0 { return "1x" }
        if speed == floor(speed) { return String(format: "%.0fx", speed) }
        return String(format: "%gx", speed)
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

    private static func finiteSize(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}

private struct PodcastDismissGesture<G: Gesture>: ViewModifier {
    let enabled: Bool
    let gesture: G

    func body(content: Content) -> some View {
        content.simultaneousGesture(gesture, including: enabled ? .all : .none)
    }
}

private struct PodcastScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
