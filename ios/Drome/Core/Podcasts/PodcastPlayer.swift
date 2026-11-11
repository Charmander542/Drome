import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Dedicated podcast playback engine.
///
/// Uses a single AVPlayer with buffered start (same pattern as music) so remote
/// enclosures don't trip FigFilePlayer (-12864). Pauses music when a podcast
/// starts, and loads Now Playing artwork asynchronously.
@MainActor
final class PodcastPlayer: ObservableObject {
    // MARK: Published state

    @Published var currentEpisode: PodcastEpisode?
    @Published var isPlaying = false
    @Published var elapsed: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var chapters: [PodcastChapter] = []
    @Published var playbackSpeed: Double = 1.0 {
        didSet {
            if isPlaying { player.rate = Float(playbackSpeed) }
            UserDefaults.standard.set(playbackSpeed, forKey: "podcast.playbackSpeed")
        }
    }

    /// Active chapter for the current playhead (if chapters are available).
    var currentChapter: PodcastChapter? {
        guard let idx = PodcastChapterResolver.currentIndex(in: chapters, at: elapsed),
              chapters.indices.contains(idx) else { return nil }
        return chapters[idx]
    }

    /// Called before podcast audio starts so music can yield the session.
    var onWillStartPlayback: (() -> Void)?
    /// Refresh the show feed and return an updated episode (fresh enclosure URL).
    /// Used when the cached audio URL 404s after CDN / tracking redirects expire.
    var onRefreshEpisode: ((PodcastEpisode) async -> PodcastEpisode?)?

    // MARK: Private state

    /// Captured across AVAudioSession interruptions so only the engine that
    /// was actually playing resumes after Bluetooth connect/disconnect.
    private var resumeAfterInterruption = false
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    private var itemReadyCancellable: AnyCancellable?
    private var itemReadyTimeout: Task<Void, Never>?
    private var playGeneration = 0
    private var wantsToPlay = false
    private var pendingSeek: TimeInterval?
    private var didAttemptFreshURL = false
    private let nowPlaying = PodcastNowPlayingCenter()
    private let store: PodcastStore?

    static let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    /// Prefer Apple's public UA key + CoreMedia-like string. The old private
    /// `AVURLAssetHTTPHeaderFieldsKey` broke Podtrac/Art19 redirect chains and
    /// surfaced as "The requested URL was not found on this server".
    private static let userAgent =
        "AppleCoreMedia/1.0.0 (Drome; like iPhone; podcast)"

    init(store: PodcastStore? = nil) {
        self.store = store
        // Critical for HTTP enclosures — don't force play into an empty buffer.
        player.automaticallyWaitsToMinimizeStalling = true
        playbackSpeed = UserDefaults.standard.object(forKey: "podcast.playbackSpeed") as? Double ?? 1.0
        setupObservers()
        setupRemoteNotificationHandlers()
    }

    // MARK: Playback

    func play(_ episode: PodcastEpisode, resumeFromSaved: Bool = true) {
        guard episode.audioURL.scheme == "http" || episode.audioURL.scheme == "https" else {
            errorMessage = "This episode has no playable stream URL"
            return
        }

        playGeneration += 1
        let generation = playGeneration
        itemReadyCancellable?.cancel()
        itemReadyTimeout?.cancel()
        itemStatusObserver?.invalidate()
        didAttemptFreshURL = false

        let startPosition: TimeInterval = {
            if resumeFromSaved, let store {
                return (try? store.playbackPosition(episodeID: episode.id, showFeedURL: episode.showID)) ?? 0
            }
            return 0
        }()

        // Yield the shared audio session to podcasts.
        AudioFocus.shared.claim(.podcast)
        onWillStartPlayback?()
        activateAudioSession()

        currentEpisode = episode
        chapters = episode.chapters.filter(\.toc).sorted { $0.startTime < $1.startTime }
        errorMessage = nil
        elapsed = 0
        duration = episode.duration ?? 0
        wantsToPlay = true
        resumeAfterInterruption = false
        pendingSeek = startPosition > 1 ? startPosition : nil
        DromeDiagnostics.logPodcast(
            "play «\(episode.title)» resume=\(Int(startPosition))s gen=\(generation)")

        // Resolve tracking redirects first so AVPlayer gets a stable media URL.
        // Podtrac / Spotify prefix / Art19 chains often 404 when AVPlayer follows
        // them with private header overrides.
        Task { @MainActor [weak self] in
            guard let self, generation == self.playGeneration else { return }
            let resolved = await Self.resolvePlayableURL(episode.audioURL) ?? episode.audioURL
            guard generation == self.playGeneration else { return }
            DromeDiagnostics.logPodcast("stream \(resolved.host ?? "?")…")
            self.startItem(url: resolved, episode: episode, generation: generation, startPosition: startPosition)
        }
        Task { await self.resolveChapters(for: episode, generation: generation) }
    }

