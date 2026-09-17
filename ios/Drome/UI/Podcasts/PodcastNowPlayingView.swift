import SwiftUI
import UIKit

/// Full-screen podcast Now Playing — same visual language as music `NowPlayingView`,
/// with podcast transport (15s back / 30s forward) and playback speed.
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

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let width = Self.finiteSize(geo.size.width)
                let height = Self.finiteSize(geo.size.height)
                let chromeReserve: CGFloat = 100
                let paneHeight = max(0, height - chromeReserve)

                ZStack {
                    background
                        .frame(width: width, height: height)
                        .clipped()

                    VStack(spacing: 0) {
                        dismissChrome(width: width)
                            .modifier(PodcastDismissGesture(
                                enabled: !isDismissClosing && !showSpeedPicker,
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
                enabled: !isDismissClosing && !showSpeedPicker,
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
            .preferredColorScheme(.dark)
            .background(Color.clear)
        }
        .offset(y: dismissY)
        .transaction { txn in
            if isDismissDragging && !isDismissClosing { txn.animation = nil }
        }
    }

    // MARK: - Chrome

    private func dismissChrome(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())

            Text(headerSubtitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
                .frame(height: 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var headerSubtitle: String {
        if let show = currentShow {
            return "Playing from \(show.title)"
        }
        return "Podcast"
    }

    private var currentShow: PodcastShow? {
        guard let episode = podcastPlayer.currentEpisode else { return nil }
        return podcastManager.subscribedShows.first(where: { $0.feedURL == episode.showID })
    }

    // MARK: - Background

    private var background: some View {
        NowPlayingBackdrop.Body(
            front: backdropFront,
            back: backdropBack,
            frontOpacity: backdropFrontOpacity
        )
        .onAppear { syncBackground(animated: false) }
        .onChange(of: podcastPlayer.currentEpisode?.imageURL?.absoluteString) { _, _ in
            syncBackground(animated: true)
        }
    }

    private func syncBackground(animated: Bool) {
        let nextURL = podcastPlayer.currentEpisode?.imageURL
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
        let horizontalPad: CGFloat = 24
        let contentWidth = max(0, width - horizontalPad * 2)
        let screenH = UIScreen.main.bounds.height
        let estimatedPane = max(400, (screenH.isFinite ? screenH : 800) - 220)
        let artSide = min(contentWidth, max(180, estimatedPane * 0.38))
        let paneHeight = max(0, height)

        return VStack(spacing: 0) {
            Spacer(minLength: 4)

            coverCard(url: podcastPlayer.currentEpisode?.imageURL, side: artSide)

            Spacer(minLength: 16)

            metadataBlock
                .frame(width: contentWidth, alignment: .leading)
                .id(podcastPlayer.currentEpisode?.id)

            Spacer(minLength: 16)

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
        .frame(width: max(0, width), height: paneHeight)
    }

    private func coverCard(url: URL?, side: CGFloat) -> some View {
        let safeSide = Self.finiteSize(side)
        return RemoteImage(url: url, holdImageWhileLoading: true)
            .frame(width: safeSide, height: safeSide)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
    }

    private var metadataBlock: some View {
        let episode = podcastPlayer.currentEpisode
        let title = cleaned(episode?.title) ?? "Episode"
        let showName = cleaned(currentShow?.title) ?? "Podcast"
        let titleLineHeight = UIFont.preferredFont(forTextStyle: .title3).lineHeight + 2

        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: titleLineHeight, alignment: .leading)

            Text(showName)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)

            if let episode, let date = episode.pubDate {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DromeTheme.accent.opacity(0.95))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 56, alignment: .topLeading)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
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

        return VStack(spacing: 8) {
            GeometryReader { geo in
                let width = max(0, geo.size.width)
                let fill = max(0, min(width, width * fraction))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(height: 6)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(6, fill), height: 6)
                    // Vertical playhead — podcast scrubber language vs music Slider knob.
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 3, height: 16)
                        .offset(x: max(0, fill - 1.5))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
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
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                isSeeking = false
                            }
                        }
                )
            }
            .frame(height: 28)

            HStack {
                Text(Formatters.playbackTime(displayed))
                    .frame(minWidth: 40, alignment: .leading)
                Spacer()
                Text(remainingLabel(displayed: displayed, total: total))
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.7))
        }
        .frame(height: 52)
    }

    private func remainingLabel(displayed: Double, total: Double) -> String {
        guard total > 0 else { return Formatters.playbackTime(0) }
        let left = max(0, total - displayed)
        return "-\(Formatters.playbackTime(left))"
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
                                     ? Color.white.opacity(0.45)
                                     : DromeTheme.accent)
                    .frame(width: 48, height: 44)
            }
            .accessibilityLabel("Playback speed \(speedLabel(podcastPlayer.playbackSpeed))")

            Spacer(minLength: 0)

            Button {
                podcastPlayer.skipBackward(seconds: 15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }

            Button {
                podcastPlayer.playPause()
            } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                    Image(systemName: podcastPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 62, height: 62)
                }
            }
            .buttonStyle(PodcastScaleButtonStyle())

            Button {
                podcastPlayer.skipForward(seconds: 30)
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }

            Spacer(minLength: 0)

            Button {
                podcastPlayer.cycleSpeed()
                flash(speedLabel(podcastPlayer.playbackSpeed))
            } label: {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(podcastPlayer.playbackSpeed == 1.0
                                     ? Color.white.opacity(0.45)
                                     : DromeTheme.accent)
                    .frame(width: 48, height: 44)
            }
            .accessibilityLabel("Cycle playback speed")
        }
        .frame(height: 68)
    }

    private var bottomBar: some View {
        HStack {
            if let episode = podcastPlayer.currentEpisode {
                let remaining = max(0, stableDuration - podcastPlayer.elapsed)
                Text(remaining > 0
                      ? "\(Formatters.playbackTime(remaining)) left"
                      : episode.durationText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            Spacer()

            if let message = podcastPlayer.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .frame(height: 44)
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
