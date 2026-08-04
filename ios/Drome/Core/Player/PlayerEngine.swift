import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// The playback engine. Owns an AVQueuePlayer used as a sliding window
/// (current + next two items preloaded) so track transitions are gapless,
/// while the full queue lives in this class:
///
/// - `userQueue` — tracks explicitly queued by the user ("Next in queue"),
///   always played before the context continues.
/// - `contextQueue` — the rest of the album/playlist the current track came
///   from ("Next from: …"), reordered when shuffle modes change.
///
/// When both run dry and Infinite Shuffle is on, the autoplay provider
/// extends the context automatically.
@MainActor
final class PlayerEngine: ObservableObject {
    // MARK: Published state

    @Published private(set) var current: QueueItem?
    @Published private(set) var userQueue: [QueueItem] = []
    @Published private(set) var contextQueue: [QueueItem] = []
    @Published private(set) var history: [QueueItem] = []
    @Published private(set) var context: PlaybackContext?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var repeatMode: RepeatMode = .off {
        didSet { resyncUpcomingWindow() }
    }
    @Published var shuffleMode: ShuffleMode = .off {
        didSet { guard oldValue != shuffleMode else { return }; reorderContextForShuffleChange() }
    }
    @Published var autoplayEnabled: Bool = UserDefaults.standard.object(forKey: "drome.autoplay") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoplayEnabled, forKey: "drome.autoplay")
            if autoplayEnabled { maybeExtendWithAutoplay() } else { removeAutoplayTail() }
        }
    }

    var autoplayProvider: AutoplayProvider?

    // MARK: Private state

    private let player = AVQueuePlayer()
    /// Parallel bookkeeping of which AVPlayerItem belongs to which queue item.
    private var window: [(playerItem: AVPlayerItem, queueItem: QueueItem)] = []
    /// Original (unshuffled) order of the remaining context, for un-shuffling.
    private var originalContextOrder: [QueueItem] = []
    /// The full source collection, used for repeat-all wraparound.
    private var fullContextSongs: [Song] = []
    private var isRebuilding = false
    private var seekEpoch = 0
    private var appliedSeekEpoch = 0
    private var autoplayTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var timeObserver: Any?

    private let client: SubsonicClient
    private let ratings: RatingsStore
    private let rotation: RotationManager
    private let downloads: DownloadManager
    private let nowPlaying = NowPlayingCenter()

    // MARK: Init

    init(client: SubsonicClient, ratings: RatingsStore, rotation: RotationManager,
         downloads: DownloadManager) {
        self.client = client
        self.ratings = ratings
        self.rotation = rotation
        self.downloads = downloads

        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
    }

    func shutdown() {
        player.pause()
        player.removeAllItems()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        cancellables.removeAll()
        nowPlaying.update(song: nil, elapsed: 0, duration: 0, isPlaying: false)
    }

    // MARK: - Public API: starting playback

    /// Play a collection starting at the tapped index. With shuffle on, the
    /// remaining tracks are reordered by the active shuffle mode.
    func play(_ songs: [Song], startAt index: Int = 0, context: PlaybackContext) {
        guard songs.indices.contains(index) else { return }
        ratings.ingest(songs)
        self.context = context
        fullContextSongs = songs

        let startSong = songs[index]
        var rest = Array(songs[(index + 1)...])
        if shuffleMode != .off {
            rest = orderedForShuffle(Array(songs[..<index]) + rest)
        }
        originalContextOrder = Array(songs[(index + 1)...]).map { QueueItem(song: $0) }
        contextQueue = shuffleMode == .off
            ? originalContextOrder
            : rest.map { QueueItem(song: $0) }
        userQueue.removeAll()
        history.removeAll()
        setCurrent(QueueItem(song: startSong), startPlaying: true)
    }

    /// Shuffle-button entry point: enables shuffle (smart by default) and
    /// picks the opening track from the weighted pool too.
    func playShuffled(_ songs: [Song], context: PlaybackContext) {
        guard !songs.isEmpty else { return }
        ratings.ingest(songs)
        if shuffleMode == .off { shuffleMode = .smart }
        self.context = context
        fullContextSongs = songs

        let pool = orderedForShuffle(songs)
        guard let first = pool.first else {
            // Everything was excluded (e.g. all out of rotation): play as-is.
            play(songs, startAt: 0, context: context)
            return
        }
        originalContextOrder = songs.filter { $0.id != first.id }.map { QueueItem(song: $0) }
        contextQueue = pool.dropFirst().map { QueueItem(song: $0) }
        userQueue.removeAll()
        history.removeAll()
        setCurrent(QueueItem(song: first), startPlaying: true)
    }

    // MARK: - Public API: transport

    func playPause() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        activateAudioSession()
        player.play()
    }

    func pause() {
        player.pause()
    }

    func next() {
        guard peekUpcoming(limit: 1).first != nil else {
            // Queue exhausted: jump to the end of the current track.
            player.seek(to: CMTime(seconds: duration, preferredTimescale: 600))
            return
        }
        // Prefer advancing the preloaded AVQueuePlayer window so bookkeeping
        // stays in `handleCurrentItemChange` (one code path for skip + gapless).
        if window.count > 1 {
            player.advanceToNextItem()
            // KVO usually handles this; sync immediately if the publisher hasn't.
            if let item = player.currentItem {
                handleCurrentItemChange(item)
            }
            maybeExtendWithAutoplay()
            return
        }
        guard let upNext = peekUpcoming(limit: 1).first else { return }
        if let current {
            history.append(current)
            scrobbleSubmission(current.song)
        }
        consumeFromQueues(upNext)
        setCurrent(upNext, startPlaying: true)
        maybeExtendWithAutoplay()
    }

    func previous(preferPreviousTrack: Bool = false) {
        // Hardware / lock-screen previous: restart if we're >3s into the track.
        if !preferPreviousTrack && elapsed > 3 {
            seek(to: 0)
            return
        }
        // Art-swipe / explicit "go back": always the last played song — never restart.
        guard let prev = history.popLast() else {
            if !preferPreviousTrack { seek(to: 0) }
            return
        }
        if let current {
            contextQueue.insert(current, at: 0)
        }
        setCurrent(prev, startPlaying: true)
    }

    func seek(to time: TimeInterval) {
        guard let item = player.currentItem else {
            elapsed = max(0, time)
            pushNowPlayingInfo()
            return
        }

        let itemDuration: TimeInterval = {
            let live = item.duration.seconds
            if live.isFinite, live > 0 { return live }
            if duration.isFinite, duration > 0 { return duration }
            return max(time, 0)
        }()

        // Seeking exactly to duration often stalls the item without advancing.
        let maxSeekable = max(0, itemDuration - 0.35)
        var seconds = min(max(0, time), maxSeekable)

        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            if start.isFinite, end.isFinite, end > start {
                seconds = min(max(seconds, start), max(start, end - 0.35))
            }
        }

        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        seekEpoch += 1
        let epoch = seekEpoch
        let shouldResume = player.timeControlStatus == .playing
            || player.rate > 0
            || isPlaying

        // Zero-tolerance seeks frequently no-op on Navidrome HTTP streams.
        let slack = CMTime(seconds: 1.0, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: slack, toleranceAfter: slack) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekEpoch == epoch else { return }
                self.appliedSeekEpoch = epoch
                let actual = self.player.currentTime().seconds
                self.elapsed = (actual.isFinite && actual >= 0) ? actual : seconds
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.pushNowPlayingInfo()
                if finished, shouldResume {
                    self.activateAudioSession()
                    self.player.play()
                }
            }
        }

        elapsed = seconds
        pushNowPlayingInfo()
    }

    /// High-resolution playhead for karaoke / scrubber UIs. Prefer this over
    /// the throttled `elapsed` publish when you need frame-smooth updates.
    func accurateElapsed() -> TimeInterval {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return elapsed }
        return seconds
    }

    func cycleShuffleMode() {
        switch shuffleMode {
        case .off: shuffleMode = .smart
        case .smart: shuffleMode = .random
        case .random: shuffleMode = .off
        }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Public API: queue editing

    func playNext(_ song: Song) {
        ratings.ingest([song])
        userQueue.insert(QueueItem(song: song), at: 0)
        if current == nil {
            let item = userQueue.removeFirst()
            setCurrent(item, startPlaying: true)
        } else {
            resyncUpcomingWindow()
        }
    }

    func addToQueue(_ song: Song) {
        ratings.ingest([song])
        userQueue.append(QueueItem(song: song))
        if current == nil {
            let item = userQueue.removeFirst()
            setCurrent(item, startPlaying: true)
        } else {
            resyncUpcomingWindow()
        }
    }

    func jump(to item: QueueItem) {
        guard item.id != current?.id else { return }
        if let current {
            history.append(current)
        }
        // Everything before the tapped item in play order is skipped.
        if let idx = userQueue.firstIndex(where: { $0.id == item.id }) {
            userQueue.removeSubrange(0...idx)
        } else if let idx = contextQueue.firstIndex(where: { $0.id == item.id }) {
            userQueue.removeAll()
            contextQueue.removeSubrange(0...idx)
        }
        setCurrent(item, startPlaying: true)
    }

    func moveUserQueueItems(from source: IndexSet, to destination: Int) {
        userQueue.move(fromOffsets: source, toOffset: destination)
        resyncUpcomingWindow()
    }

    func moveContextQueueItems(from source: IndexSet, to destination: Int) {
        contextQueue.move(fromOffsets: source, toOffset: destination)
        resyncUpcomingWindow()
    }

    func removeUserQueueItems(at offsets: IndexSet) {
        userQueue.remove(atOffsets: offsets)
        resyncUpcomingWindow()
    }

    func removeContextQueueItems(at offsets: IndexSet) {
        contextQueue.remove(atOffsets: offsets)
        resyncUpcomingWindow()
    }

    func removeFromQueue(_ item: QueueItem) {
        if let idx = userQueue.firstIndex(where: { $0.id == item.id }) {
            userQueue.remove(at: idx)
            resyncUpcomingWindow()
            return
        }
        if let idx = contextQueue.firstIndex(where: { $0.id == item.id }) {
            contextQueue.remove(at: idx)
            resyncUpcomingWindow()
        }
    }

    func clearQueue() {
        userQueue.removeAll()
        contextQueue.removeAll()
        resyncUpcomingWindow()
    }

    // MARK: - Player window management

    private func setCurrent(_ item: QueueItem, startPlaying: Bool) {
        current = item
        elapsed = 0
        duration = TimeInterval(item.song.duration ?? 0)
        rebuildWindow(startPlaying: startPlaying)
        scrobbleNowPlaying(item.song)
        loadArtwork(for: item.song)
    }

    private func makePlayerItem(for song: Song) -> AVPlayerItem {
        let url = downloads.localURL(songId: song.id)
            ?? client.streamURL(songId: song.id)
            ?? URL(fileURLWithPath: "/dev/null")
        return AVPlayerItem(url: url)
    }

    private func rebuildWindow(startPlaying: Bool) {
        isRebuilding = true
        player.removeAllItems()
        window.removeAll()
        defer {
            isRebuilding = false
            pushNowPlayingInfo()
        }
        guard let current else { return }
        for queueItem in [current] + peekUpcoming(limit: 2) {
            let playerItem = makePlayerItem(for: queueItem.song)
            window.append((playerItem, queueItem))
            player.insert(playerItem, after: player.items().last)
        }
        if startPlaying {
            activateAudioSession()
            player.play()
        }
    }

    /// Keeps the preloaded window in sync after queue edits without touching
    /// the currently playing item (preserving gapless playback).
    private func resyncUpcomingWindow() {
        guard let first = window.first else { return }
        isRebuilding = true
        for entry in window.dropFirst() {
            player.remove(entry.playerItem)
        }
        window = [first]
        if repeatMode != .one {
            for queueItem in peekUpcoming(limit: 2) {
                let playerItem = makePlayerItem(for: queueItem.song)
                window.append((playerItem, queueItem))
                player.insert(playerItem, after: player.items().last)
            }
        }
        isRebuilding = false
    }

    /// Tops up the window after a natural advance.
    private func topUpWindow() {
        guard window.count < 3, repeatMode != .one else { return }
        let queued = Set(window.map(\.queueItem.id))
        for queueItem in peekUpcoming(limit: 3) where !queued.contains(queueItem.id) {
            if window.count >= 3 { break }
            let playerItem = makePlayerItem(for: queueItem.song)
            window.append((playerItem, queueItem))
            player.insert(playerItem, after: player.items().last)
        }
    }

    private func peekUpcoming(limit: Int) -> [QueueItem] {
        Array((userQueue + contextQueue).prefix(limit))
    }

    private func consumeFromQueues(_ item: QueueItem) {
        if let idx = userQueue.firstIndex(where: { $0.id == item.id }) {
            userQueue.remove(at: idx)
        } else if let idx = contextQueue.firstIndex(where: { $0.id == item.id }) {
            contextQueue.remove(at: idx)
        }
    }

    // MARK: - Player observation

    private func observePlayer() {
        player.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                self?.handleCurrentItemChange(item)
            }
            .store(in: &cancellables)

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.pushNowPlayingInfo()
            }
            .store(in: &cancellables)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isRebuilding else { return }
                // While a seek is in flight, keep the optimistic playhead until
                // the completion handler settles on the real position.
                guard self.seekEpoch == self.appliedSeekEpoch else { return }
                let seconds = time.seconds
                guard seconds.isFinite, seconds >= 0 else { return }
                self.elapsed = seconds
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
            }
        }

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleItemDidEnd(notification.object as? AVPlayerItem)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleInterruption(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init)
                if reason == .oldDeviceUnavailable {
                    self?.pause()
                }
            }
            .store(in: &cancellables)
    }

    /// AVQueuePlayer advanced by itself (gapless transition) — update our
    /// bookkeeping to match.
    private func handleCurrentItemChange(_ item: AVPlayerItem?) {
        guard !isRebuilding else { return }
        guard let item else {
            // Gapless handoffs often emit a transient `nil` currentItem while
            // the next buffer is already playing. Treating that as "exhausted"
            // cleared our window and left the UI stuck on the previous track.
            if player.items().isEmpty {
                handleQueueExhausted()
            }
            return
        }
        guard let index = window.firstIndex(where: { $0.playerItem === item }) else {
            return
        }
        guard index > 0 else { return }

        for finished in window[..<index] {
            history.append(finished.queueItem)
            scrobbleSubmission(finished.queueItem.song)
        }
        let newCurrent = window[index].queueItem
        window.removeFirst(index)
        consumeFromQueues(newCurrent)
        // Assign a fresh value so SwiftUI always observes the change even if
        // song metadata happens to compare equal.
        current = newCurrent
        elapsed = 0
        duration = TimeInterval(newCurrent.song.duration ?? 0)
        isPlaying = player.timeControlStatus == .playing
        topUpWindow()
        pushNowPlayingInfo()
        scrobbleNowPlaying(newCurrent.song)
        loadArtwork(for: newCurrent.song)
        maybeExtendWithAutoplay()
    }

    private func handleItemDidEnd(_ item: AVPlayerItem?) {
        guard let item, item === window.first?.playerItem else { return }
        if repeatMode == .one {
            player.seek(to: .zero)
            player.play()
            if let song = current?.song { scrobbleSubmission(song) }
        }
    }

    private func handleQueueExhausted() {
        guard let finished = current else { return }
        scrobbleSubmission(finished.song)
        if repeatMode == .all, !fullContextSongs.isEmpty, let context {
            history.append(finished)
            play(fullContextSongs, startAt: 0, context: context)
            return
        }
        // Leave the finished track visible, paused at the end (Spotify-like).
        history.append(finished)
        window.removeAll()
        elapsed = duration
        isPlaying = false
        pushNowPlayingInfo()
    }

    // MARK: - Shuffle

    private func orderedForShuffle(_ songs: [Song]) -> [Song] {
        let excluded = (context?.allowsOutOfRotation ?? false) ? [] : rotation.excludedIDs
        return ShuffleEngine.order(songs, mode: shuffleMode,
                                   rating: { [weak self] in self?.ratings.rating(for: $0) ?? 0 },
                                   excluded: excluded)
    }

    private func reorderContextForShuffleChange() {
        guard !contextQueue.isEmpty || !originalContextOrder.isEmpty else { return }
        let remainingIDs = Set(contextQueue.map(\.id))
        switch shuffleMode {
        case .off:
            // Restore source order for items still queued; keep autoplay tail at the end.
            let restored = originalContextOrder.filter { remainingIDs.contains($0.id) }
            let extras = contextQueue.filter { item in !originalContextOrder.contains(where: { $0.id == item.id }) }
            contextQueue = restored + extras
        case .smart, .random:
            let excluded = (context?.allowsOutOfRotation ?? false) ? Set<String>() : rotation.excludedIDs
            let kept = contextQueue.filter { !excluded.contains($0.song.id) }
            let songs = ShuffleEngine.order(kept.map(\.song), mode: shuffleMode,
                                            rating: { [weak self] in self?.ratings.rating(for: $0) ?? 0 },
                                            excluded: excluded)
            var byID: [String: [QueueItem]] = Dictionary(grouping: kept, by: { $0.song.id })
            contextQueue = songs.compactMap { byID[$0.id]?.popLast() }
        }
        resyncUpcomingWindow()
    }

    // MARK: - Autoplay (Infinite Shuffle)

    private func maybeExtendWithAutoplay() {
        guard autoplayEnabled, repeatMode == .off, autoplayTask == nil,
              let provider = autoplayProvider, current != nil else { return }
        guard userQueue.count + contextQueue.count < 5 else { return }

        let seeds = (history.suffix(8).map(\.song) + [current?.song].compactMap { $0 })
        var excluding = Set(history.suffix(60).map(\.song.id))
        excluding.formUnion(userQueue.map(\.song.id))
        excluding.formUnion(contextQueue.map(\.song.id))
        if let currentID = current?.song.id { excluding.insert(currentID) }

        autoplayTask = Task { [weak self] in
            let songs = await provider.nextBatch(seeds: seeds, excluding: excluding)
            guard let self else { return }
            self.autoplayTask = nil
            guard !songs.isEmpty else { return }
            self.ratings.ingest(songs)
            self.contextQueue.append(contentsOf: songs.map { QueueItem(song: $0, isAutoplay: true) })
            if self.context == nil {
                self.context = PlaybackContext(label: "Autoplay", kind: .mix)
            }
            self.topUpWindow()
        }
    }

    private func removeAutoplayTail() {
        contextQueue.removeAll(where: \.isAutoplay)
        resyncUpcomingWindow()
    }

    // MARK: - System integration

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        nowPlaying.configureCommands()
        nowPlaying.onPlay = { [weak self] in self?.playPause() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }
        nowPlaying.onSeek = { [weak self] time in self?.seek(to: time) }
    }

    private func pushNowPlayingInfo() {
        nowPlaying.update(song: current?.song, elapsed: elapsed,
                          duration: duration, isPlaying: isPlaying)
    }

    private func loadArtwork(for song: Song) {
        guard let url = client.coverArtURL(id: song.coverArt ?? song.albumId ?? song.id) else {
            nowPlaying.setArtwork(nil, songID: nil)
            return
        }
        Task { [weak self] in
            let image = await ImageLoader.shared.image(for: url)
            guard let self, self.current?.song.id == song.id else { return }
            self.nowPlaying.setArtwork(image, songID: song.id)
            self.pushNowPlayingInfo()
        }
    }

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

    // MARK: - Scrobbling

    private func scrobbleNowPlaying(_ song: Song) {
        Task { try? await client.scrobble(id: song.id, submission: false) }
    }

    private func scrobbleSubmission(_ song: Song) {
        Task { try? await client.scrobble(id: song.id, submission: true) }
    }
}