    private func startItem(
        url: URL,
        episode: PodcastEpisode,
        generation: Int,
        startPosition: TimeInterval
    ) {
        let item = makePlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.playGeneration else { return }
                if item.status == .failed {
                    await self.handleItemFailure(
                        item.error,
                        episode: episode,
                        generation: generation,
                        startPosition: startPosition)
                }
            }
        }

        updateNowPlaying(for: episode, startPosition: startPosition, rate: 0)
        waitUntilReadyThenPlay(item, generation: generation)
    }

    private func handleItemFailure(
        _ error: Error?,
        episode: PodcastEpisode,
        generation: Int,
        startPosition: TimeInterval
    ) async {
        let message = error?.localizedDescription ?? "Couldn't play this episode"
        DromeDiagnostics.logPodcast("item failed: \(message)")

        // One automatic recovery: refresh the feed for a fresh enclosure URL.
        if !didAttemptFreshURL, let onRefreshEpisode {
            didAttemptFreshURL = true
            errorMessage = "Refreshing episode link…"
            if let fresh = await onRefreshEpisode(episode),
               generation == playGeneration {
                let urlChanged = fresh.audioURL != episode.audioURL
                DromeDiagnostics.logPodcast(
                    "retry after refresh urlChanged=\(urlChanged)")
                currentEpisode = fresh
                let resolved = await Self.resolvePlayableURL(fresh.audioURL) ?? fresh.audioURL
                guard generation == playGeneration else { return }
                errorMessage = nil
                wantsToPlay = true
                pendingSeek = startPosition > 1 ? startPosition : pendingSeek
                startItem(
                    url: resolved,
                    episode: fresh,
                    generation: generation,
                    startPosition: startPosition)
                return
            }
        }

        errorMessage = Self.friendlyError(message)
        wantsToPlay = false
        isPlaying = false
    }

    private static func friendlyError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("not found") || lower.contains("404") {
            return "Episode audio link expired — pull to refresh the show and try again"
        }
        return raw
    }

    /// Follow redirects with URLSession so AVPlayer doesn't have to walk the
    /// tracking chain (Podtrac → pdst → vpixl → CDN) itself.
    private static func resolvePlayableURL(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        if let resolved = await performResolve(request) {
            return resolved
        }
        // Some CDNs reject HEAD — fall back to a ranged GET.
        var get = request
        get.httpMethod = "GET"
        get.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        return await performResolve(get)
    }

    private static func performResolve(_ request: URLRequest) async -> URL? {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard let final = http.url else { return nil }
            // Accept 2xx and 3xx-followed finals; reject obvious HTML error pages.
            if (200...399).contains(http.statusCode) {
                let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                if type.contains("text/html") { return nil }
                return final
            }
            return nil
        } catch {
            DromeDiagnostics.logPodcast("resolve failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func resolveChapters(for episode: PodcastEpisode, generation: Int) async {
        let resolved = await PodcastChapterResolver.resolve(for: episode)
        guard generation == playGeneration else { return }
        chapters = resolved
        if var current = currentEpisode, current.id == episode.id {
            current.chapters = resolved
            currentEpisode = current
            // Persist so the next open is instant.
            if !resolved.isEmpty {
                try? store?.updateChapters(
                    episodeID: episode.id,
                    showFeedURL: episode.showID,
                    chaptersURL: episode.chaptersURL,
                    chapters: resolved)
            }
        }
    }

    func playPause() {
        if wantsToPlay || isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard currentEpisode != nil else { return }
        AudioFocus.shared.claim(.podcast)
        onWillStartPlayback?()
        activateAudioSession()
        wantsToPlay = true
        resumeAfterInterruption = false
        if let item = player.currentItem, item.status == .readyToPlay {
            player.play()
            player.rate = Float(playbackSpeed)
        } else if let episode = currentEpisode {
            // Reload if the previous item failed.
            play(episode, resumeFromSaved: true)
        }
    }

    func pause() {
        wantsToPlay = false
        resumeAfterInterruption = false
        player.pause()
        isPlaying = false
        saveCurrentPosition()
        if let episode = currentEpisode {
            updateNowPlaying(for: episode, startPosition: elapsed, rate: 0)
        }
    }

    func seek(to time: TimeInterval) {
        let total = duration > 0 ? duration : (player.currentItem.flatMap { CMTimeGetSecondsIfFinite($0.duration) } ?? 0)
        let target = max(0, total > 0 ? min(time, total) : time)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
        elapsed = target
    }

    func skipForward(seconds: TimeInterval = 30) {
        seek(to: elapsed + seconds)
    }

    func skipBackward(seconds: TimeInterval = 30) {
        seek(to: elapsed - seconds)
    }

    func stop() {
        playGeneration += 1
        itemReadyCancellable?.cancel()
        itemReadyTimeout?.cancel()
        saveCurrentPosition()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentEpisode = nil
        chapters = []
        isPlaying = false
        wantsToPlay = false
        resumeAfterInterruption = false
        elapsed = 0
        duration = 0
        pendingSeek = nil
        AudioFocus.shared.release(.podcast)
        // Episode is gone — don't sticky-block music remote Play.
        AudioFocus.shared.forgetLastOwner(.podcast)
        nowPlaying.clearNowPlaying()
        DromeDiagnostics.logPodcast("stopped")
    }

    /// Seeds mini-player / now-playing chrome without starting AVPlayer.
    /// Used by `-UITestPodcastMini` launch argument for simulator screenshots.
    func adoptEpisodeForChrome(
        _ episode: PodcastEpisode,
        elapsed: TimeInterval = 0,
        duration: TimeInterval = 0,
        playing: Bool = false
    ) {
        currentEpisode = episode
        self.elapsed = elapsed
        self.duration = duration > 0 ? duration : (episode.duration ?? 0)
        isPlaying = playing
        wantsToPlay = playing
        errorMessage = nil
    }

    // MARK: Speed

    func cycleSpeed() {
        guard let currentIndex = Self.speedPresets.firstIndex(of: playbackSpeed) else {
            playbackSpeed = 1.0
            return
        }
        playbackSpeed = Self.speedPresets[(currentIndex + 1) % Self.speedPresets.count]
    }

    func setSpeed(_ speed: Double) {
        playbackSpeed = speed
    }

    // MARK: Item creation

    private func makePlayerItem(url: URL) -> AVPlayerItem {
        // Use the public UA key only — never AVURLAssetHTTPHeaderFieldsKey.
        // That private API drops/breaks headers across podcast CDN redirects
        // and commonly returns Apache "URL was not found" HTML to AVPlayer.
        var options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ]
        if #available(iOS 16.0, tvOS 16.0, *) {
            options[AVURLAssetHTTPUserAgentKey] = Self.userAgent
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 25
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
    }

    private func waitUntilReadyThenPlay(_ item: AVPlayerItem, generation: Int) {
        itemReadyCancellable?.cancel()
        itemReadyTimeout?.cancel()

        let startIfReady = { [weak self] in
            guard let self, generation == self.playGeneration, item === self.player.currentItem else { return }
            guard self.wantsToPlay else { return }
            if item.status == .failed { return }

            if let seekTo = self.pendingSeek {
                self.pendingSeek = nil
                self.player.seek(
                    to: CMTime(seconds: seekTo, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { [weak self] finished in
                    Task { @MainActor in
                        guard let self, generation == self.playGeneration, finished, self.wantsToPlay else { return }
                        self.player.play()
                        self.player.rate = Float(self.playbackSpeed)
                    }
                }
            } else {
                self.player.play()
                self.player.rate = Float(self.playbackSpeed)
            }
        }

        if item.status == .readyToPlay {
            startIfReady()
            return
        }

        itemReadyTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, generation == self.playGeneration, item === self.player.currentItem else { return }
                self.itemReadyCancellable = nil
                if item.status != .failed, self.wantsToPlay {
                    startIfReady()
                }
            }
        }

        itemReadyCancellable = Publishers.Merge3(
            item.publisher(for: \.status).map { _ in () },
            item.publisher(for: \.isPlaybackLikelyToKeepUp).map { _ in () },
            item.publisher(for: \.loadedTimeRanges).map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self, generation == self.playGeneration, item === self.player.currentItem else { return }
            if item.status == .failed {
                self.itemReadyTimeout?.cancel()
                self.itemReadyCancellable = nil
                return
            }
            let buffered = !item.isPlaybackBufferEmpty || item.isPlaybackLikelyToKeepUp
            if item.status == .readyToPlay && buffered {
                self.itemReadyTimeout?.cancel()
                self.itemReadyCancellable = nil
                startIfReady()
            }
        }
    }

    // MARK: Observers

    private func setupObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite { self.elapsed = seconds }
                if let currentItem = self.player.currentItem,
                   let dur = CMTimeGetSecondsIfFinite(currentItem.duration), dur > 0 {
                    self.duration = dur
                }
                if self.elapsed.isFinite, self.duration.isFinite, self.duration > 0 {
                    self.nowPlaying.updateElapsedTime(self.elapsed, duration: self.duration, rate: self.player.rate)
                }
            }
        }

        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            let newRate = change.newValue ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                let playing = newRate > 0.01
                if self.isPlaying != playing {
                    self.isPlaying = playing
                    if !playing, !self.wantsToPlay {
                        self.saveCurrentPosition()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, let ended = note.object as? AVPlayerItem,
                      ended === self.player.currentItem else { return }
                self.handleEpisodeEnd()
            }
        }

        #if !os(tvOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleInterruption(note)
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(note)
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self,
                      let stalled = note.object as? AVPlayerItem,
                      stalled === self.player.currentItem,
                      self.wantsToPlay else { return }
                DromeDiagnostics.logPodcast("stalled → soft seek")
                let pos = self.elapsed
                self.seek(to: pos)
                self.player.play()
                self.player.rate = Float(self.playbackSpeed)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .dromeNetworkPathChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self,
                      (note.userInfo?["regained"] as? Bool) == true,
                      self.wantsToPlay,
                      self.currentEpisode != nil,
                      AudioFocus.shared.isOwner(.podcast) else { return }
                DromeDiagnostics.logPodcast("network regained → resume")
                self.activateAudioSession()
                self.player.play()
                self.player.rate = Float(self.playbackSpeed)
            }
        }
        #endif
    }

    private func setupRemoteNotificationHandlers() {
        NotificationCenter.default.addObserver(
            forName: .podcastPlayerResume, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
        NotificationCenter.default.addObserver(
            forName: .podcastPlayerPause, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
        NotificationCenter.default.addObserver(
            forName: .podcastPlayerSkipForward, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.skipForward() }
        }
        NotificationCenter.default.addObserver(
            forName: .podcastPlayerSkipBackward, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }
        }
        NotificationCenter.default.addObserver(
            forName: .podcastPlayerToggle, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.playPause() }
        }
    }

    #if !os(tvOS)
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // Capture intent before pause() clears wantsToPlay.
            resumeAfterInterruption = wantsToPlay || isPlaying
            DromeDiagnostics.logPodcast("interruption began resumeAfter=\(resumeAfterInterruption)")
            if resumeAfterInterruption {
                wantsToPlay = false
                player.pause()
                isPlaying = false
                saveCurrentPosition()
                if let episode = currentEpisode {
                    updateNowPlaying(for: episode, startPosition: elapsed, rate: 0)
                }
            }
        case .ended:
            let shouldResume = {
                if let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    return AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
                }
                return false
            }()
            let canResume = resumeAfterInterruption
                && shouldResume
                && AudioFocus.shared.isOwner(.podcast)
                && currentEpisode != nil
            resumeAfterInterruption = false
            DromeDiagnostics.logPodcast("interruption ended canResume=\(canResume)")
            if canResume {
                resume()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
            .flatMap(AVAudioSession.RouteChangeReason.init)
        // Car Bluetooth unplug / route loss — stay paused; do not auto-resume
        // when a new device appears (that path races with interruptions).
        if reason == .oldDeviceUnavailable {
            resumeAfterInterruption = false
            if wantsToPlay || isPlaying {
                pause()
            }
        }
    }
    #endif

    private func handleEpisodeEnd() {
        guard let episode = currentEpisode else { return }
        wantsToPlay = false
        isPlaying = false
        try? store?.savePlaybackPosition(
            episodeID: episode.id,
            showFeedURL: episode.showID,
            position: duration,
            completed: true
        )
    }

    private func saveCurrentPosition() {
        guard let episode = currentEpisode else { return }
        let position = elapsed.isFinite ? elapsed : 0
        let completed = duration > 0 && position >= duration * 0.95
        try? store?.savePlaybackPosition(
            episodeID: episode.id,
            showFeedURL: episode.showID,
            position: position,
            completed: completed
        )
    }

    // MARK: Audio Session

    private func activateAudioSession() {
        #if !os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("[PodcastPlayer] audio session error: \(error)")
        }
        #endif
    }

    // MARK: Now Playing

    private func updateNowPlaying(for episode: PodcastEpisode, startPosition: TimeInterval, rate: Float) {
        guard AudioFocus.shared.isOwner(.podcast) else { return }
        nowPlaying.updateNowPlaying(
            episode: episode,
            duration: duration > 0 ? duration : (episode.duration ?? 0),
            position: startPosition,
            speed: Double(rate == 0 ? 0 : playbackSpeed)
        )
    }
}

