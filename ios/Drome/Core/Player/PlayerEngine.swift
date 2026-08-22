import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import GroupActivities

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
    /// Sticky transport intent. AVPlayer briefly reports paused / waiting while
    /// skipping tracks — UI follows this so the play/pause button does not flash.
    private var wantsToPlay = false
    /// Playhead lives on `clock` for SwiftUI; these mirrors are for engine logic.
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    let clock = PlaybackClock()
    @Published var repeatMode: RepeatMode = .off {
        didSet { resyncUpcomingWindow() }
    }
    @Published var shuffleMode: ShuffleMode = .off {
        didSet {
            guard oldValue != shuffleMode, !suppressShuffleReorder else { return }
            reorderContextForShuffleChange()
            persistSessionSoon()
        }
    }
    /// When true, assigning `shuffleMode` does not reshuffle the existing queue
    /// (used when starting a fresh Play or restoring a saved session).
    private var suppressShuffleReorder = false
    @Published var autoplayEnabled: Bool = UserDefaults.standard.object(forKey: "drome.autoplay") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoplayEnabled, forKey: "drome.autoplay")
            if autoplayEnabled { maybeExtendWithAutoplay() } else { removeAutoplayTail() }
        }
    }
    @Published private(set) var sharePlayActive = false
    @Published private(set) var sharePlayParticipantCount = 0
    @Published private(set) var isEligibleForSharePlay = false
    @Published var sharePlayNotice: String?

    var autoplayProvider: AutoplayProvider?
    /// Fired when a track becomes current (explicit `setCurrent` or gapless advance).
    var onTrackStarted: ((Song) -> Void)?
    /// Connect gate: run `action` immediately and return `true`, or defer and return `false`.
    var localPlaybackGate: ((@escaping () -> Void) -> Bool)?

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
    /// Bumped whenever in-flight autoplay work is cancelled so stale
    /// `nextBatch` results cannot rebuild the player window.
    private var autoplayGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private var timeObserver: Any?
    /// Delayed lookahead insert so the current stream wins bandwidth first.
    private var prefetchTask: Task<Void, Never>?
    /// Wait for `readyToPlay` / a short buffer before `play()` so skips don't
    /// underrun the HDMI HAL (grain + FigFilePlayer -12864).
    private var itemReadyCancellable: AnyCancellable?
    private var itemReadyTimeout: Task<Void, Never>?
    #if os(tvOS)
    private let tvCache: TVPlaybackCache
    private let tvAudio = TVNowPlayingAudio()
    private var tvUsingAudioPlayer = false
    private var tvRebuildGeneration = 0
    #endif
    private var lastPublishedElapsed: TimeInterval = -1
    /// Tracks AirPlay so we only rebuild when the route actually flips.
    private var lastAirPlayActive = false
    private let sharePlayBridge = SharePlayCoordinatorBridge()
    private let groupStateObserver = GroupStateObserver()
    private var sharePlaySession: GroupSession<DromeListenTogether>?
    private var sharePlayMessenger: GroupSessionMessenger?
    private var sharePlaySessionTasks: [Task<Void, Never>] = []
    private var applyingSharePlay = false
    private var lastSharePlaySnapshot: SharePlaySnapshot?
    private var pendingSharePlaySnapshot: SharePlaySnapshot?

    private let client: SubsonicClient
    private let ratings: RatingsStore
    private let rotation: RotationManager
    private let downloads: DownloadManager
    private let nowPlaying = NowPlayingCenter()
    private var sessionStore: PlaybackSessionStore?
    private var persistTask: Task<Void, Never>?
    /// Snapshots of queues displaced by an accidental `play` / `playShuffled`.
    /// Art-swipe previous restores these when in-queue history is empty.
    private var sessionUndoStack: [PlaybackSessionSnapshot] = []
    private let maxSessionUndo = 8
    /// When another Connect device is playing, drive UI playhead from its session.
    private var remotePlayheadAnchor: (elapsed: TimeInterval, at: Date, playing: Bool)?

    // MARK: Init

    init(client: SubsonicClient, ratings: RatingsStore, rotation: RotationManager,
         downloads: DownloadManager) {
        self.client = client
        self.ratings = ratings
        self.rotation = rotation
        self.downloads = downloads
        #if os(tvOS)
        self.tvCache = TVPlaybackCache(client: client)
        #endif

        // Prefer stalling briefly over underrunning / glitching on hiccups.
        player.automaticallyWaitsToMinimizeStalling = true
        #if os(tvOS)
        player.allowsExternalPlayback = false
        player.actionAtItemEnd = .pause
        tvAudio.onFinished = { [weak self] in
            self?.playNextAfterCurrentEnds()
        }
        #else
        player.actionAtItemEnd = .advance
        #endif

        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
        observeAppLifecycle()
        lastAirPlayActive = isAirPlayRouteActive

        #if os(iOS)
        player.playbackCoordinator.delegate = sharePlayBridge
        groupStateObserver.$isEligibleForGroupSession
            .receive(on: RunLoop.main)
            .sink { [weak self] eligible in
                self?.isEligibleForSharePlay = eligible
            }
            .store(in: &cancellables)
        #endif
    }

    /// Wire per-account persistence for Recently Played + cold-start resume.
    func attachSessionStore(_ store: PlaybackSessionStore) {
        sessionStore = store
    }

    /// Rebuild the last listening session after launch (paused) so the mini
    /// player can offer Continue without auto-playing.
    @discardableResult
    func restorePersistedSessionIfNeeded() -> Bool {
        guard current == nil else { return false }
        guard let snap = sessionStore?.latest() else { return false }
        restore(snap, seeking: true, startPlaying: false, recordPlay: false)
        return true
    }

    /// Rebuild current item when AirPlay turns on/off so FLAC raw ↔ MP3.
    private func handlePossibleAirPlayRouteChange() {
        let airPlay = isAirPlayRouteActive
        guard airPlay != lastAirPlayActive else { return }
        lastAirPlayActive = airPlay
        guard current != nil else { return }
        let resume = wantsToPlay
        let position = elapsed
        rebuildWindow(startPlaying: resume)
        if position > 0.5 {
            seek(to: position)
        }
    }

    func shutdown() {
        SharePlayRuntime.shared.bind(nil)
        leaveSharePlay()
        cancelAutoplayWork()
        prefetchTask?.cancel()
        prefetchTask = nil
        itemReadyCancellable?.cancel()
        itemReadyCancellable = nil
        itemReadyTimeout?.cancel()
        itemReadyTimeout = nil
        #if os(tvOS)
        tvRebuildGeneration += 1
        tvAudio.stop()
        tvUsingAudioPlayer = false
        #endif
        player.pause()
        player.rate = 0
        player.removeAllItems()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        cancellables.removeAll()
        nowPlaying.update(song: nil, elapsed: 0, duration: 0, isPlaying: false)
    }

    // MARK: - Public API: starting playback

    /// Play a collection starting at the tapped index, always in order
    /// (Play turns shuffle off; use `playShuffled` for shuffle).
    func play(_ songs: [Song], startAt index: Int = 0, context: PlaybackContext) {
        guard songs.indices.contains(index) else { return }
        runLocalPlayback { [self] in
            pushSessionUndoIfNeeded()
            cancelAutoplayWork()
            ratings.ingest(songs)
            if shuffleMode != .off {
                suppressShuffleReorder = true
                shuffleMode = .off
                suppressShuffleReorder = false
            }
            self.context = context
            fullContextSongs = songs

            let startSong = songs[index]
            originalContextOrder = Array(songs[(index + 1)...]).map { QueueItem(song: $0) }
            contextQueue = originalContextOrder
            userQueue.removeAll()
            history.removeAll()
            // Direct user tap — always honor the chosen track even if low-rated.
            setCurrent(QueueItem(song: startSong), startPlaying: true, allowLowRated: true)
            ensureAutoplayBuffer()
            persistSessionSoon()
            broadcastSharePlayIfNeeded()
        }
    }

    /// Shuffle-button entry point: enables shuffle (smart by default) and
    /// picks the opening track from the weighted pool too.
    func playShuffled(_ songs: [Song], context: PlaybackContext) {
        guard !songs.isEmpty else { return }
        runLocalPlayback { [self] in
            pushSessionUndoIfNeeded()
            cancelAutoplayWork()
            ratings.ingest(songs)
            if shuffleMode == .off { shuffleMode = .smart }
            self.context = context
            fullContextSongs = songs

            let pool = orderedForShuffle(songs)
            guard let first = pool.first else {
                // Everything was excluded (e.g. all out of rotation): play as-is.
                // Undo already pushed; nested play would double-push — skip.
                self.context = context
                fullContextSongs = songs
                originalContextOrder = Array(songs.dropFirst()).map { QueueItem(song: $0) }
                contextQueue = originalContextOrder
                userQueue.removeAll()
                history.removeAll()
                if let song = songs.first {
                    setCurrent(QueueItem(song: song), startPlaying: true, allowLowRated: true)
                }
                ensureAutoplayBuffer()
                persistSessionSoon()
                return
            }
            originalContextOrder = songs.filter { $0.id != first.id }.map { QueueItem(song: $0) }
            contextQueue = pool.dropFirst().map { QueueItem(song: $0) }
            userQueue.removeAll()
            history.removeAll()
            setCurrent(QueueItem(song: first), startPlaying: true, allowLowRated: true)
            ensureAutoplayBuffer()
            persistSessionSoon()
        }
    }

    /// Restore a previously saved listening session (queue + shuffle).
    /// Playhead always starts at 0 — recents should replay, not scrub mid-track.
    @discardableResult
    func resumeSession(forKey key: String) -> Bool {
        guard var snap = sessionStore?.snapshot(forResumeKey: key) else { return false }
        snap.elapsed = 0
        restore(snap, seeking: false, startPlaying: true, recordPlay: true)
        return true
    }

    /// Resume the most recently persisted session and start playing.
    @discardableResult
    func resumeLatestSession() -> Bool {
        guard let snap = sessionStore?.latest() else { return false }
        restore(snap, seeking: true, startPlaying: true, recordPlay: true)
        return true
    }

    private func restore(_ snap: PlaybackSessionSnapshot,
                         seeking: Bool = true,
                         startPlaying: Bool = true,
                         recordPlay: Bool = true) {
        cancelAutoplayWork()
        ratings.ingest(snap.fullContextSongs + [snap.currentSong]
                       + snap.history + snap.userQueue + snap.contextQueue)
        suppressShuffleReorder = true
        shuffleMode = ShuffleMode(rawValue: snap.shuffleMode) ?? .off
        suppressShuffleReorder = false
        switch snap.repeatMode {
        case "all": repeatMode = .all
        case "one": repeatMode = .one
        default: repeatMode = .off
        }
        autoplayEnabled = snap.autoplayEnabled
        context = snap.makeContext()
        fullContextSongs = snap.fullContextSongs
        history = snap.history.map { QueueItem(song: $0) }
        userQueue = snap.userQueue.map { QueueItem(song: $0) }
        contextQueue = snap.contextQueue.map { song in
            let isAutoplay = !snap.fullContextSongs.contains(where: { $0.id == song.id })
            return QueueItem(song: song, isAutoplay: isAutoplay)
        }
        originalContextOrder = snap.originalContextOrder.map { QueueItem(song: $0) }
        setCurrent(QueueItem(song: snap.currentSong),
                   startPlaying: startPlaying,
                   allowLowRated: true,
                   recordPlay: recordPlay)
        if seeking, snap.elapsed > 0.5 {
            // Paint the mini-player progress immediately; AV seek catches up.
            setPlayhead(elapsed: snap.elapsed)
            seek(to: snap.elapsed)
        }
        ensureAutoplayBuffer()
        persistSessionSoon()
    }

    private func persistSessionSoon() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            persistSessionNow()
        }
    }

    private func persistSessionNow() {
        guard let store = sessionStore, let snap = makeSessionSnapshot() else { return }
        store.save(snap)
    }

    // MARK: - Public API: transport

    func playPause() {
        if wantsToPlay { pause() } else { resume() }
    }

    func resume(bypassConnectGate: Bool = false) {
        let body = { [self] in
            clearRemotePlayheadMirror()
            setPlaybackIntent(true)
            activateAudioSession()
            #if os(tvOS)
            if tvUsingAudioPlayer {
                tvAudio.play()
                persistSessionSoon()
                return
            }
            #endif
            playCurrentWhenReady()
            persistSessionSoon()
        }
        if bypassConnectGate {
            body()
        } else {
            runLocalPlayback(body)
        }
    }

    func pause() {
        setPlaybackIntent(false)
        #if os(tvOS)
        tvAudio.pause()
        #endif
        player.pause()
        persistSessionNow()
    }

    private func setPlaybackIntent(_ playing: Bool) {
        wantsToPlay = playing
        if isPlaying != playing {
            isPlaying = playing
        }
    }

    func next() {
        let keepPlaying = wantsToPlay
        // Drop leading low-rated tracks when the user opted into global skip.
        drainLowRatedFromQueues()
        guard peekUpcoming(limit: 1).first != nil else {
            if autoplayEnabled, repeatMode == .off {
                continueWithAutoplayIfNeeded(playImmediately: true)
                return
            }
            player.seek(to: CMTime(seconds: duration, preferredTimescale: 600))
            return
        }
        // Prefer advancing the preloaded AVQueuePlayer window so bookkeeping
        // stays in `handleCurrentItemChange` (one code path for skip + gapless).
        // tvOS plays one HTTP stream at a time — skip rebuilds instead of
        // advancing into a prefetched item FigFilePlayer may already have failed.
        #if !os(tvOS)
        if window.count > 1 {
            player.advanceToNextItem()
            if let item = player.currentItem {
                handleCurrentItemChange(item)
            }
            applyPlaybackIntent(keepPlaying)
            ensureAutoplayBuffer()
            return
        }
        #endif
        guard let upNext = peekUpcoming(limit: 1).first else { return }
        if let current {
            history.append(current)
            scrobbleSubmission(current.song)
        }
        consumeFromQueues(upNext)
        setCurrent(upNext, startPlaying: keepPlaying)
        ensureAutoplayBuffer()
    }

    func previous(preferPreviousTrack: Bool = false) {
        let keepPlaying = wantsToPlay
        // Hardware / lock-screen previous: restart if we're >3s into the track.
        if !preferPreviousTrack && elapsed > 3 {
            seek(to: 0)
            return
        }
        // Art-swipe / explicit "go back": always the last played song — never restart.
        if let prev = history.popLast() {
            if let current {
                contextQueue.insert(current, at: 0)
            }
            setCurrent(prev, startPlaying: keepPlaying)
            return
        }
        // Accidental Play replaced the queue — restore the displaced session.
        if restoreUndoneSession() { return }
        if !preferPreviousTrack { seek(to: 0) }
    }

    /// Art-swipe advance: exactly one step to the peeked neighbor, no low-rated
    /// drain / auto-skip (those would land on a different song than the cover).
    func advanceFromArtSwipe(goingNext: Bool) {
        let keepPlaying = wantsToPlay
        if goingNext {
            guard let upNext = peekUpcoming(limit: 1).first else { return }
            cancelAutoplayWork()
            if let current {
                history.append(current)
                scrobbleSubmission(current.song)
            }
            consumeFromQueues(upNext)
            // Force the setCurrent path (not AVQueuePlayer.advance) so we don't
            // hit handleCurrentItemChange's async low-rated skip.
            setCurrent(upNext, startPlaying: keepPlaying, allowLowRated: true)
            ensureAutoplayBuffer()
        } else {
            previous(preferPreviousTrack: true)
        }
    }

    /// Re-assert play/pause after a skip so transient AVPlayer status cannot
    /// flip the transport button.
    private func applyPlaybackIntent(_ playing: Bool) {
        setPlaybackIntent(playing)
        if playing {
            activateAudioSession()
            playCurrentWhenReady()
        } else {
            #if os(tvOS)
            tvAudio.pause()
            #endif
            player.pause()
        }
        pushNowPlayingInfo()
    }

    private func playCurrentWhenReady() {
        #if os(tvOS)
        if tvUsingAudioPlayer {
            tvAudio.play()
            return
        }
        guard let item = player.currentItem else { return }
        if item.status == .failed {
            retryCurrentAfterDecodeFailure()
            return
        }
        if itemIsSafeToStart(item) {
            itemReadyCancellable = nil
            itemReadyTimeout?.cancel()
            player.play()
            return
        }
        waitUntilItemReady(item) { [weak self] in
            self?.playCurrentWhenReady()
        }
        #else
        player.play()
        #endif
    }

    #if os(tvOS)
    private func itemIsSafeToStart(_ item: AVPlayerItem) -> Bool {
        item.status == .readyToPlay
    }

    private func waitUntilItemReady(_ item: AVPlayerItem, onReady: @escaping () -> Void) {
        if item.status == .failed {
            retryCurrentAfterDecodeFailure()
            return
        }
        if itemIsSafeToStart(item) {
            onReady()
            return
        }
        itemReadyCancellable?.cancel()
        itemReadyTimeout?.cancel()
        itemReadyTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.itemReadyCancellable = nil
                if item.status == .failed {
                    if item === self.player.currentItem {
                        self.retryCurrentAfterDecodeFailure()
                    }
                } else {
                    onReady()
                }
            }
        }
        itemReadyCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == .readyToPlay {
                    self.itemReadyTimeout?.cancel()
                    self.itemReadyCancellable = nil
                    onReady()
                } else if status == .failed {
                    self.itemReadyTimeout?.cancel()
                    self.itemReadyCancellable = nil
                    if item === self.player.currentItem {
                        self.retryCurrentAfterDecodeFailure()
                    }
                }
            }
    }

    private func retryCurrentAfterDecodeFailure() {
        guard let song = current?.song else { return }
        let queueItem = current
        Task { @MainActor in
            guard let url = try? await self.tvCache.fileURL(for: song) else { return }
            guard self.current?.id == queueItem?.id else { return }
            do {
                self.player.pause()
                self.player.removeAllItems()
                self.window.removeAll()
                try self.tvAudio.start(url: url)
                self.tvUsingAudioPlayer = true
                self.setPlaybackIntent(true)
            } catch {
                self.playNextAfterCurrentEnds()
            }
        }
    }
    #endif

    /// Song behind the current cover (in-queue history, else undone session).
    var artSwipePreviousSong: Song? {
        if let song = history.last?.song { return song }
        return sessionUndoStack.last?.currentSong
    }

    /// Song ahead of the current cover in Up Next.
    var artSwipeNextSong: Song? {
        peekUpcoming(limit: 1).first?.song
    }

    /// True when swipe-back can restore either history or a displaced queue.
    var canArtSwipePrevious: Bool {
        !history.isEmpty || !sessionUndoStack.isEmpty
    }

    var canArtSwipeNext: Bool {
        !peekUpcoming(limit: 1).isEmpty
    }

    private func pushSessionUndoIfNeeded() {
        guard let snap = makeSessionSnapshot() else { return }
        // Don't stack identical consecutive snapshots.
        if let last = sessionUndoStack.last,
           last.currentSong.id == snap.currentSong.id,
           last.resumeKey == snap.resumeKey,
           last.contextQueue.map(\.id) == snap.contextQueue.map(\.id) {
            return
        }
        sessionUndoStack.append(snap)
        if sessionUndoStack.count > maxSessionUndo {
            sessionUndoStack.removeFirst(sessionUndoStack.count - maxSessionUndo)
        }
    }

    @discardableResult
    private func restoreUndoneSession() -> Bool {
        guard let snap = sessionUndoStack.popLast() else { return false }
        restore(snap, seeking: true)
        return true
    }

    private func makeSessionSnapshot() -> PlaybackSessionSnapshot? {
        guard let current, let context else { return nil }
        return PlaybackSessionSnapshot(
            resumeKey: context.resumeKey(fallbackSong: current.song),
            label: context.label,
            kind: context.kind,
            currentSong: current.song,
            elapsed: accurateElapsed(),
            shuffleMode: shuffleMode.rawValue,
            repeatMode: {
                switch repeatMode {
                case .off: return "off"
                case .all: return "all"
                case .one: return "one"
                }
            }(),
            autoplayEnabled: autoplayEnabled,
            history: history.map(\.song),
            userQueue: userQueue.map(\.song),
            contextQueue: contextQueue.map(\.song),
            originalContextOrder: originalContextOrder.map(\.song),
            fullContextSongs: fullContextSongs,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    /// Snapshot for Drome Connect transfer / remote publish.
    func connectSnapshot() -> PlaybackSessionSnapshot? {
        makeSessionSnapshot()
    }

    /// Apply a Connect session from another device and optionally start playing.
    func applyConnectSnapshot(_ snap: PlaybackSessionSnapshot, startPlaying: Bool, recordPlay: Bool = true) {
        restore(snap, seeking: true, startPlaying: startPlaying, recordPlay: recordPlay)
    }

    func seek(to time: TimeInterval) {
        #if os(tvOS)
        if tvUsingAudioPlayer {
            let seconds = max(0, time)
            tvAudio.seek(to: seconds)
            setPlayhead(elapsed: seconds, duration: tvAudio.duration > 0 ? tvAudio.duration : duration)
            seekEpoch += 1
            appliedSeekEpoch = seekEpoch
            if wantsToPlay { tvAudio.play() }
            pushNowPlayingInfo()
            return
        }
        #endif
        guard let item = player.currentItem else {
            setPlayhead(elapsed: max(0, time))
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

        // HTTP streams on the phone need slack or the seek no-ops. Apple TV
        // playing a local file needs an exact seek — a 1s window plus another
        // seek (scrub) is what made HDMI audio fall apart (HLS-FASB).
        let slack: CMTime
        if let url = (item.asset as? AVURLAsset)?.url, url.isFileURL {
            slack = .zero
        } else {
            slack = CMTime(seconds: 1.0, preferredTimescale: 600)
        }
        player.seek(to: target, toleranceBefore: slack, toleranceAfter: slack) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekEpoch == epoch else { return }
                self.appliedSeekEpoch = epoch
                let actual = self.player.currentTime().seconds
                let nextElapsed = (actual.isFinite && actual >= 0) ? actual : seconds
                var nextDuration = self.duration
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    nextDuration = itemDuration
                }
                self.setPlayhead(elapsed: nextElapsed, duration: nextDuration)
                self.pushNowPlayingInfo()
                if finished, shouldResume {
                    self.activateAudioSession()
                    #if os(tvOS)
                    self.playCurrentWhenReady()
                    #else
                    self.player.play()
                    #endif
                }
            }
        }

        setPlayhead(elapsed: seconds)
        pushNowPlayingInfo()
    }

    /// High-resolution playhead for karaoke / scrubber UIs. Prefer this over
    /// the throttled `elapsed` publish when you need frame-smooth updates.
    func accurateElapsed() -> TimeInterval {
        if let anchor = remotePlayheadAnchor {
            if anchor.playing {
                return max(0, anchor.elapsed + Date().timeIntervalSince(anchor.at))
            }
            return max(0, anchor.elapsed)
        }
        #if os(tvOS)
        if tvUsingAudioPlayer {
            return tvAudio.currentTime
        }
        #endif
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return elapsed }
        return seconds
    }

    /// Drive mini / now-playing playhead from another Connect device's session.
    func mirrorRemotePlayhead(elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        remotePlayheadAnchor = (elapsed, Date(), isPlaying)
        setPlayhead(elapsed: elapsed, duration: duration > 0 ? duration : nil)
    }

    func clearRemotePlayheadMirror() {
        remotePlayheadAnchor = nil
    }

    private func runLocalPlayback(_ action: @escaping () -> Void) {
        if let gate = localPlaybackGate {
            _ = gate(action)
        } else {
            action()
        }
    }

    private func setPlayhead(elapsed: TimeInterval, duration newDuration: TimeInterval? = nil) {
        self.elapsed = elapsed
        if let newDuration {
            duration = newDuration
        }
        clock.set(elapsed: elapsed, duration: newDuration ?? duration)
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
        if current == nil {
            runLocalPlayback { [self] in
                userQueue.insert(QueueItem(song: song), at: 0)
                let item = userQueue.removeFirst()
                setCurrent(item, startPlaying: true, allowLowRated: true)
            }
            return
        }
        userQueue.insert(QueueItem(song: song), at: 0)
        resyncUpcomingWindow()
    }

    func addToQueue(_ song: Song) {
        ratings.ingest([song])
        if current == nil {
            runLocalPlayback { [self] in
                userQueue.append(QueueItem(song: song))
                let item = userQueue.removeFirst()
                setCurrent(item, startPlaying: true, allowLowRated: true)
            }
            return
        }
        userQueue.append(QueueItem(song: song))
        resyncUpcomingWindow()
    }

    func jump(to item: QueueItem) {
        guard item.id != current?.id else { return }
        runLocalPlayback { [self] in
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
            // User tapped a specific queue row — play it even if low-rated.
            setCurrent(item, startPlaying: true, allowLowRated: true)
            ensureAutoplayBuffer()
        }
    }

    func moveUserQueueItems(from source: IndexSet, to destination: Int) {
        userQueue.move(fromOffsets: source, toOffset: destination)
        resyncUpcomingWindow()
    }

    func moveContextQueueItems(from source: IndexSet, to destination: Int) {
        contextQueue.move(fromOffsets: source, toOffset: destination)
        resyncUpcomingWindow()
    }

    /// Drag-handle reorder: place `id` immediately before `destID`.
    func moveQueueItem(id: UUID, before destID: UUID) {
        guard id != destID else { return }
        let dragged: QueueItem
        if let i = userQueue.firstIndex(where: { $0.id == id }) {
            dragged = userQueue.remove(at: i)
        } else if let i = contextQueue.firstIndex(where: { $0.id == id }) {
            dragged = contextQueue.remove(at: i)
        } else {
            return
        }
        if let j = userQueue.firstIndex(where: { $0.id == destID }) {
            userQueue.insert(dragged, at: j)
        } else if let j = contextQueue.firstIndex(where: { $0.id == destID }) {
            contextQueue.insert(dragged, at: j)
        } else {
            userQueue.append(dragged)
        }
        resyncUpcomingWindow()
    }

    /// Live handle drag within one queue section.
    func moveQueueItem(id: UUID, toIndex dest: Int, inUserQueue: Bool) {
        if inUserQueue {
            Self.reposition(&userQueue, id: id, toIndex: dest)
        } else {
            Self.reposition(&contextQueue, id: id, toIndex: dest)
        }
        resyncUpcomingWindow()
    }

    private static func reposition(_ items: inout [QueueItem], id: UUID, toIndex dest: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let dest = min(max(dest, 0), items.count - 1)
        guard from != dest else { return }
        let item = items.remove(at: from)
        items.insert(item, at: min(dest, items.count))
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

    /// - Parameter allowLowRated: When true (direct user selection), never
    ///   auto-skip 1–2★ tracks. Skip only applies to programmatic advancement.
    /// - Parameter recordPlay: When false (cold-start restore), skip scrobble /
    ///   recent-play writes until the user actually presses play.
    private func setCurrent(_ item: QueueItem,
                            startPlaying: Bool,
                            allowLowRated: Bool = false,
                            recordPlay: Bool = true) {
        current = item
        setPlayhead(elapsed: 0, duration: TimeInterval(item.song.duration ?? 0))
        rebuildWindow(startPlaying: startPlaying)
        loadArtwork(for: item.song)
        if recordPlay {
            scrobbleNowPlaying(item.song)
            onTrackStarted?(item.song)
        }
        if !allowLowRated, shouldSkipLowRated(item.song), peekUpcoming(limit: 1) != nil {
            // Advance past globally-skipped low ratings without stalling.
            DispatchQueue.main.async { [weak self] in self?.next() }
        } else {
            ensureAutoplayBuffer()
        }
        persistSessionSoon()
        broadcastSharePlayIfNeeded()
    }

    private var isAirPlayRouteActive: Bool {
        #if os(tvOS)
        // Apple TV cannot decode FLAC over HDMI (FigFilePlayer -12864), including
        // local files. Never treat the TV output as an AirPlay transcode trigger
        // for the iPhone player, but also never feed it lossless originals.
        return false
        #else
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .airPlay
        }
        #endif
    }

    private func makePlayerItem(for song: Song) -> AVPlayerItem {
        makePlayerItem(for: song, url: playbackURL(for: song))
    }

    private func playbackURL(for song: Song) -> URL {
        #if os(tvOS)
        tvHTTPStreamURL(for: song) ?? URL(fileURLWithPath: "/dev/null")
        #else
        let airPlay = isAirPlayRouteActive
        if !airPlay, let local = downloads.localURL(songId: song.id) { return local }
        return client.streamURL(songId: song.id, compatibleWithAirPlay: airPlay)
            ?? URL(fileURLWithPath: "/dev/null")
        #endif
    }

    #if os(tvOS)
    private func tvHTTPStreamURL(for song: Song) -> URL? {
        let suffix = (song.suffix ?? "").lowercased()
        let type = (song.contentType ?? "").lowercased()
        if suffix == "mp3" || type.contains("mpeg") {
            return client.streamURL(songId: song.id, format: "raw", maxBitRate: nil,
                                    estimateContentLength: true)
                ?? client.downloadURL(songId: song.id)
        }
        return client.streamURL(songId: song.id, format: "mp3", maxBitRate: 320,
                                estimateContentLength: true)
    }
    #endif

    private func makePlayerItem(for song: Song, url: URL) -> AVPlayerItem {
        let isFile = url.isFileURL
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: isFile,
        ])
        let item = AVPlayerItem(asset: asset)
        sharePlayBridge.remember(item, identity: Self.sharePlayContentID(for: song))
        item.preferredForwardBufferDuration = isFile ? 4 : 45
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        item.preferredPeakBitRate = 0
        return item
    }

    /// How many *upcoming* items to keep in AVQueuePlayer.
    /// Remote lossless streams are bandwidth-heavy; only preload one ahead so
    /// the current track keeps the pipe. Local files can preload two.
    private func upcomingPrefetchCount() -> Int {
        #if os(tvOS)
        // A second live HTTP/transcode stream is what FigFilePlayer probes and
        // fails while the current track is still playing.
        return 0
        #else
        let currentIsLocal = current.map { downloads.localURL(songId: $0.song.id) != nil } ?? false
        let upcoming = peekUpcoming(limit: 2)
        let upcomingAllLocal = !upcoming.isEmpty
            && upcoming.allSatisfy { downloads.localURL(songId: $0.song.id) != nil }
        if currentIsLocal && upcomingAllLocal { return 2 }
        return 1
        #endif
    }

    private func rebuildWindow(startPlaying: Bool) {
        #if os(tvOS)
        rebuildWindowFromFile(startPlaying: startPlaying)
        #else
        rebuildWindowStreaming(startPlaying: startPlaying)
        #endif
    }

    #if os(tvOS)
    private func rebuildWindowFromFile(startPlaying: Bool) {
        isRebuilding = true
        prefetchTask?.cancel()
        itemReadyCancellable?.cancel()
        itemReadyCancellable = nil
        itemReadyTimeout?.cancel()
        itemReadyTimeout = nil
        tvRebuildGeneration += 1
        tvAudio.stop()
        tvUsingAudioPlayer = false
        player.pause()
        player.rate = 0
        player.removeAllItems()
        window.removeAll()
        sharePlayBridge.reset()
        guard let current else {
            isRebuilding = false
            return
        }
        let song = current.song
        let queueItem = current
        setPlaybackIntent(startPlaying)
        activateAudioSession()

        // Cached complete MP3 → Audio Queue (no FigFilePlayer).
        if let cached = tvCache.cachedURL(for: song) {
            do {
                try tvAudio.start(url: cached)
                if !startPlaying { tvAudio.pause() }
                tvUsingAudioPlayer = true
                isRebuilding = false
                let duration = tvAudio.duration > 0 ? tvAudio.duration : TimeInterval(song.duration ?? 0)
                setPlayhead(elapsed: 0, duration: duration)
                pushNowPlayingInfo()
                if let next = peekUpcoming(limit: 1).first {
                    tvCache.prefetch(next.song)
                }
                return
            } catch {
                tvAudio.stop()
                tvUsingAudioPlayer = false
            }
        }

        // Start MP3 HTTP immediately so we aren't silent while a full file copies.
        guard let url = tvHTTPStreamURL(for: song) else {
            isRebuilding = false
            return
        }
        let playerItem = makePlayerItem(for: song, url: url)
        window.append((playerItem, queueItem))
        player.insert(playerItem, after: nil)
        isRebuilding = false
        pushNowPlayingInfo()
        if startPlaying {
            playCurrentWhenReady()
        }
        tvCache.prefetch(song)
        if let next = peekUpcoming(limit: 1).first {
            tvCache.prefetch(next.song)
        }
    }
    #endif

    #if !os(tvOS)
    private func rebuildWindowStreaming(startPlaying: Bool) {
        isRebuilding = true
        prefetchTask?.cancel()
        itemReadyCancellable?.cancel()
        itemReadyCancellable = nil
        itemReadyTimeout?.cancel()
        itemReadyTimeout = nil
        let suspension = sharePlaySession.map { _ in
            player.playbackCoordinator.beginSuspension(for: .dromeRebuilding)
        }
        defer { suspension?.end() }
        player.pause()
        player.rate = 0
        player.removeAllItems()
        window.removeAll()
        sharePlayBridge.reset()
        defer {
            isRebuilding = false
            pushNowPlayingInfo()
        }
        guard let current else { return }

        let playerItem = makePlayerItem(for: current.song)
        window.append((playerItem, current))
        player.insert(playerItem, after: nil)
        if let session = sharePlaySession {
            player.playbackCoordinator.coordinateWithSession(session)
        }

        if startPlaying {
            activateAudioSession()
            setPlaybackIntent(true)
            playCurrentWhenReady()
        } else {
            setPlaybackIntent(false)
        }

        schedulePrefetchTopUp(delayNanoseconds: 1_200_000_000)
    }
    #endif

    /// Keeps the preloaded window in sync after queue edits without touching
    /// the currently playing item (preserving gapless playback).
    private func resyncUpcomingWindow() {
        if let first = window.first {
            isRebuilding = true
            prefetchTask?.cancel()
            for entry in window.dropFirst() {
                player.remove(entry.playerItem)
            }
            window = [first]
            isRebuilding = false
            // Prefer the playing item; top up lookahead after a beat.
            schedulePrefetchTopUp(delayNanoseconds: 400_000_000)
        }
        persistSessionSoon()
        broadcastSharePlayIfNeeded()
    }

    /// Tops up the window after a natural advance or delayed prefetch.
    private func topUpWindow() {
        let targetCount = 1 + upcomingPrefetchCount()
        guard window.count < targetCount, repeatMode != .one else { return }
        let queued = Set(window.map(\.queueItem.id))
        for queueItem in peekUpcoming(limit: targetCount) where !queued.contains(queueItem.id) {
            if window.count >= targetCount { break }
            let playerItem = makePlayerItem(for: queueItem.song)
            window.append((playerItem, queueItem))
            player.insert(playerItem, after: player.items().last)
        }
    }

    private func schedulePrefetchTopUp(delayNanoseconds: UInt64) {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.topUpWindow()
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

    // MARK: - App lifecycle

    private func observeAppLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.persistSessionNow()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.persistSessionNow()
            }
            .store(in: &cancellables)
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
                switch status {
                case .playing:
                    // External resume (lock screen / CarPlay / headphones).
                    self.wantsToPlay = true
                    if !self.isPlaying { self.isPlaying = true }
                case .waitingToPlayAtSpecifiedRate:
                    // Buffering — keep the button on the sticky intent.
                    if self.isPlaying != self.wantsToPlay {
                        self.isPlaying = self.wantsToPlay
                    }
                case .paused:
                    if self.isRebuilding || self.wantsToPlay {
                        // Transient pause during skip/rebuild — do not flip UI.
                        if self.isPlaying != self.wantsToPlay {
                            self.isPlaying = self.wantsToPlay
                        }
                    } else if self.isPlaying {
                        self.isPlaying = false
                    }
                @unknown default:
                    break
                }
                self.pushNowPlayingInfo()
            }
            .store(in: &cancellables)

        // Publish playhead ~2 Hz for UI; karaoke uses accurateElapsed() instead.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isRebuilding else { return }
                #if os(tvOS)
                if self.tvUsingAudioPlayer { return }
                #endif
                guard self.seekEpoch == self.appliedSeekEpoch else { return }
                let seconds = time.seconds
                guard seconds.isFinite, seconds >= 0 else { return }
                // Skip tiny updates to cut SwiftUI churn while audio stays smooth.
                if abs(seconds - self.lastPublishedElapsed) < 0.2,
                   abs(seconds - self.elapsed) < 0.2 {
                    return
                }
                self.lastPublishedElapsed = seconds
                var nextDuration = self.duration
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    nextDuration = itemDuration
                }
                self.setPlayhead(elapsed: seconds, duration: nextDuration)
            }
        }

        #if os(tvOS)
        Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.tvUsingAudioPlayer, !self.isRebuilding else { return }
                let seconds = self.tvAudio.currentTime
                guard seconds.isFinite, seconds >= 0 else { return }
                let duration = self.tvAudio.duration > 0 ? self.tvAudio.duration : self.duration
                self.setPlayhead(elapsed: seconds, duration: duration)
            }
            .store(in: &cancellables)
        #endif

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleItemDidEnd(notification.object as? AVPlayerItem)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard let failed = notification.object as? AVPlayerItem,
                      failed === self.player.currentItem else { return }
                #if os(tvOS)
                self.retryCurrentAfterDecodeFailure()
                #endif
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
                guard let self else { return }
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init)
                if reason == .oldDeviceUnavailable {
                    self.pause()
                    return
                }
                // Rebuild the player item when entering/leaving AirPlay so we
                // switch between lossless raw and AirPlay-compatible MP3.
                if reason == .newDeviceAvailable || reason == .routeConfigurationChange {
                    self.handlePossibleAirPlayRouteChange()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureAudioSession()
                self?.activateAudioSession()
                if self?.wantsToPlay == true {
                    self?.playCurrentWhenReady()
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
            #if os(tvOS)
            return
            #else
            if player.items().isEmpty {
                handleQueueExhausted()
            }
            return
            #endif
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
        setPlayhead(elapsed: 0, duration: TimeInterval(newCurrent.song.duration ?? 0))
        // Keep transport UI on sticky intent — AVPlayer status flickers here.
        if isPlaying != wantsToPlay {
            isPlaying = wantsToPlay
        }
        topUpWindow()
        // Prefetch the following track after the new current claims bandwidth.
        schedulePrefetchTopUp(delayNanoseconds: 800_000_000)
        pushNowPlayingInfo()
        scrobbleNowPlaying(newCurrent.song)
        loadArtwork(for: newCurrent.song)
        onTrackStarted?(newCurrent.song)
        // Gapless advance is programmatic — honor skip-low-rated here.
        if shouldSkipLowRated(newCurrent.song), peekUpcoming(limit: 1) != nil {
            DispatchQueue.main.async { [weak self] in self?.next() }
        } else {
            ensureAutoplayBuffer()
        }
        broadcastSharePlayIfNeeded()
    }

    private func handleItemDidEnd(_ item: AVPlayerItem?) {
        guard let item, item === window.first?.playerItem else { return }
        if repeatMode == .one {
            player.seek(to: .zero)
            playCurrentWhenReady()
            if let song = current?.song { scrobbleSubmission(song) }
            return
        }
        #if os(tvOS)
        playNextAfterCurrentEnds()
        #endif
    }

    #if os(tvOS)
    /// Natural end / Infinite Shuffle: start the next queued song on a fresh
    /// HTTP stream instead of advancing a prefetched AVQueuePlayer item.
    private func playNextAfterCurrentEnds() {
        drainLowRatedFromQueues()
        if let upNext = peekUpcoming(limit: 1).first {
            if let current {
                history.append(current)
                scrobbleSubmission(current.song)
            }
            consumeFromQueues(upNext)
            setCurrent(upNext, startPlaying: true)
            ensureAutoplayBuffer()
            return
        }
        handleQueueExhausted()
    }
    #endif

    private func handleQueueExhausted() {
        guard let finished = current else { return }
        scrobbleSubmission(finished.song)
        if repeatMode == .all, !fullContextSongs.isEmpty, let context {
            history.append(finished)
            play(fullContextSongs, startAt: 0, context: context)
            return
        }
        history.append(finished)
        window.removeAll()
        // A refill may have won the race and already queued tracks — play those
        // instead of kicking off a second force-autoplay fetch.
        if let next = peekUpcoming(limit: 1).first {
            consumeFromQueues(next)
            setCurrent(next, startPlaying: true)
            ensureAutoplayBuffer()
            return
        }
        // Infinite Shuffle must keep going — never silently stop at the end.
        if autoplayEnabled, repeatMode == .off {
            setPlayhead(elapsed: duration)
            pushNowPlayingInfo()
            continueWithAutoplayIfNeeded(playImmediately: true)
            return
        }
        player.pause()
        player.rate = 0
        setPlayhead(elapsed: duration)
        setPlaybackIntent(false)
        pushNowPlayingInfo()
    }

    /// Regenerates the algorithmic (autoplay) tail without stopping playback.
    func rerollAutoplayQueue() {
        if !autoplayEnabled { autoplayEnabled = true }
        let contextIDs = Set(fullContextSongs.map(\.id))
        contextQueue.removeAll { item in
            item.isAutoplay || !contextIDs.contains(item.song.id)
        }
        if context?.kind == .mix {
            contextQueue.removeAll()
        }
        resyncUpcomingWindow()
        cancelAutoplayWork()
        maybeExtendWithAutoplay(force: true)
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

    /// Keeps a healthy upcoming buffer whenever Infinite Shuffle is on.
    /// Call after jumps / play / advances so the last track never leaves an
    /// empty Up Next list.
    private func ensureAutoplayBuffer() {
        guard !applyingSharePlay, autoplayEnabled, repeatMode == .off, current != nil else { return }
        let upcoming = userQueue.count + contextQueue.count
        // Refill early — never wait until the queue is already empty.
        if upcoming < 8 {
            maybeExtendWithAutoplay(force: upcoming < 3)
        }
    }

    private func cancelAutoplayWork() {
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayGeneration += 1
    }

    /// Single serialized entry for empty-queue Infinite Shuffle continuation.
    /// Collapses concurrent `next()` + end-of-queue races into one fetch.
    private func continueWithAutoplayIfNeeded(playImmediately: Bool) {
        guard autoplayEnabled, repeatMode == .off else {
            if playImmediately {
                player.pause()
                player.rate = 0
                setPlaybackIntent(false)
                pushNowPlayingInfo()
            }
            return
        }

        if playImmediately, let next = peekUpcoming(limit: 1).first {
            consumeFromQueues(next)
            setCurrent(next, startPlaying: true)
            ensureAutoplayBuffer()
            return
        }

        guard autoplayProvider != nil else {
            if playImmediately {
                player.pause()
                player.rate = 0
                setPlaybackIntent(false)
                pushNowPlayingInfo()
            }
            return
        }

        // Replace any in-flight buffer refill so stale top-ups cannot rebuild
        // the window while we start the next track.
        cancelAutoplayWork()
        let generation = autoplayGeneration
        autoplayTask = Task { [weak self] in
            guard let self else { return }
            await self.forceAutoplayContinuation(playImmediately: playImmediately, generation: generation)
            if self.autoplayGeneration == generation {
                self.autoplayTask = nil
                self.ensureAutoplayBuffer()
            }
        }
    }

    private func maybeExtendWithAutoplay(force: Bool = false) {
        guard !applyingSharePlay, autoplayEnabled, repeatMode == .off, autoplayTask == nil,
              let provider = autoplayProvider, current != nil else { return }
        if !force {
            guard userQueue.count + contextQueue.count < 8 else { return }
        }

        let seeds = (history.suffix(8).map(\.song) + [current?.song].compactMap { $0 })
        var excluding = Set(history.suffix(60).map(\.song.id))
        excluding.formUnion(userQueue.map(\.song.id))
        excluding.formUnion(contextQueue.map(\.song.id))
        if let currentID = current?.song.id { excluding.insert(currentID) }

        autoplayGeneration += 1
        let generation = autoplayGeneration
        autoplayTask = Task { [weak self] in
            let songs = await provider.nextBatch(seeds: seeds, excluding: excluding, count: 20)
            guard let self else { return }
            guard !Task.isCancelled, self.autoplayGeneration == generation else { return }
            self.autoplayTask = nil
            guard !songs.isEmpty else { return }
            self.ratings.ingest(songs)
            self.contextQueue.append(contentsOf: songs.map { QueueItem(song: $0, isAutoplay: true) })
            if self.context == nil {
                self.context = PlaybackContext(label: "Autoplay", kind: .mix)
            }
            self.topUpWindow()
            self.broadcastSharePlayIfNeeded()
            // Keep topping up until the buffer is healthy.
            self.ensureAutoplayBuffer()
        }
    }

    private func forceAutoplayContinuation(playImmediately: Bool, generation: Int) async {
        guard let provider = autoplayProvider else {
            if playImmediately {
                player.pause()
                player.rate = 0
                setPlaybackIntent(false)
                pushNowPlayingInfo()
            }
            return
        }

        // Prefer anything queued while we were waiting to start this task.
        if playImmediately, let next = peekUpcoming(limit: 1).first {
            consumeFromQueues(next)
            setCurrent(next, startPlaying: true)
            ensureAutoplayBuffer()
            return
        }

        var excluding = Set(history.suffix(60).map(\.song.id))
        excluding.formUnion(userQueue.map(\.song.id))
        excluding.formUnion(contextQueue.map(\.song.id))
        let seeds = history.suffix(8).map(\.song)
        let songs = await provider.nextBatch(seeds: seeds, excluding: excluding, count: 20)
        guard !Task.isCancelled, autoplayGeneration == generation else { return }
        guard !songs.isEmpty else {
            if playImmediately {
                player.pause()
                player.rate = 0
                setPlaybackIntent(false)
                pushNowPlayingInfo()
            }
            return
        }
        ratings.ingest(songs)
        contextQueue.append(contentsOf: songs.map { QueueItem(song: $0, isAutoplay: true) })
        if context == nil {
            context = PlaybackContext(label: "Autoplay", kind: .mix)
        }
        if playImmediately, let next = peekUpcoming(limit: 1).first {
            consumeFromQueues(next)
            setCurrent(next, startPlaying: true)
        } else {
            topUpWindow()
        }
        broadcastSharePlayIfNeeded()
    }

    private func drainLowRatedFromQueues() {
        guard PlaybackPreferences.skipLowRatedEverywhere else { return }
        userQueue.removeAll { shouldSkipLowRated($0.song) }
        contextQueue.removeAll { shouldSkipLowRated($0.song) }
        resyncUpcomingWindow()
    }

    private func shouldSkipLowRated(_ song: Song) -> Bool {
        guard PlaybackPreferences.skipLowRatedEverywhere else { return false }
        let r = ratings.rating(for: song)
        return (1...2).contains(r)
    }

    private func removeAutoplayTail() {
        contextQueue.removeAll(where: \.isAutoplay)
        resyncUpcomingWindow()
    }

    // MARK: - System integration

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if sharePlayActive {
            // Mix with FaceTime so Drome can play on each phone during the call.
            try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        } else {
            #if os(tvOS)
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            #else
            try? session.setCategory(.playback, mode: .default, options: [])
            #endif
        }
        try? session.setActive(true, options: [])
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
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
        let candidates = [
            song.coverArt,
            song.albumId,
            song.id,
        ].compactMap { $0 }.filter { !$0.isEmpty }

        let localURL: URL? = candidates.lazy
            .compactMap { self.downloads.localCoverURL(coverId: $0) }
            .first
        let remoteURL: URL? = candidates.lazy
            .compactMap { self.client.coverArtURL(id: $0, size: 1200) }
            .first
        guard let url = localURL ?? remoteURL else { return }

        if let cached = ImageLoader.shared.previewImage(for: url) {
            nowPlaying.setArtwork(cached, songID: song.id)
            pushNowPlayingInfo()
            if ImageLoader.shared.cachedImage(for: url) != nil { return }
        }

        Task { [weak self] in
            var image = await ImageLoader.shared.image(for: url)
            if image == nil {
                for id in candidates.dropFirst() {
                    guard let alt = self?.client.coverArtURL(id: id, size: 1200) else { continue }
                    image = await ImageLoader.shared.image(for: alt)
                    if image != nil { break }
                }
            }
            guard let self, self.current?.song.id == song.id, let image else { return }
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
            if !sharePlayActive { pause() }
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

    // MARK: - SharePlay

    func startSharePlay() {
        SharePlayLauncher.start(from: self)
    }

    func attachSharePlaySession(_ session: GroupSession<DromeListenTogether>) {
        joinSharePlay(session)
    }

    func leaveSharePlay() {
        sharePlaySessionTasks.forEach { $0.cancel() }
        sharePlaySessionTasks.removeAll()
        sharePlayMessenger = nil
        sharePlaySession?.leave()
        sharePlaySession = nil
        sharePlayActive = false
        sharePlayParticipantCount = 0
        lastSharePlaySnapshot = nil
        pendingSharePlaySnapshot = nil
        configureAudioSession()
    }

    private func joinSharePlay(_ session: GroupSession<DromeListenTogether>) {
        sharePlaySessionTasks.forEach { $0.cancel() }
        sharePlaySessionTasks.removeAll()
        sharePlaySession?.leave()

        sharePlaySession = session
        let messenger = GroupSessionMessenger(session: session)
        sharePlayMessenger = messenger

        // Listen before join() so the first catch-up / snapshot is not dropped.
        sharePlaySessionTasks.append(Task { [weak self] in
            for await (snapshot, _) in messenger.messages(of: SharePlaySnapshot.self) {
                await self?.applySharePlaySnapshot(snapshot)
            }
        })
        sharePlaySessionTasks.append(Task { [weak self] in
            for await (_, _) in messenger.messages(of: SharePlayCatchUp.self) {
                await MainActor.run { self?.broadcastSharePlay(force: true) }
            }
        })
        sharePlaySessionTasks.append(Task { [weak self] in
            for await state in session.$state.values {
                guard let self else { return }
                if case .invalidated = state {
                    self.sharePlaySession = nil
                    self.sharePlayMessenger = nil
                    self.sharePlayActive = false
                    self.sharePlayParticipantCount = 0
                    self.pendingSharePlaySnapshot = nil
                    self.configureAudioSession()
                }
            }
        })
        sharePlaySessionTasks.append(Task { [weak self] in
            for await participants in session.$activeParticipants.values {
                guard let self else { return }
                let count = participants.count
                let grew = count > self.sharePlayParticipantCount
                self.sharePlayParticipantCount = count
                if grew { self.broadcastSharePlay(force: true) }
            }
        })

        player.playbackCoordinator.coordinateWithSession(session)
        session.join()
        sharePlayActive = true
        configureAudioSession()
        broadcastSharePlay(force: true)
        requestSharePlayCatchUp()
        ensureAutoplayBuffer()

        sharePlaySessionTasks.append(Task { [weak self] in
            for delay in [400_000_000, 1_200_000_000, 3_000_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.broadcastSharePlay(force: true)
                    self?.requestSharePlayCatchUp()
                }
            }
        })
    }

    private func makeSharePlaySnapshot() -> SharePlaySnapshot? {
        guard let song = current?.song else { return nil }
        let upcoming = peekUpcoming(limit: 24).map { SharePlayTrack(song: $0.song) }
        return SharePlaySnapshot(
            current: SharePlayTrack(song: song),
            upcoming: upcoming,
            isPlaying: wantsToPlay)
    }

    private func broadcastSharePlayIfNeeded() {
        broadcastSharePlay(force: false)
    }

    private func broadcastSharePlay(force: Bool) {
        guard sharePlayActive, !applyingSharePlay, let messenger = sharePlayMessenger else { return }
        guard let snapshot = makeSharePlaySnapshot() else { return }
        if !force, snapshot == lastSharePlaySnapshot { return }
        lastSharePlaySnapshot = snapshot
        Task {
            try? await messenger.send(snapshot)
        }
    }

    private func requestSharePlayCatchUp() {
        guard sharePlayActive, let messenger = sharePlayMessenger else { return }
        let ping = SharePlayCatchUp(token: UUID().uuidString)
        Task {
            try? await messenger.send(ping)
        }
    }

    private func applySharePlaySnapshot(_ snapshot: SharePlaySnapshot) async {
        if applyingSharePlay {
            pendingSharePlaySnapshot = snapshot
            return
        }
        if let last = lastSharePlaySnapshot, snapshot.sentAt + 0.05 < last.sentAt {
            return
        }
        if snapshot == lastSharePlaySnapshot {
            lastSharePlaySnapshot = snapshot
            return
        }

        applyingSharePlay = true
        defer {
            applyingSharePlay = false
            if let pending = pendingSharePlaySnapshot {
                pendingSharePlaySnapshot = nil
                Task { await applySharePlaySnapshot(pending) }
            } else {
                ensureAutoplayBuffer()
            }
        }

        let currentMatches = current.map {
            Self.sharePlayContentID(for: $0.song) == Self.sharePlayContentID(for: snapshot.current)
        } ?? false

        if currentMatches {
            let upcomingSongs = await resolveSharePlayTracks(snapshot.upcoming)
            userQueue = upcomingSongs.map { QueueItem(song: $0) }
            contextQueue.removeAll()
            lastSharePlaySnapshot = snapshot
            resyncUpcomingWindow()
            return
        }

        var songs: [Song] = []
        if let currentSong = await resolveSharePlayTrack(snapshot.current) {
            songs.append(currentSong)
        }
        let upcomingSongs = await resolveSharePlayTracks(snapshot.upcoming)
        for song in upcomingSongs where !songs.contains(where: { $0.id == song.id }) {
            songs.append(song)
        }
        guard !songs.isEmpty else {
            sharePlayNotice = "“\(snapshot.current.title)” isn’t in your library."
            return
        }
        if songs.first.map({ Self.sharePlayContentID(for: $0) }) != Self.sharePlayContentID(for: snapshot.current) {
            sharePlayNotice = "“\(snapshot.current.title)” isn’t in your library — playing the next shared track."
        }
        lastSharePlaySnapshot = snapshot
        cancelAutoplayWork()
        context = PlaybackContext(label: "Jam", kind: .mix)
        fullContextSongs = songs
        originalContextOrder = Array(songs.dropFirst()).map { QueueItem(song: $0) }
        contextQueue = originalContextOrder
        userQueue.removeAll()
        history.removeAll()
        setCurrent(QueueItem(song: songs[0]), startPlaying: snapshot.isPlaying, allowLowRated: true)
        NowPlayingPresenter.open()
        sharePlayNotice = nil
    }

    private func resolveSharePlayTracks(_ tracks: [SharePlayTrack]) async -> [Song] {
        var songs: [Song] = []
        var seen = Set<String>()
        for track in tracks {
            guard let song = await resolveSharePlayTrack(track) else { continue }
            let key = Self.sharePlayContentID(for: song)
            if seen.insert(key).inserted {
                songs.append(song)
            }
        }
        return songs
    }

    private func resolveSharePlayTrack(_ track: SharePlayTrack) async -> Song? {
        if let song = try? await client.song(id: track.id) { return song }
        let query = [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return nil }
        let result = try? await client.search(query, artistCount: 0, albumCount: 0, songCount: 12)
        let titleKey = LibraryMatcher.normalize(track.title)
        let artistKey = LibraryMatcher.normalize(track.artist)
        return result?.songs.first { song in
            LibraryMatcher.normalize(song.title) == titleKey
                && (artistKey.isEmpty
                    || LibraryMatcher.normalize(song.displayArtist).contains(artistKey)
                    || artistKey.contains(LibraryMatcher.normalize(song.displayArtist)))
        }
    }

    static func sharePlayContentID(for song: Song) -> String {
        sharePlayContentID(title: song.title, artist: song.displayArtist)
    }

    static func sharePlayContentID(for track: SharePlayTrack) -> String {
        sharePlayContentID(title: track.title, artist: track.artist)
    }

    static func sharePlayContentID(title: String, artist: String) -> String {
        "\(LibraryMatcher.normalize(title))|\(LibraryMatcher.normalize(artist))"
    }
}
