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
    /// Connect must not tear down AVQueuePlayer while this device is producing audio.
    var isLocalPlaybackEngaged: Bool { wantsToPlay || isPlaying }
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
    /// When true, the next `play` / `playShuffled` keeps `userQueue` instead of clearing it.
    private var preserveUserQueueOnce = false
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
    /// Called before music audio starts so podcast can yield the session.
    var onWillStartPlayback: (() -> Void)?
    /// Connect gate: run `action` immediately and return `true`, or defer and return `false`.
    var localPlaybackGate: ((@escaping () -> Void) -> Bool)?

    // MARK: Private state

    /// Captured across AVAudioSession interruptions so only the engine that
    /// was actually playing resumes after Bluetooth connect/disconnect.
    private var resumeAfterInterruption = false
    private let player = AVQueuePlayer()    /// Parallel bookkeeping of which AVPlayerItem belongs to which queue item.
    private var window: [(playerItem: AVPlayerItem, queueItem: QueueItem)] = []
    /// Original (unshuffled) order of the remaining context, for un-shuffling.
    private var originalContextOrder: [QueueItem] = []
    /// The full source collection, used for repeat-all wraparound.
    private var fullContextSongs: [Song] = []
    private var isRebuilding = false
    /// Nested rebuilds (AirPlay flip mid-advance) must not clear this early.
    private var rebuildDepth = 0
    /// Prevents didPlayToEndTime + currentItem KVO from both advancing the queue.
    private var isHandlingTrackEnd = false
    #if !os(tvOS)
    /// Queue row tied to the active AVPlayerItem — ignores stale end notifications.
    private var iosActivePlaybackItemID: UUID?
    #endif
    /// Natural end arrived while a rebuild was in flight — flush when safe.
    private var pendingAdvanceAfterRebuild = false
    /// Coalesced Next taps while a rebuild is in flight (one setCurrent later).
    private var pendingNextCount = 0
    /// Connect takeControl / transfer while a rebuild was in flight.
    private var pendingConnectApply: (snap: PlaybackSessionSnapshot, startPlaying: Bool, recordPlay: Bool)?
    /// Invalidates in-flight item-ready KVO / timeouts across rebuilds.
    private var itemReadyGeneration = 0
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
    private var tvLoadTask: Task<Void, Never>?
    /// Queue row that owns the active tvAudio session — ignores stale finish callbacks.
    private var tvActivePlaybackItemID: UUID?
    #endif
    private var lastPublishedElapsed: TimeInterval = -1
    /// Tracks AirPlay so we only rebuild when the route actually flips.
    private var lastAirPlayActive = false
    private var pendingAirPlayRebuild = false
    /// Cellular vs Wi‑Fi stream format (compress-on-cellular).
    private var lastCellularCompressed = false
    private var pendingNetworkRebuild = false
    private let sharePlayBridge = SharePlayCoordinatorBridge()
    private let groupStateObserver = GroupStateObserver()
    private var sharePlaySession: GroupSession<DromeListenTogether>?
    private var sharePlayMessenger: GroupSessionMessenger?
    private var sharePlaySessionTasks: [Task<Void, Never>] = []
    private var applyingSharePlay = false
    private var lastSharePlaySnapshot: SharePlaySnapshot?
    private var pendingSharePlaySnapshot: SharePlaySnapshot?
    /// True while AVPlayer is mid tear-down / buffer-wait — Connect/SharePlay must wait.
    private var isPlayerTransitioning: Bool {
        isRebuilding || isHandlingTrackEnd || rebuildDepth > 0 || itemReadyCancellable != nil
    }

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
            Task { @MainActor in
                await Task.yield()
                self?.handleTVTrackEnded()
            }
        }
        #else
        // Always pause at end and advance ourselves. AVQueuePlayer `.advance` into
        // an empty lookahead (typical for remote streams) races rebuildWindow and
        // was crashing on next / natural end.
        player.actionAtItemEnd = .pause
        #endif

        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
        observeAppLifecycle()
        observeNetworkStreamChanges()
        lastAirPlayActive = isAirPlayRouteActive
        lastCellularCompressed = shouldCompressForCellular

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
        DromeDiagnostics.logPlayer("session store attached")
    }

    /// One-line player state for the diagnostics log.
    func diagnosticStateLine() -> String {
        let song = current?.song
        return [
            "track=\(song?.id ?? "nil")",
            "«\(song?.title ?? "—")»",
            "\(Int(elapsed))/\(Int(duration))s",
            isPlaying ? "playing" : "paused",
            "rebuild:\(isRebuilding)/d:\(rebuildDepth)",
            "pendingNext:\(pendingNextCount)",
            "pendingAdvance:\(pendingAdvanceAfterRebuild)",
            "handlingEnd:\(isHandlingTrackEnd)",
            "window:\(window.count)",
            "cellular:\(shouldCompressForCellular)",
            "airPlay:\(isAirPlayRouteActive)",
        ].joined(separator: " ")
    }

    /// Rebuild the last listening session after launch (paused) so the mini
    /// player can offer Continue without auto-playing.
    @discardableResult
    func restorePersistedSessionIfNeeded() -> Bool {
        guard current == nil else { return false }
        guard var snap = sessionStore?.latest() else { return false }
        DromeDiagnostics.logPlayer("restore session track=\(snap.currentSong.id) elapsed=\(Int(snap.elapsed))")
        // After song-end crashes we often saved the *next* track with the
        // previous playhead (~⅓). Cold launch always starts that track at 0.
        snap.elapsed = 0
        restore(snap, seeking: false, startPlaying: false, recordPlay: false)
        return true
    }

    /// Rebuild current item when AirPlay turns on/off so FLAC raw ↔ MP3.
    private func handlePossibleAirPlayRouteChange() {
        let airPlay = isAirPlayRouteActive
        guard airPlay != lastAirPlayActive else { return }
        lastAirPlayActive = airPlay
        DromeDiagnostics.logPlayer("airPlay route → \(airPlay)")
        scheduleStreamFormatRebuild(pending: \.pendingAirPlayRebuild)
    }

    private func handlePossibleCellularStreamChange() {
        let compressed = shouldCompressForCellular
        guard compressed != lastCellularCompressed else { return }
        lastCellularCompressed = compressed
        DromeDiagnostics.logPlayer("cellular compress → \(compressed) (next track)")
        // Do NOT rebuild mid-track. Format applies on the next `setCurrent`.
        // Mid-song tear-down + seek was making cellular playback jump around.
    }

    /// User toggled Compress on cellular — rebuild current item once.
    private func rebuildForStreamPreferenceChange() {
        lastCellularCompressed = shouldCompressForCellular
        DromeDiagnostics.logPlayer("stream preference changed → rebuild")
        scheduleStreamFormatRebuild(pending: \.pendingNetworkRebuild)
    }

    private func scheduleStreamFormatRebuild(
        pending: ReferenceWritableKeyPath<PlayerEngine, Bool>
    ) {
        guard current != nil else { return }
        // Never rebuild mid song-end / buffer-wait — schedule for after.
        if isPlayerTransitioning {
            self[keyPath: pending] = true
            return
        }
        performStreamFormatRebuild()
    }

    private func performStreamFormatRebuild() {
        pendingAirPlayRebuild = false
        pendingNetworkRebuild = false
        guard current != nil else { return }
        DromeDiagnostics.logPlayer("stream format rebuild \(diagnosticStateLine())")
        let resume = wantsToPlay
        let position = max(0, elapsed)
        rebuildWindow(startPlaying: resume)
        if position > 0.5 {
            seek(to: position)
        }
    }

    private func finishRebuildSideEffects() -> Bool {
        if pendingNextCount > 0 {
            let skips = pendingNextCount
            DromeDiagnostics.logPlayer("rebuild done → coalesced advanceBy(\(skips))")
            pendingNextCount = 0
            pendingAdvanceAfterRebuild = false
            pendingConnectApply = nil
            DispatchQueue.main.async { [weak self] in
                self?.advanceBy(skips, playImmediately: true)
            }
            return true
        }
        if pendingAdvanceAfterRebuild {
            DromeDiagnostics.logPlayer("rebuild done → advanceAfterCurrentEnds")
            pendingAdvanceAfterRebuild = false
            pendingConnectApply = nil
            DispatchQueue.main.async { [weak self] in
                self?.advanceAfterCurrentEnds(playImmediately: self?.wantsToPlay == true)
            }
            return true
        }
        if let pending = pendingConnectApply {
            pendingConnectApply = nil
            DispatchQueue.main.async { [weak self] in
                self?.restore(pending.snap, seeking: true,
                              startPlaying: pending.startPlaying,
                              recordPlay: pending.recordPlay)
            }
            return true
        }
        if pendingAirPlayRebuild || pendingNetworkRebuild {
            DispatchQueue.main.async { [weak self] in
                self?.performStreamFormatRebuild()
            }
            return true
        }
        return false
    }

    /// True when the user expects audio to run after a rebuild/advance.
    private func shouldEngagePlayback(startPlaying: Bool) -> Bool {
        startPlaying || wantsToPlay
    }

    #if os(tvOS)
    /// Single front door for natural track end on Apple TV.
    private func handleTVTrackEnded() {
        guard let current else { return }
        guard tvActivePlaybackItemID == current.id else { return }
        tvActivePlaybackItemID = nil

        if isRebuilding || rebuildDepth > 0 || isHandlingTrackEnd {
            pendingAdvanceAfterRebuild = true
            DromeDiagnostics.logPlayer("tv track ended during rebuild → deferred")
            return
        }
        DromeDiagnostics.logPlayer("tv track ended → advance")
        advanceAfterCurrentEnds(playImmediately: wantsToPlay)
    }
    #endif

    /// AVPlayer / TV audio can land paused after a skip — re-assert play when intent says so.
    private func kickPlaybackIfNeeded() {
        guard shouldEngagePlayback(startPlaying: true), current != nil, !isRebuilding else { return }
        #if os(tvOS)
        if tvUsingAudioPlayer {
            if !tvAudio.isPlaying { tvAudio.play() }
            if !isPlaying { isPlaying = true }
            pushNowPlayingInfo()
            return
        }
        #endif
        playCurrentWhenReady()
    }

    private func observeNetworkStreamChanges() {
        // Path changes only update the sticky cellular flag for *next* track.
        NotificationCenter.default.publisher(for: .dromeNetworkPathChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handlePossibleCellularStreamChange()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: PlaybackPreferences.streamPreferenceDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildForStreamPreferenceChange()
            }
            .store(in: &cancellables)
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
        tvLoadTask?.cancel()
        tvLoadTask = nil
        tvActivePlaybackItemID = nil
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
    /// - Parameter clearUserQueue: When false, keeps explicitly queued tracks.
    func play(_ songs: [Song], startAt index: Int = 0, context: PlaybackContext,
              clearUserQueue: Bool = true) {
        guard songs.indices.contains(index) else { return }
        let shouldClearUserQueue = clearUserQueue && !preserveUserQueueOnce
        preserveUserQueueOnce = false
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
            if shouldClearUserQueue {
                userQueue.removeAll()
            }
            history.removeAll()
            // Direct user tap — always honor the chosen track even if low-rated.
            setCurrent(QueueItem(song: startSong), startPlaying: true, allowLowRated: true)
            ensureAutoplayBuffer()
            persistSessionSoon()
            broadcastSharePlayIfNeeded()
        }
    }

    /// Runs `action` so any nested `play` / `playShuffled` keeps the user queue.
    func performPreservingUserQueue(_ action: () -> Void) {
        preserveUserQueueOnce = true
        action()
        preserveUserQueueOnce = false
    }

    /// Shuffle-button entry point: enables shuffle (smart by default) and
    /// picks the opening track from the weighted pool too.
    func playShuffled(_ songs: [Song], context: PlaybackContext, clearUserQueue: Bool = true) {
        guard !songs.isEmpty else { return }
        let shouldClearUserQueue = clearUserQueue && !preserveUserQueueOnce
        preserveUserQueueOnce = false
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
                if shouldClearUserQueue {
                    userQueue.removeAll()
                }
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
            if shouldClearUserQueue {
                userQueue.removeAll()
            }
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
        runLocalPlayback { [self] in
            restore(snap, seeking: false, startPlaying: true, recordPlay: true)
        }
        return true
    }

    /// Resume the most recently persisted session and start playing.
    @discardableResult
    func resumeLatestSession() -> Bool {
        guard let snap = sessionStore?.latest() else { return false }
        runLocalPlayback { [self] in
            restore(snap, seeking: true, startPlaying: true, recordPlay: true)
        }
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

    private func persistSessionNow(force: Bool = false) {
        // Never snapshot mid tear-down — AVPlayer's currentTime can still be
        // the previous track while `current` already advanced.
        if !force, isPlayerTransitioning { return }
        guard let store = sessionStore, let snap = makeSessionSnapshot() else { return }
        store.save(snap)
    }

    // MARK: - Public API: transport

    func playPause() {
        if wantsToPlay { pause() } else { resume() }
    }

    func resume(bypassConnectGate: Bool = false) {
        let body = { [self] in
            AudioFocus.shared.claim(.music)
            onWillStartPlayback?()
            clearRemotePlayheadMirror()
            setPlaybackIntent(true)
            resumeAfterInterruption = false
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
        resumeAfterInterruption = false
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
        // Rapid Next while tearing down AVPlayer crashed — coalesce into one jump.
        if isHandlingTrackEnd || isRebuilding || rebuildDepth > 0 || itemReadyCancellable != nil {
            pendingNextCount += 1
            pendingAdvanceAfterRebuild = true
            DromeDiagnostics.logPlayer("next coalesced (pending=\(pendingNextCount)) \(diagnosticStateLine())")
            return
        }
        // Drop leading low-rated tracks when the user opted into global skip.
        drainLowRatedFromQueues(resyncWindow: false)
        let skips = 1 + pendingNextCount
        pendingNextCount = 0
        DromeDiagnostics.logPlayer("next advanceBy(\(skips))")
        advanceBy(skips, playImmediately: keepPlaying)
    }

    /// Skip `count` tracks with a single player rebuild (not N nested rebuilds).
    private func advanceBy(_ count: Int, playImmediately: Bool) {
        let steps = max(1, count)
        guard !isHandlingTrackEnd else {
            pendingNextCount += steps
            return
        }
        if isRebuilding || rebuildDepth > 0 {
            pendingNextCount += steps
            pendingAdvanceAfterRebuild = true
            return
        }
        isHandlingTrackEnd = true
        defer { isHandlingTrackEnd = false }

        drainLowRatedFromQueues(resyncWindow: false)

        if let current {
            history.append(current)
            scrobbleSubmission(current.song)
        }

        var landed: QueueItem?
        var skipped = 0
        while skipped < steps {
            guard let upNext = peekUpcoming(limit: 1).first else { break }
            consumeFromQueues(upNext)
            skipped += 1
            if skipped < steps {
                history.append(upNext)
            } else {
                landed = upNext
            }
        }

        if let landed {
            DromeDiagnostics.logPlayer("advanceBy(\(count)) → \(landed.song.id) «\(landed.song.title)»")
            setCurrent(landed, startPlaying: playImmediately)
            if !playImmediately {
                pinPlayheadToStart()
            }
            ensureAutoplayBuffer()
            return
        }
        if playImmediately {
            handleQueueExhausted()
        }
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
            if !keepPlaying {
                pinPlayheadToStart()
            }
            ensureAutoplayBuffer()
        } else {
            previous(preferPreviousTrack: true)
            if !keepPlaying {
                pinPlayheadToStart()
            }
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

    /// Force the visible + actual playhead to 0 after a paused skip/advance.
    private func pinPlayheadToStart() {
        setPlayhead(elapsed: 0)
        #if os(tvOS)
        if tvUsingAudioPlayer {
            tvAudio.seek(to: 0)
            return
        }
        #endif
        guard player.currentItem != nil else { return }
        let target = CMTime.zero
        seekEpoch += 1
        let epoch = seekEpoch
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekEpoch == epoch else { return }
                self.appliedSeekEpoch = epoch
                self.setPlayhead(elapsed: 0)
                self.pushNowPlayingInfo()
            }
        }
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
        guard let item = player.currentItem else { return }
        if item.status == .failed {
            itemReadyCancellable = nil
            itemReadyTimeout?.cancel()
            DromeDiagnostics.logPlayer("current item failed → skip")
            advanceAfterCurrentEnds(playImmediately: wantsToPlay)
            return
        }
        if itemIsSafeToStart(item) {
            itemReadyCancellable = nil
            itemReadyTimeout?.cancel()
            player.play()
            return
        }
        waitUntilItemReadyForPlayback(item)
        #endif
    }

    /// Hold play() until the first packets are buffered so remote audio
    /// doesn't start into an empty pipe (clicks / static / grain).
    private func waitUntilItemReadyForPlayback(_ item: AVPlayerItem) {
        itemReadyCancellable?.cancel()
        itemReadyTimeout?.cancel()
        itemReadyGeneration += 1
        let generation = itemReadyGeneration
        if itemIsSafeToStart(item) {
            player.play()
            return
        }
        let solo = current?.song.needsSoloStream == true
        let timeoutNs: UInt64 = solo ? 10_000_000_000 : 5_000_000_000
        itemReadyTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      generation == self.itemReadyGeneration,
                      item === self.player.currentItem,
                      !self.isRebuilding else { return }
                self.itemReadyCancellable = nil
                // Prefer a brief stall over forcing an empty buffer — AVPlayer
                // will fill and resume when automaticallyWaitsToMinimizeStalling.
                if item.status == .readyToPlay || self.itemIsSafeToStart(item) {
                    self.player.play()
                } else if item.status != .failed {
                    self.player.play()
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
            guard let self,
                  generation == self.itemReadyGeneration,
                  item === self.player.currentItem,
                  !self.isRebuilding else { return }
            if item.status == .failed {
                self.itemReadyTimeout?.cancel()
                self.itemReadyCancellable = nil
                DromeDiagnostics.logPlayer("item failed while waiting → skip")
                self.advanceAfterCurrentEnds(playImmediately: self.wantsToPlay)
                return
            }
            if self.itemIsSafeToStart(item) {
                self.itemReadyTimeout?.cancel()
                self.itemReadyCancellable = nil
                self.player.play()
            }
        }
    }

    /// Local files can start immediately; remote streams need a real buffer.
    private func itemIsSafeToStart(_ item: AVPlayerItem) -> Bool {
        guard item.status == .readyToPlay else { return false }
        let isFile = (item.asset as? AVURLAsset)?.url.isFileURL == true
        if isFile { return true }
        if item.isPlaybackBufferEmpty { return false }
        if item.isPlaybackLikelyToKeepUp { return true }
        let now = item.currentTime()
        guard now.isNumeric else { return false }
        let nowSec = CMTimeGetSeconds(now)
        let bufferedAhead = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .compactMap { range -> TimeInterval? in
                guard range.start.isNumeric, range.duration.isNumeric else { return nil }
                let start = CMTimeGetSeconds(range.start)
                let end = start + CMTimeGetSeconds(range.duration)
                guard end > nowSec, start <= nowSec + 0.25 else { return nil }
                return end - nowSec
            }
            .max() ?? 0
        let minBuffer: TimeInterval = (current?.song.needsSoloStream == true) ? 3.5 : 1.75
        return bufferedAhead >= minBuffer
    }

    #if os(tvOS)
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
            try? await Task.sleep(nanoseconds: 8_000_000_000)
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
        itemReadyCancellable = Publishers.Merge3(
            item.publisher(for: \.status).map { _ in () },
            item.publisher(for: \.isPlaybackLikelyToKeepUp).map { _ in () },
            item.publisher(for: \.loadedTimeRanges).map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else { return }
            if item.status == .failed {
                self.itemReadyTimeout?.cancel()
                self.itemReadyCancellable = nil
                if item === self.player.currentItem {
                    self.retryCurrentAfterDecodeFailure()
                }
                return
            }
            if self.itemIsSafeToStart(item) {
                self.itemReadyTimeout?.cancel()
                self.itemReadyCancellable = nil
                onReady()
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
                self.tvActivePlaybackItemID = nil
                try self.tvAudio.start(url: url)
                self.tvActivePlaybackItemID = queueItem?.id
                self.tvUsingAudioPlayer = true
                self.setPlaybackIntent(true)
            } catch {
                self.advanceAfterCurrentEnds(playImmediately: true)
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
        // Prefer the engine playhead during transitions; AV currentTime can lag.
        let playhead = isPlayerTransitioning ? elapsed : accurateElapsed()
        let songDuration = TimeInterval(current.song.duration ?? 0)
        let clamped: TimeInterval = {
            guard playhead.isFinite else { return 0 }
            guard songDuration > 1 else { return max(0, playhead) }
            return min(max(0, playhead), songDuration)
        }()
        var snap = PlaybackSessionSnapshot(
            resumeKey: context.resumeKey(fallbackSong: current.song),
            label: context.label,
            kind: context.kind,
            currentSong: current.song,
            elapsed: clamped,
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
        // Trim before returning so encode/copy work stays cheap on the hot path.
        snap.trimForPersistence()
        return snap
    }

    /// Snapshot for Drome Connect transfer / remote publish.
    func connectSnapshot() -> PlaybackSessionSnapshot? {
        makeSessionSnapshot()
    }

    /// Apply a Connect session from another device and optionally start playing.
    /// - Parameter force: Intentional takeControl / transfer — still waits out an
    ///   in-flight rebuild (nested `removeAllItems` crashes); applied right after.
    func applyConnectSnapshot(_ snap: PlaybackSessionSnapshot,
                              startPlaying: Bool,
                              recordPlay: Bool = true,
                              force: Bool = false) {
        // Applying a full restore tears down AVQueuePlayer. Never do that while
        // a local advance/rebuild/buffer-wait is in flight — that path crashes.
        if isPlayerTransitioning {
            if force {
                pendingConnectApply = (snap, startPlaying, recordPlay)
            }
            return
        }
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
                    self.playCurrentWhenReady()
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
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        remotePlayheadAnchor = (safeElapsed, Date(), isPlaying)
        setPlayhead(elapsed: safeElapsed, duration: safeDuration > 0 ? safeDuration : nil)
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
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.elapsed = safeElapsed
        if let newDuration, newDuration.isFinite, newDuration >= 0 {
            duration = newDuration
        }
        clock.set(elapsed: safeElapsed, duration: duration)
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
        var playItem = item
        // Collapse a streak of low-rated skips into ONE rebuild — chaining
        // async next() → removeAllItems was a common end-of-song crash.
        if !allowLowRated {
            var guardCount = 0
            while shouldSkipLowRated(playItem.song),
                  let upNext = peekUpcoming(limit: 1).first,
                  guardCount < 40 {
                history.append(playItem)
                scrobbleSubmission(playItem.song)
                consumeFromQueues(upNext)
                playItem = upNext
                guardCount += 1
            }
        }

        current = playItem
        setPlayhead(elapsed: 0, duration: TimeInterval(playItem.song.duration ?? 0))
        DromeDiagnostics.logPlayer(
            "setCurrent \(playItem.song.id) «\(playItem.song.title)» play=\(startPlaying) \(diagnosticStateLine())")
        // Pin the new track at 0 before rebuild so a crash mid-rebuild doesn't
        // restore the next song at the previous playhead (~⅓).
        persistSessionNow(force: true)
        if startPlaying {
            AudioFocus.shared.claim(.music)
            onWillStartPlayback?()
            resumeAfterInterruption = false
        }
        rebuildWindow(startPlaying: startPlaying)
        loadArtwork(for: playItem.song)
        if recordPlay {
            scrobbleNowPlaying(playItem.song)
            onTrackStarted?(playItem.song)
        }
        ensureAutoplayBuffer()
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

    /// Cellular / expensive path and user opted into compression.
    /// Only real WWAN — `isExpensive` flaps on Low Data Mode / hotspot and was
    /// flipping stream format mid-song (seek jumps that felt like skipping).
    private var shouldCompressForCellular: Bool {
        #if os(tvOS)
        return false
        #else
        guard PlaybackPreferences.compressOnCellular else { return false }
        return ConnectivityMonitor.lastIsCellular
        #endif
    }

    private func makePlayerItem(for song: Song) -> AVPlayerItem? {
        guard let url = playbackURL(for: song) else { return nil }
        return makePlayerItem(for: song, url: url)
    }

    private func playbackURL(for song: Song) -> URL? {
        #if os(tvOS)
        return tvHTTPStreamURL(for: song)
        #else
        let airPlay = isAirPlayRouteActive
        if !airPlay, let local = downloads.localURL(songId: song.id) { return local }
        if airPlay {
            return client.streamURL(songId: song.id, compatibleWithAirPlay: true)
        }
        if shouldCompressForCellular {
            return client.streamURL(
                songId: song.id,
                format: "mp3",
                maxBitRate: PlaybackPreferences.cellularMaxBitRate,
                estimateContentLength: true)
        }
        return client.streamURL(songId: song.id, compatibleWithAirPlay: false)
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
        // Hi-res FLAC needs a deep buffer; a second stream stealing the pipe is
        // what made playback sound grainy / staticy.
        if isFile {
            item.preferredForwardBufferDuration = 4
        } else if song.needsSoloStream {
            item.preferredForwardBufferDuration = 90
        } else {
            item.preferredForwardBufferDuration = 45
        }
        // Cellular MP3: shorter buffer so stalls recover without huge seeks.
        if shouldCompressForCellular, !isFile {
            item.preferredForwardBufferDuration = 20
        }
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        item.preferredPeakBitRate = 0
        return item
    }

    /// How many *upcoming* items to keep in AVQueuePlayer.
    /// Always 0: we advance via `setCurrent` rebuild. Prefetching a second
    /// HTTP stream raced end-of-track / Connect and crashed mid-listen.
    private func upcomingPrefetchCount() -> Int {
        0
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
        tvLoadTask?.cancel()
        tvLoadTask = nil
        tvActivePlaybackItemID = nil
        tvAudio.stop()
        tvUsingAudioPlayer = false
        // Do not touch AVQueuePlayer here — removeAllItems() at every track
        // boundary was crashing FigFilePlayer on HDMI (err -12864).
        window.removeAll()
        sharePlayBridge.reset()
        guard let current else {
            isRebuilding = false
            return
        }
        let song = current.song
        let queueItem = current
        let engagePlayback = shouldEngagePlayback(startPlaying: startPlaying)
        setPlaybackIntent(engagePlayback)
        activateAudioSession()
        pushNowPlayingInfo()

        if let next = peekUpcoming(limit: 1).first {
            tvCache.prefetch(next.song)
        }

        tvLoadTask = Task { @MainActor in
            await self.loadTVPlayback(
                song: song,
                queueItem: queueItem,
                generation: self.tvRebuildGeneration,
                engagePlayback: engagePlayback)
        }
    }

    /// Apple TV must never stream through AVPlayer/FigFilePlayer — it crashes on
    /// many formats (FLAC/ALAC/WAV, err -12864). Cache a complete MP3 first.
    @MainActor
    private func loadTVPlayback(
        song: Song,
        queueItem: QueueItem,
        generation: Int,
        engagePlayback: Bool
    ) async {
        func stillCurrent() -> Bool {
            generation == tvRebuildGeneration && current?.id == queueItem.id
        }

        if pendingNextCount > 0 || pendingAdvanceAfterRebuild {
            isRebuilding = false
            _ = finishRebuildSideEffects()
            return
        }

        if let cached = tvCache.cachedURL(for: song),
           startTVAudioFile(cached, song: song, queueItem: queueItem, generation: generation,
                            engagePlayback: engagePlayback) {
            return
        }

        do {
            let url = try await tvCache.fileURL(for: song)
            try Task.checkCancellation()
            guard stillCurrent() else { return }
            if pendingNextCount > 0 || pendingAdvanceAfterRebuild {
                isRebuilding = false
                _ = finishRebuildSideEffects()
                return
            }
            if startTVAudioFile(url, song: song, queueItem: queueItem, generation: generation,
                                engagePlayback: engagePlayback) {
                return
            }
            tvCache.invalidate(for: song)
        } catch {
            guard stillCurrent() else { return }
        }

        guard stillCurrent() else { return }
        isRebuilding = false
        advanceAfterCurrentEnds(playImmediately: wantsToPlay)
    }

    @discardableResult
    private func startTVAudioFile(
        _ url: URL,
        song: Song,
        queueItem: QueueItem,
        generation: Int,
        engagePlayback: Bool
    ) -> Bool {
        guard generation == tvRebuildGeneration, current?.id == queueItem.id else { return false }
        do {
            try tvAudio.start(url: url)
            tvActivePlaybackItemID = queueItem.id
            setPlaybackIntent(engagePlayback)
            if !engagePlayback { tvAudio.pause() }
            tvUsingAudioPlayer = true
            isRebuilding = false
            let duration = tvAudio.duration > 0 ? tvAudio.duration : TimeInterval(song.duration ?? 0)
            setPlayhead(elapsed: 0, duration: duration)
            pushNowPlayingInfo()
            let dispatched = finishRebuildSideEffects()
            if engagePlayback, !dispatched {
                kickPlaybackIfNeeded()
            }
            return true
        } catch {
            tvAudio.stop()
            tvUsingAudioPlayer = false
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }
    #endif

    #if !os(tvOS)
    private func rebuildWindowStreaming(startPlaying: Bool) {
        rebuildDepth += 1
        isRebuilding = true
        let engagePlayback = shouldEngagePlayback(startPlaying: startPlaying)
        DromeDiagnostics.logPlayer("rebuildWindow start play=\(engagePlayback) \(diagnosticStateLine())")
        itemReadyGeneration += 1
        prefetchTask?.cancel()
        itemReadyCancellable?.cancel()
        itemReadyCancellable = nil
        itemReadyTimeout?.cancel()
        itemReadyTimeout = nil
        // Suspend SharePlay coordination around tear-down, but do NOT
        // re-coordinateWithSession every track — that crashed the coordinator.
        let suspension = sharePlaySession.map { _ in
            player.playbackCoordinator.beginSuspension(for: .dromeRebuilding)
        }
        iosActivePlaybackItemID = nil
        window.removeAll()
        player.pause()
        player.rate = 0
        player.removeAllItems()
        sharePlayBridge.reset()

        defer {
            suspension?.end()
            rebuildDepth = max(0, rebuildDepth - 1)
            if rebuildDepth == 0 {
                isRebuilding = false
                pushNowPlayingInfo()
                DromeDiagnostics.logPlayer("rebuildWindow done \(diagnosticStateLine())")
                let dispatched = finishRebuildSideEffects()
                if engagePlayback, !dispatched {
                    kickPlaybackIfNeeded()
                }
            }
        }

        guard let current else { return }
        guard let playerItem = makePlayerItem(for: current.song) else {
            // No playable URL — skip forward once rebuild unwinds.
            pendingAdvanceAfterRebuild = true
            return
        }
        window.append((playerItem, current))
        player.insert(playerItem, after: nil)
        iosActivePlaybackItemID = current.id
        updateActionAtItemEnd()

        if engagePlayback {
            activateAudioSession()
            setPlaybackIntent(true)
        } else {
            setPlaybackIntent(false)
        }
    }
    #endif

    /// Keeps the preloaded window in sync after queue edits without touching
    /// the currently playing item (preserving gapless playback).
    private func resyncUpcomingWindow() {
        if let first = window.first {
            rebuildDepth += 1
            isRebuilding = true
            prefetchTask?.cancel()
            for entry in window.dropFirst() {
                player.remove(entry.playerItem)
            }
            window = [first]
            rebuildDepth = max(0, rebuildDepth - 1)
            if rebuildDepth == 0 { isRebuilding = false }
            updateActionAtItemEnd()
        }
        persistSessionSoon()
        broadcastSharePlayIfNeeded()
    }

    /// Tops up the window after a natural advance or delayed prefetch.
    /// Currently a no-op (upcomingPrefetchCount == 0) — kept for future local gapless.
    private func topUpWindow() {
        let targetCount = 1 + upcomingPrefetchCount()
        guard window.count < targetCount, repeatMode != .one else {
            updateActionAtItemEnd()
            return
        }
        let queued = Set(window.map(\.queueItem.id))
        for queueItem in peekUpcoming(limit: targetCount) where !queued.contains(queueItem.id) {
            if window.count >= targetCount { break }
            guard let playerItem = makePlayerItem(for: queueItem.song) else { continue }
            window.append((playerItem, queueItem))
            player.insert(playerItem, after: player.items().last)
        }
        updateActionAtItemEnd()
    }

    private func schedulePrefetchTopUp(delayNanoseconds: UInt64) {
        // Prefetch disabled — second HTTP streams raced song-end rebuilds.
        prefetchTask?.cancel()
        prefetchTask = nil
        _ = delayNanoseconds
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
                guard let self else { return }
                DromeDiagnostics.snapshotPlayer(self, note: "player-background")
                self.persistSessionNow()
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
                // While paused, ignore non-zero AVPlayer times right after a skip —
                // prefetched items often report a stale playhead until seek settles.
                if !self.wantsToPlay, seconds > 0.35, self.elapsed < 0.35 {
                    return
                }
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
                guard !self.tvUsingAudioPlayer else { return }
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
                    self.resumeAfterInterruption = false
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
    /// bookkeeping to match. With actionAtItemEnd=.pause this is uncommon;
    /// keep it for any residual multi-item windows.
    private func handleCurrentItemChange(_ item: AVPlayerItem?) {
        guard !isRebuilding, !isHandlingTrackEnd else { return }
        guard let item else {
            // Transient nil during rebuild/removeAllItems — ignore. Natural end
            // is handled by didPlayToEndTime → advanceAfterCurrentEnds.
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
        current = newCurrent
        setPlayhead(elapsed: 0, duration: TimeInterval(newCurrent.song.duration ?? 0))
        if isPlaying != wantsToPlay {
            isPlaying = wantsToPlay
        }
        if !wantsToPlay {
            pinPlayheadToStart()
        }
        updateActionAtItemEnd()
        // Prefetch disabled — avoid second-stream races at song boundaries.
        pushNowPlayingInfo()
        scrobbleNowPlaying(newCurrent.song)
        loadArtwork(for: newCurrent.song)
        onTrackStarted?(newCurrent.song)
        ensureAutoplayBuffer()
        broadcastSharePlayIfNeeded()
    }

    private func handleItemDidEnd(_ item: AVPlayerItem?) {
        #if os(tvOS)
        if tvUsingAudioPlayer { return }
        #endif
        guard let item, item === window.first?.playerItem else { return }
        guard let current, window.first?.queueItem.id == current.id else { return }
        #if !os(tvOS)
        guard iosActivePlaybackItemID == current.id else { return }
        // removeAllItems() during rebuild echoes didPlayToEndTime for the track
        // we already advanced away from — never queue a second advance from that.
        if isRebuilding || rebuildDepth > 0 {
            DromeDiagnostics.logPlayer("track ended during rebuild → ignored (spurious)")
            return
        }
        #else
        if isRebuilding || rebuildDepth > 0 {
            pendingAdvanceAfterRebuild = true
            DromeDiagnostics.logPlayer("track ended during rebuild → deferred")
            return
        }
        #endif
        if repeatMode == .one {
            player.seek(to: .zero)
            playCurrentWhenReady()
            scrobbleSubmission(current.song)
            return
        }
        #if !os(tvOS)
        iosActivePlaybackItemID = nil
        #endif
        DromeDiagnostics.logPlayer("track ended → advance")
        advanceAfterCurrentEnds(playImmediately: wantsToPlay)
    }

    /// Start the next queued song on a fresh player item. Used for Next and
    /// natural end — never AVQueuePlayer.advance (races rebuild / Connect).
    private func advanceAfterCurrentEnds(playImmediately: Bool) {
        advanceBy(1 + pendingNextCount, playImmediately: playImmediately)
        pendingNextCount = 0
    }

    private func updateActionAtItemEnd() {
        // Keep a single advance path (didPlayToEndTime / next → setCurrent).
        player.actionAtItemEnd = .pause
    }

    private func handleQueueExhausted() {
        guard let finished = current else { return }
        scrobbleSubmission(finished.song)
        if repeatMode == .all, !fullContextSongs.isEmpty, let context {
            history.append(finished)
            if shuffleMode != .off {
                playShuffled(fullContextSongs, context: context)
            } else {
                play(fullContextSongs, startAt: 0, context: context)
            }
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
            setPlaybackIntent(true)
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
        if let currentID = current?.song.id { excluding.insert(currentID) }
        let seeds = history.suffix(8).map(\.song) + [current?.song].compactMap { $0 }
        var songs = await provider.nextBatch(seeds: seeds, excluding: excluding, count: 20)
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

    private func drainLowRatedFromQueues(resyncWindow: Bool = true) {
        guard PlaybackPreferences.skipLowRatedEverywhere else { return }
        userQueue.removeAll { shouldSkipLowRated($0.song) }
        contextQueue.removeAll { shouldSkipLowRated($0.song) }
        // Skip resync when the caller is about to rebuild the window entirely
        // (next / end-of-track) — mutating AVQueuePlayer twice races and crashes.
        if resyncWindow {
            resyncUpcomingWindow()
        }
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
        nowPlaying.onPlay = { [weak self] in
            guard AudioFocus.shared.owner != .podcast else { return }
            self?.playPause()
        }
        nowPlaying.onPause = { [weak self] in
            guard AudioFocus.shared.owner != .podcast else { return }
            self?.pause()
        }
        nowPlaying.onNext = { [weak self] in
            guard AudioFocus.shared.owner != .podcast else { return }
            self?.next()
        }
        nowPlaying.onPrevious = { [weak self] in
            guard AudioFocus.shared.owner != .podcast else { return }
            self?.previous()
        }
        nowPlaying.onSeek = { [weak self] time in
            guard AudioFocus.shared.owner != .podcast else { return }
            self?.seek(to: time)
        }
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
            if sharePlayActive { return }
            // Capture intent before pause() clears wantsToPlay.
            resumeAfterInterruption = wantsToPlay || isPlaying
            if resumeAfterInterruption {
                setPlaybackIntent(false)
                #if os(tvOS)
                tvAudio.pause()
                #endif
                player.pause()
                persistSessionNow()
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
                && AudioFocus.shared.isOwner(.music)
                && current != nil
            resumeAfterInterruption = false
            if canResume {
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
        if isPlayerTransitioning {
            pendingSharePlaySnapshot = snapshot
            return
        }
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
            if snapshot.isPlaying != wantsToPlay {
                if snapshot.isPlaying {
                    resume(bypassConnectGate: true)
                } else {
                    pause()
                }
            }
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