// MARK: - Podcast Now Playing Center

@MainActor
private final class PodcastNowPlayingCenter {
    private var artworkTask: Task<Void, Never>?

    func updateNowPlaying(episode: PodcastEpisode, duration: TimeInterval, position: TimeInterval, speed: Double) {
        #if !os(tvOS)
        guard AudioFocus.shared.isOwner(.podcast) else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = episode.title
        info[MPMediaItemPropertyAlbumTitle] = "Podcast"
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = speed
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        setupRemoteCommands()
        AudioFocus.shared.applyRemoteCommandSurface()

        artworkTask?.cancel()
        guard let imageURL = episode.imageURL,
              let scheme = imageURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }

        let episodeID = episode.id
        artworkTask = Task.detached(priority: .utility) {
            var request = URLRequest(url: imageURL)
            request.setValue("Drome/1.0 (Podcast; iOS)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard AudioFocus.shared.isOwner(.podcast) else { return }
                guard var current = MPNowPlayingInfoCenter.default().nowPlayingInfo,
                      current[MPMediaItemPropertyTitle] as? String != nil else { return }
                // Drop stale art if focus already moved on.
                _ = episodeID
                current[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
        #endif
    }

    func updateElapsedTime(_ elapsed: TimeInterval, duration: TimeInterval, rate: Float) {
        #if !os(tvOS)
        guard AudioFocus.shared.isOwner(.podcast) else { return }
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    func clearNowPlaying() {
        #if !os(tvOS)
        artworkTask?.cancel()
        // Never wipe music's tile when podcast is yielding focus.
        if AudioFocus.shared.isOwner(.podcast) || AudioFocus.shared.owner == .none {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        #endif
    }

    private var commandsConfigured = false

    private func setupRemoteCommands() {
        #if !os(tvOS)
        guard !commandsConfigured else { return }
        commandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        // Strict `isOwner(.podcast)` — see NowPlayingCenter. Soft `!= .music`
        // let both engines handle the same event when focus was `.none`.
        center.playCommand.addTarget { _ in
            guard AudioFocus.shared.allowsRemotePlayback(for: .podcast) else {
                return .commandFailed
            }
            NotificationCenter.default.post(name: .podcastPlayerResume, object: nil)
            return .success
        }
        center.pauseCommand.addTarget { _ in
            guard AudioFocus.shared.isOwner(.podcast) else { return .commandFailed }
            NotificationCenter.default.post(name: .podcastPlayerPause, object: nil)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            guard AudioFocus.shared.allowsRemotePlayback(for: .podcast) else {
                return .commandFailed
            }
            NotificationCenter.default.post(name: .podcastPlayerToggle, object: nil)
            return .success
        }
        center.skipForwardCommand.addTarget { _ in
            guard AudioFocus.shared.isOwner(.podcast) else { return .commandFailed }
            NotificationCenter.default.post(name: .podcastPlayerSkipForward, object: nil)
            return .success
        }
        center.skipBackwardCommand.addTarget { _ in
            guard AudioFocus.shared.isOwner(.podcast) else { return .commandFailed }
            NotificationCenter.default.post(name: .podcastPlayerSkipBackward, object: nil)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard AudioFocus.shared.isOwner(.podcast) else { return .commandFailed }
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            NotificationCenter.default.post(
                name: .podcastPlayerSeek,
                object: nil,
                userInfo: ["time": event.positionTime])
            return .success
        }
        AudioFocus.shared.applyRemoteCommandSurface()
        #endif
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let podcastPlayerResume = Notification.Name("podcastPlayerResume")
    static let podcastPlayerPause = Notification.Name("podcastPlayerPause")
    static let podcastPlayerSkipForward = Notification.Name("podcastPlayerSkipForward")
    static let podcastPlayerSkipBackward = Notification.Name("podcastPlayerSkipBackward")
    static let podcastPlayerSeek = Notification.Name("podcastPlayerSeek")
    static let podcastPlayerToggle = Notification.Name("podcastPlayerToggle")
}

// MARK: - Helpers

extension CMTime {
    var seconds: TimeInterval {
        guard timescale != 0 else { return 0 }
        return TimeInterval(value) / TimeInterval(timescale)
    }
}

func CMTimeGetSecondsIfFinite(_ time: CMTime) -> TimeInterval? {
    guard time.flags.contains(.valid), time.timescale > 0 else { return nil }
    let seconds = TimeInterval(time.value) / TimeInterval(time.timescale)
    return seconds.isFinite && seconds > 0 ? seconds : nil
}
