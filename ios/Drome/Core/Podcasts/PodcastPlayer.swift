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

    // MARK: Private state

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
    private let nowPlaying = PodcastNowPlayingCenter()
    private let store: PodcastStore?

    static let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    private static let userAgent = "Drome/1.0 (Podcast; iOS)"

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

        let startPosition: TimeInterval = {
            if resumeFromSaved, let store {
                return (try? store.playbackPosition(episodeID: episode.id, showFeedURL: episode.showID)) ?? 0
            }
            return 0
        }()

        // Yield the shared audio session to podcasts.
        onWillStartPlayback?()
        activateAudioSession()

        currentEpisode = episode
        chapters = episode.chapters.filter(\.toc).sorted { $0.startTime < $1.startTime }
        errorMessage = nil
        elapsed = 0
        duration = episode.duration ?? 0
        wantsToPlay = true
        pendingSeek = startPosition > 1 ? startPosition : nil

        let item = makePlayerItem(url: episode.audioURL)
        player.replaceCurrentItem(with: item)

        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.playGeneration else { return }
                if item.status == .failed {
                    let message = item.error?.localizedDescription ?? "Couldn't play this episode"
                    self.errorMessage = message
                    self.wantsToPlay = false
                    self.isPlaying = false
                    print("[PodcastPlayer] item failed: \(message)")
                }
            }
        }

        updateNowPlaying(for: episode, startPosition: startPosition, rate: 0)
        waitUntilReadyThenPlay(item, generation: generation)
        Task { await self.resolveChapters(for: episode, generation: generation) }
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
        activateAudioSession()
        wantsToPlay = true
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
        elapsed = 0
        duration = 0
        pendingSeek = nil
        nowPlaying.clearNowPlaying()
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
        // Many hosts (Art19, Megaphone, etc.) reject empty / default User-Agents.
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": Self.userAgent,
                "Accept": "*/*",
            ],
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ])
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
            pause()
        case .ended:
            if let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
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

        artworkTask?.cancel()
        guard let imageURL = episode.imageURL,
              let scheme = imageURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }

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
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
        #endif
    }

    func updateElapsedTime(_ elapsed: TimeInterval, duration: TimeInterval, rate: Float) {
        #if !os(tvOS)
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    private var commandsConfigured = false

    private func setupRemoteCommands() {
        #if !os(tvOS)
        guard !commandsConfigured else { return }
        commandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: .podcastPlayerResume, object: nil)
            return .success
        }
        center.pauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .podcastPlayerPause, object: nil)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .podcastPlayerToggle, object: nil)
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { _ in
            NotificationCenter.default.post(name: .podcastPlayerSkipForward, object: nil)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in
            NotificationCenter.default.post(name: .podcastPlayerSkipBackward, object: nil)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            NotificationCenter.default.post(
                name: .podcastPlayerSeek,
                object: nil,
                userInfo: ["time": event.positionTime])
            return .success
        }
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
