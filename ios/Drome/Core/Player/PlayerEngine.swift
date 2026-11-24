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
    /// What's actually playing (e.g. `MP3 · 192 kbps` on Funnel), not just library tags.
    @Published private(set) var activeStreamBadge: String?
    @Published private(set) var userQueue: [QueueItem] = []
    @Published private(set) var contextQueue: [QueueItem] = []
    @Published private(set) var history: [QueueItem] = []
    @Published private(set) var context: PlaybackContext?
    @Published private(set) var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            clock.setPlaying(isPlaying)
        }
    }
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
    /// True while the active context is the Made for you / Nonstop endless station.
    var isNonstop: Bool {
        context?.kind == .mix && context?.label == NonstopEngine.label
    }
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
    /// Bumped on every hard stop so a stale `play()` / ready callback cannot
    /// resume an outgoing item after we've already started the next track.
    private var playbackGeneration = 0
    /// Bumped to cancel in-flight ReplayGain / crossfade volume ramps.
    private var volumeFadeGeneration = 0
    private var seekEpoch = 0
    private var appliedSeekEpoch = 0
    private var autoplayTask: Task<Void, Never>?
    /// Bumped whenever in-flight autoplay work is cancelled so stale
    /// `nextBatch` results cannot rebuild the player window.
    private var autoplayGeneration = 0
    /// Session bans for the current Nonstop run (Aura Nonstop skip/dislike).
    private var nonstopSession = NonstopEngine.Session()
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
    /// Async precise-duration probe for local files (never on the play hot path).
    private var durationRefineTask: Task<Void, Never>?
    private var durationObservation: AnyCancellable?
    /// Tracks AirPlay so we only rebuild when the route actually flips.
    private var lastAirPlayActive = false
    private var pendingAirPlayRebuild = false
    /// Bluetooth / car audio — FLAC over A2DP often goes silent after the
    /// initial buffer (~45–60s); we switch to MP3 like AirPlay.
    private var lastBluetoothRoute = false
    private var pendingBluetoothRebuild = false
    #if !os(tvOS)
    /// Coalesce AirPlay / A2DP routeConfigurationChange storms before rebuilding.
    private var routeSampleTask: Task<Void, Never>?
    #endif
    /// Cellular / remote resilient stream format.
    private var lastCellularCompressed = false
    private var pendingNetworkRebuild = false
    #if !os(tvOS)
    /// Disk cache of compressed MP3 for Tailscale / cellular resilience.
    private let streamCache: StreamCache
    /// Finished original file for the next LAN track, so the changeover
    /// doesn't wait on a fresh HTTP buffer.
    private let losslessAhead: LosslessAheadCache
    private var losslessWarmTask: Task<Void, Never>?
    /// Coalesce stall recoveries so we don't rebuild in a loop.
    private var stallRecoveryTask: Task<Void, Never>?
    /// Escalation to rebuild — kept separate so soft seeks can't cancel it.
    private var stallRebuildTask: Task<Void, Never>?
    /// Waits for seekable ranges before honoring a mid-track recovery seek.
    private var deferredRecoverySeekTask: Task<Void, Never>?
    private var lastStallRecoveryAt: Date = .distantPast
    private var stallStartedAt: Date?
    /// Soft seeks attempted for the current stall episode.
    private var stallSoftSeekCount = 0
    /// After a stall rebuild, keep using MP3/cache until the next track.
    private var stallForcedResilient = false
    /// Rebuilds attempted for the current track — circuit-breaks infinite thrash.
    private var stallRebuildCountForTrack = 0
    /// Counts consecutive "playing but playhead stuck + empty buffer" ticks.
    private var silentBufferTicks = 0
    /// Last time the playhead meaningfully advanced (health / silence detector).
    private var lastPlayheadAdvanceAt: Date = .distantPast
    private var lastObservedPlayhead: TimeInterval = -1
    /// Ignore stall/silence recovery until this date (after seek/rebuild).
    private var recoveryQuietUntil: Date = .distantPast
    /// Throttle setCategory — reconfiguring every recover glitches A2DP.
    private var lastAudioSessionConfigAt: Date = .distantPast
    /// Wall-clock health probe — AVPlayer's timebase stops ticking when frozen,
    /// so the periodic time observer alone can't detect true BT silence.
    private var healthProbeCancellable: AnyCancellable?
    #endif
    private let sharePlayBridge = SharePlayCoordinatorBridge()
    private let groupStateObserver = GroupStateObserver()
    private var sharePlaySession: GroupSession<DromeListenTogether>?
    private var sharePlayMessenger: GroupSessionMessenger?
    private var sharePlaySessionTasks: [Task<Void, Never>] = []
    private var applyingSharePlay = false
    private var lastSharePlaySnapshot: SharePlaySnapshot?
    private var pendingSharePlaySnapshot: SharePlaySnapshot?
    /// True once we've applied a remote jam snapshot (or we seeded one as host).
    private var sharePlayDidSync = false
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
        #else
        self.streamCache = StreamCache(client: client)
        self.losslessAhead = LosslessAheadCache(client: client)
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
        #if !os(tvOS)
        startPlaybackHealthProbe()
        #endif
        lastAirPlayActive = isAirPlayRouteActive
        lastBluetoothRoute = isBluetoothRouteActive
        lastCellularCompressed = shouldUseResilientStream

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
        let item = player.currentItem
        let tcs: String = {
            switch player.timeControlStatus {
            case .playing: return "playing"
            case .paused: return "paused"
            case .waitingToPlayAtSpecifiedRate: return "waiting"
            @unknown default: return "unknown"
            }
        }()
        var parts = [
            "track=\(song?.id ?? "nil")",
            "«\(song?.title ?? "—")»",
            "\(String(format: "%.1f", elapsed))/\(Int(duration))s",
            "want=\(wantsToPlay)",
            "ui=\(isPlaying)",
            "tcs=\(tcs)",
            "rate=\(String(format: "%.2f", player.rate))",
            "rebuild:\(isRebuilding)/d:\(rebuildDepth)",
            "pendingNext:\(pendingNextCount)",
            "pendingAdvance:\(pendingAdvanceAfterRebuild)",
            "handlingEnd:\(isHandlingTrackEnd)",
            "window:\(window.count)",
            "resilient:\(shouldUseResilientStream)",
            "airPlay:\(isAirPlayRouteActive)",
            "bt:\(isBluetoothRouteActive)",
            "sharePlay:\(sharePlayActive)/\(sharePlayParticipantCount)",
        ]
        if let item {
            let status: String = {
                switch item.status {
                case .unknown: return "unknown"
                case .readyToPlay: return "ready"
                case .failed: return "failed"
                @unknown default: return "?"
                }
            }()
            parts.append("item=\(status)")
            parts.append("bufEmpty=\(item.isPlaybackBufferEmpty)")
            parts.append("keepUp=\(item.isPlaybackLikelyToKeepUp)")
        } else {
            parts.append("item=nil")
        }
        #if !os(tvOS)
        parts.append("path:\(ConnectivityMonitor.lastInterfaceSummary)")
        parts.append("stallRebuilds:\(stallRebuildCountForTrack)")
        parts.append("softSeek:\(stallSoftSeekCount)")
        parts.append("forcedMP3:\(stallForcedResilient)")
        parts.append("quiet:\(isInRecoveryQuietPeriod)")
        #endif
        return parts.joined(separator: " ")
    }

    /// Multi-line dump for the copy-paste support report.
    func diagnosticReportLines(note: String) -> [String] {
        let song = current?.song
        let item = player.currentItem
        let assetURL = (item?.asset as? AVURLAsset)?.url
        let urlKind: String = {
            guard let assetURL else { return "none" }
            if assetURL.isFileURL {
                return assetURL.path.contains("DromeStreamCache") ? "streamCache" : "localFile"
            }
            return "http"
        }()
        var lines: [String] = [
            "report(\(note))",
            "  track id=\(song?.id ?? "nil") title=«\(song?.title ?? "—")» artist=«\(song?.displayArtist ?? "—")»",
            "  format suffix=\(song?.suffix ?? "?") contentType=\(song?.contentType ?? "?") duration=\(song?.duration.map(String.init) ?? "?")s bitRate=\(song?.bitRate.map(String.init) ?? "?")",
            "  playhead elapsed=\(String(format: "%.2f", elapsed)) accurate=\(String(format: "%.2f", accurateElapsed())) duration=\(String(format: "%.2f", duration))",
            "  intent wantsToPlay=\(wantsToPlay) isPlaying=\(isPlaying) rate=\(String(format: "%.2f", player.rate)) tcs=\(player.timeControlStatus.rawValue)",
            "  queues user=\(userQueue.count) context=\(contextQueue.count) history=\(history.count) window=\(window.count) contextLabel=\(context?.label ?? "nil")",
            "  transport rebuild=\(isRebuilding) depth=\(rebuildDepth) handlingEnd=\(isHandlingTrackEnd) pendingNext=\(pendingNextCount) pendingAdvance=\(pendingAdvanceAfterRebuild)",
            "  seek epoch=\(seekEpoch)/applied=\(appliedSeekEpoch)",
            "  routes airPlay=\(isAirPlayRouteActive) bluetooth=\(isBluetoothRouteActive) resilient=\(shouldUseResilientStream)",
            "  sharePlay active=\(sharePlayActive) participants=\(sharePlayParticipantCount) synced=\(sharePlayDidSync)",
            "  source kind=\(urlKind) url=\(DromeDiagnostics.redactedURL(assetURL))",
        ]
        if let item {
            let err = item.error.map { "\($0.localizedDescription)" } ?? "nil"
            lines.append("  item status=\(item.status.rawValue) bufEmpty=\(item.isPlaybackBufferEmpty) keepUp=\(item.isPlaybackLikelyToKeepUp) error=\(err)")
            let loaded = item.loadedTimeRanges
                .map(\.timeRangeValue)
                .map { r -> String in
                    let s = CMTimeGetSeconds(r.start)
                    let d = CMTimeGetSeconds(r.duration)
                    return String(format: "%.1f+%.1f", s, d)
                }
                .joined(separator: ",")
            lines.append("  loadedRanges=[\(loaded)]")
        } else {
            lines.append("  item=nil")
        }
        #if !os(tvOS)
        lines.append(
            "  stall rebuilds=\(stallRebuildCountForTrack) softSeek=\(stallSoftSeekCount) forcedResilient=\(stallForcedResilient) quiet=\(isInRecoveryQuietPeriod) silentTicks=\(silentBufferTicks)")
        lines.append(
            "  stallStarted=\(stallStartedAt.map { String(format: "%.1fsAgo", Date().timeIntervalSince($0)) } ?? "nil") lastRecover=\(String(format: "%.1fsAgo", Date().timeIntervalSince(lastStallRecoveryAt)))")
        if let song, let cached = streamCache.cachedURL(
            for: song.id,
            minimumBytes: Self.minimumStreamCacheBytes(for: song)) {
            lines.append("  streamCache=hit \(DromeDiagnostics.redactedURL(cached))")
        } else if song != nil {
            lines.append("  streamCache=miss")
        }
        #endif
        let session = AVAudioSession.sharedInstance()
        let outs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        lines.append("  audioSession category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=[\(outs)]")
        lines.append("  audioFocus=\(AudioFocus.shared.owner == .music ? "music" : AudioFocus.shared.owner == .podcast ? "podcast" : "none")")
        return lines
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

    /// Debounce AirPlay / A2DP route flaps, then rebuild only when the stable
    /// route needs a different stream format (FLAC ↔ AirPlay/A2DP MP3).
    private func scheduleRouteFormatSample(reassertPlay: Bool = false) {
        #if os(tvOS)
        // tvOS has no AirPlay/A2DP format swap — only soft-reseat when asked.
        if reassertPlay, wantsToPlay {
            activateAudioSession()
            playCurrentWhenReady()
        }
        #else
        routeSampleTask?.cancel()
        routeSampleTask = Task { @MainActor [weak self] in
            // AirPlay fires several routeConfigurationChange events in a few
            // hundred ms while negotiating. Wait for a stable sample.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled else { return }
            self.commitRouteFormatIfNeeded(reassertPlay: reassertPlay)
        }
        #endif
    }

    private func commitRouteFormatIfNeeded(reassertPlay: Bool) {
        #if os(tvOS)
        return
        #else
        let airPlay = isAirPlayRouteActive
        let bluetooth = isBluetoothRouteActive
        let airFlip = airPlay != lastAirPlayActive
        let btFlip = bluetooth != lastBluetoothRoute
        guard airFlip || btFlip || reassertPlay else { return }

        if airFlip {
            DromeDiagnostics.logPlayer(
                "airPlay route stable → \(airPlay) outputs=\(Self.routeSummary)")
            lastAirPlayActive = airPlay
        }
        if btFlip {
            DromeDiagnostics.logIncident(
                "bluetooth route stable → \(bluetooth) outputs=\(Self.routeSummary)",
                player: self)
            lastBluetoothRoute = bluetooth
            configureAudioSession()
        }

        if airFlip || btFlip {
            if currentStreamNeedsFormatRebuild() {
                let pending: ReferenceWritableKeyPath<PlayerEngine, Bool> =
                    airFlip ? \.pendingAirPlayRebuild : \.pendingBluetoothRebuild
                scheduleStreamFormatRebuild(pending: pending)
                return
            }
            DromeDiagnostics.logPlayer(
                "route flipped but stream format already matches — skip rebuild")
        }

        // Soft re-seat after a handoff that didn't need a new URL.
        if wantsToPlay, !isRebuilding, reassertPlay || btFlip || airFlip {
            activateAudioSession()
            playCurrentWhenReady()
        }
        #endif
    }

    /// True when the live item's format class differs from what `playbackURL`
    /// would pick for the current route (skip no-op AirPlay↔BT rebuilds).
    private func currentStreamNeedsFormatRebuild() -> Bool {
        guard let song = current?.song else { return false }
        let desired = desiredStreamFormatSignature(for: song)
        guard let current = currentStreamFormatSignature() else { return true }
        return current != desired
    }

    private func desiredStreamFormatSignature(for song: Song) -> String {
        #if os(tvOS)
        return "tv"
        #else
        let airPlay = isAirPlayRouteActive
        let bluetooth = isBluetoothRouteActive
        if !airPlay, !sharePlayActive, downloads.localURL(songId: song.id) != nil {
            return "local"
        }
        let wantCompressed = shouldUseResilientStream || bluetooth
        if !airPlay, !sharePlayActive, wantCompressed,
           streamCache.cachedURL(
            for: song.id,
            minimumBytes: Self.minimumStreamCacheBytes(for: song)) != nil {
            return "cache-mp3"
        }
        if airPlay || bluetooth || sharePlayActive {
            return "server-mp3-320"
        }
        if shouldUseResilientStream {
            return "server-mp3-\(resilientMaxBitRate)"
        }
        return "server-raw"
        #endif
    }

    private func currentStreamFormatSignature() -> String? {
        guard let song = current?.song,
              let url = (player.currentItem?.asset as? AVURLAsset)?.url else {
            return nil
        }
        if url.isFileURL {
            if downloads.localURL(songId: song.id) == url { return "local" }
            return "cache-mp3"
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let format = items.first(where: { $0.name == "format" })?.value ?? "raw"
        if format == "mp3" {
            let br = items.first(where: { $0.name == "maxBitRate" })?.value ?? "?"
            return "server-mp3-\(br)"
        }
        if format == "raw" { return "server-raw" }
        return "server-\(format)"
    }

    private func handlePossibleCellularStreamChange(regained: Bool = false) {
        let compressed = shouldUseResilientStream
        if compressed != lastCellularCompressed {
            let wasCompressed = lastCellularCompressed
            lastCellularCompressed = compressed
            if wasCompressed, !compressed {
                // Upgraded to LAN / Wi‑Fi — rebuild onto FLAC now.
                DromeDiagnostics.logPlayer("resilient stream → off (LAN/Wi‑Fi) → rebuild FLAC")
                scheduleStreamFormatRebuild(pending: \.pendingNetworkRebuild)
            } else {
                // Downgrade to MP3 waits for the next track to avoid mid-song stutter.
                DromeDiagnostics.logPlayer("resilient stream → \(compressed) (next track)")
            }
        }
        #if !os(tvOS)
        if regained, wantsToPlay {
            DromeDiagnostics.logPlayer("network regained → stall check \(diagnosticStateLine())")
            // Pierce quiet period — we may have been mid-rebuild when the path died.
            scheduleStallRecovery(reason: "network-regained", force: true)
        }
        // Keep warm-caching upcoming tracks whenever the path is usable.
        if ConnectivityMonitor.lastIsOnline {
            prefetchUpcomingIntoCache()
        }
        #endif
    }

    /// User toggled Compress / resilient prefs — rebuild current item once.
    private func rebuildForStreamPreferenceChange() {
        lastCellularCompressed = shouldUseResilientStream
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
        // Hold off while a prior rebuild's quiet period is still cooling —
        // route sampling already debounce flaps before we get here.
        #if !os(tvOS)
        if isInRecoveryQuietPeriod {
            self[keyPath: pending] = true
            return
        }
        #endif
        performStreamFormatRebuild()
    }

    private func performStreamFormatRebuild() {
        pendingAirPlayRebuild = false
        pendingNetworkRebuild = false
        pendingBluetoothRebuild = false
        guard current != nil else { return }
        // Align last* with the live route so a flap mid-rebuild doesn't
        // immediately queue the opposite format.
        lastAirPlayActive = isAirPlayRouteActive
        #if !os(tvOS)
        lastBluetoothRoute = isBluetoothRouteActive
        #endif
        DromeDiagnostics.logPlayer("stream format rebuild \(diagnosticStateLine())")
        configureAudioSession(force: true)
        let resume = wantsToPlay
        #if !os(tvOS)
        let position = recoveryElapsed()
        // Shorter quiet than stall recovery — format swaps should feel snappy.
        beginRecoveryQuietPeriod(2.0)
        // Seek before audible play so we don't start at 0 then jump.
        rebuildWindow(startPlaying: false)
        if resume { setPlaybackIntent(true) }
        if position > 0.5 {
            seekWhenSeekable(to: position, thenPlay: resume)
        } else if resume {
            kickPlaybackIfNeeded()
        }
        #else
        let position = max(0, elapsed)
        rebuildWindow(startPlaying: resume)
        if position > 0.5 {
            seek(to: position)
        }
        #endif
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
        if pendingAirPlayRebuild || pendingNetworkRebuild || pendingBluetoothRebuild {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let networkPending = self.pendingNetworkRebuild
                self.pendingAirPlayRebuild = false
                self.pendingBluetoothRebuild = false
                self.pendingNetworkRebuild = false
                // Re-read the live route after quiet — drop no-op flip-flops.
                self.lastAirPlayActive = self.isAirPlayRouteActive
                #if !os(tvOS)
                self.lastBluetoothRoute = self.isBluetoothRouteActive
                #endif
                if networkPending || self.currentStreamNeedsFormatRebuild() {
                    self.performStreamFormatRebuild()
                } else {
                    DromeDiagnostics.logPlayer(
                        "coalesced route rebuild skipped — format matches")
                    if self.wantsToPlay {
                        self.playCurrentWhenReady()
                    }
                }
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

    /// Fully detach audible output before swapping tracks.
    ///
    /// `pause` + `removeAllItems` alone is not enough on Bluetooth headphones —
    /// the outgoing item's already-decoded PCM can keep draining into A2DP while
    /// the next item starts, so two songs play at once. Mute first, cancel seeks,
    /// and nil the current item before clearing the queue.
    private func silenceAndClearPlayerQueue(reason: String) {
        playbackGeneration += 1
        itemReadyGeneration += 1
        itemReadyCancellable?.cancel()
        itemReadyCancellable = nil
        itemReadyTimeout?.cancel()
        itemReadyTimeout = nil
        player.pause()
        player.rate = 0
        if player.volume > 0.001 {
            player.volume = 0
        }
        for entry in window {
            entry.playerItem.cancelPendingSeeks()
        }
        if let item = player.currentItem {
            item.cancelPendingSeeks()
        }
        #if !os(tvOS)
        iosActivePlaybackItemID = nil
        #endif
        player.replaceCurrentItem(with: nil)
        player.removeAllItems()
        window.removeAll()
        DromeDiagnostics.logPlayer("silence+clear (\(reason)) gen=\(playbackGeneration)")
    }

    private func restorePlayerOutputVolume() {
        if player.volume < 0.999 {
            player.volume = 1
        }
    }

    private func observeNetworkStreamChanges() {
        NotificationCenter.default.publisher(for: .dromeNetworkPathChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let regained = (note.userInfo?["regained"] as? Bool) ?? false
                self?.handlePossibleCellularStreamChange(regained: regained)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: PlaybackPreferences.streamPreferenceDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildForStreamPreferenceChange()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AudioFXPreferences.audioFXDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyAudioFXVolume()
                self?.refreshEqualizerOnWindow()
            }
            .store(in: &cancellables)

        #if !os(tvOS)
        NotificationCenter.default.publisher(for: AudioFocus.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Re-assert Now Playing + remote surface after podcast ↔ music swaps.
                guard let self, AudioFocus.shared.isOwner(.music) else { return }
                self.pushNowPlayingInfo()
            }
            .store(in: &cancellables)
        #endif
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
        #else
        clearStallRecoveryState(resetForcedResilient: true)
        deferredRecoverySeekTask?.cancel()
        deferredRecoverySeekTask = nil
        healthProbeCancellable?.cancel()
        healthProbeCancellable = nil
        routeSampleTask?.cancel()
        routeSampleTask = nil
        #endif
        silenceAndClearPlayerQueue(reason: "shutdown")
        restorePlayerOutputVolume()
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
            if context.label != NonstopEngine.label {
                nonstopSession.reset()
            }
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

    /// Swap into a new mix / vibe queue without tearing down the current item.
    /// Used by Instant Mix / Vibe Tuner so the song you are already hearing
    /// keeps playing while Up Next becomes the new mix.
    func adoptUpcomingMix(
        _ songs: [Song],
        context: PlaybackContext,
        clearUserQueue: Bool = true
    ) {
        guard let current else {
            guard !songs.isEmpty else { return }
            play(songs, startAt: 0, context: context, clearUserQueue: clearUserQueue)
            return
        }
        let upcoming = songs.filter { $0.id != current.song.id }
        runLocalPlayback { [self] in
            pushSessionUndoIfNeeded()
            cancelAutoplayWork()
            ratings.ingest([current.song] + upcoming)
            // Fresh mix order — don't inherit a prior shuffle mode that would
            // reshuffle the curated vibe picks under the user.
            if shuffleMode != .off {
                suppressShuffleReorder = true
                shuffleMode = .off
                suppressShuffleReorder = false
            }
            self.context = context
            fullContextSongs = [current.song] + upcoming
            originalContextOrder = upcoming.map { QueueItem(song: $0) }
            contextQueue = originalContextOrder
            if clearUserQueue {
                userQueue.removeAll()
            }
            // Leave `current`, history, and AVPlayer alone — no rebuild.
            resyncUpcomingWindow()
            ensureAutoplayBuffer()
            persistSessionSoon()
            broadcastSharePlayIfNeeded()
            pushNowPlayingInfo()
        }
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

            // ShuffleEngine keeps OOR out of algorithmic pools, but falls back
            // to the full list when every track is excluded so Shuffle still
            // shuffles (instead of silently playing in order).
            let pool = orderedForShuffle(songs)
            guard let first = pool.first else { return }
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

    /// Seeds mini-player / now-playing chrome without starting AVPlayer.
    /// Used by `-UITestWalk` so XCUITest can open music Now Playing offline.
    func adoptSongForChrome(
        _ song: Song,
        elapsed: TimeInterval = 0,
        playing: Bool = false
    ) {
        let item = QueueItem(song: song)
        current = item
        context = PlaybackContext(label: "UITest", kind: .mix)
        contextQueue = []
        userQueue = [QueueItem(song: Song(
            id: "uitest-song-next",
            title: "UITest Up Next",
            album: song.album,
            artist: song.artist,
            duration: 180))]
        setPlayhead(elapsed: elapsed, duration: TimeInterval(song.duration ?? 0))
        setPlaybackIntent(playing)
        activeStreamBadge = "UITest · 320 kbps"
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
        // Nonstop: two early skips of the same artist leave them out of this run.
        if isNonstop, elapsed < NonstopEngine.earlySkipSeconds {
            let artist = current?.song.artistId ?? current?.song.artist
            nonstopSession.recordEarlySkip(artist: artist)
            if let artist, nonstopSession.bannedArtists.contains(artist) {
                removeUpcoming(matchingArtist: artist)
            }
        }
        // Drop leading low-rated tracks when the user opted into global skip.
        drainLowRatedFromQueues(resyncWindow: false)
        let skips = 1 + pendingNextCount
        pendingNextCount = 0
        DromeDiagnostics.logPlayer("next advanceBy(\(skips))")
        advanceBy(skips, playImmediately: keepPlaying)
    }

    /// “Not for this station” — song out for this Nonstop; artist twice bans upcoming.
    func dislikeNonstopSong() {
        guard isNonstop, let song = current?.song else { return }
        let bannedArtists = nonstopSession.dislike(song: song)
        for artist in bannedArtists {
            removeUpcoming(matchingArtist: artist)
        }
        // Also drop this exact song if it was re-queued.
        contextQueue.removeAll { $0.song.id == song.id }
        userQueue.removeAll { $0.song.id == song.id }
        next()
    }

    /// Start Aura-style Nonstop: open on liked/seed tracks, refill forever.
    func startNonstop(seeds: [Song] = []) {
        nonstopSession.reset()
        autoplayEnabled = true
        let opening = NonstopEngine.opening(
            from: seeds,
            excludedGenres: MadeForYouPreferences.excludedGenres)
        let context = PlaybackContext(label: NonstopEngine.label, kind: .mix)
        if opening.isEmpty {
            // Empty seed — kick Infinite Shuffle and label it Nonstop once audio lands.
            self.context = context
            continueWithAutoplayIfNeeded(playImmediately: true)
            return
        }
        play(opening, startAt: 0, context: context)
        ensureAutoplayBuffer()
    }

    private func removeUpcoming(matchingArtist artist: String) {
        guard !artist.isEmpty else { return }
        let matches: (Song) -> Bool = { song in
            song.artistId == artist || song.artist == artist
        }
        contextQueue.removeAll { matches($0.song) }
        userQueue.removeAll { matches($0.song) }
        resyncUpcomingWindow()
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
        // Same coalesce as `next()` — never nest removeAllItems / replace while
        // a rebuild is already tearing the queue down (dual-audio on BT).
        if isHandlingTrackEnd || isRebuilding || rebuildDepth > 0 {
            if goingNext {
                pendingNextCount += 1
                pendingAdvanceAfterRebuild = true
            }
            return
        }
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
            player.rate = 0
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
        let generation = playbackGeneration
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
            guard generation == playbackGeneration, item === player.currentItem else { return }
            restorePlayerOutputVolume()
            player.play()
            return
        }
        waitUntilItemReady(item) { [weak self] in
            guard let self, generation == self.playbackGeneration else { return }
            self.playCurrentWhenReady()
        }
        #else
        guard let item = player.currentItem else { return }
        if item.status == .failed {
            itemReadyCancellable = nil
            itemReadyTimeout?.cancel()
            if recoverFailedItemOrSkip(reason: "current-item-failed") { return }
            return
        }
        // Downloaded / local files: play immediately. Waiting on readyToPlay with
        // PreferPreciseDuration forced multi-second FLAC probes before any sound.
        let isFile = (item.asset as? AVURLAsset)?.url.isFileURL == true
        if isFile {
            itemReadyCancellable = nil
            itemReadyTimeout?.cancel()
            guard generation == playbackGeneration, item === player.currentItem else { return }
            player.automaticallyWaitsToMinimizeStalling = false
            restorePlayerOutputVolume()
            player.play()
            return
        }
        player.automaticallyWaitsToMinimizeStalling = true
        if itemIsSafeToStart(item) {
            itemReadyCancellable = nil
            itemReadyTimeout?.cancel()
            guard generation == playbackGeneration, item === player.currentItem else { return }
            restorePlayerOutputVolume()
            player.play()
            return
        }
        waitUntilItemReadyForPlayback(item, playbackGeneration: generation)
        #endif
    }

    #if !os(tvOS)
    /// Hold play() until the first packets are buffered so remote audio
    /// doesn't start into an empty pipe (clicks / static / grain).
    /// tvOS uses `waitUntilItemReady` + `retryCurrentAfterDecodeFailure` instead.
    private func waitUntilItemReadyForPlayback(
        _ item: AVPlayerItem,
        playbackGeneration expectedPlayback: Int
    ) {
        itemReadyCancellable?.cancel()
        itemReadyTimeout?.cancel()
        itemReadyGeneration += 1
        let generation = itemReadyGeneration
        if itemIsSafeToStart(item) {
            guard expectedPlayback == playbackGeneration, item === player.currentItem else { return }
            restorePlayerOutputVolume()
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
                      expectedPlayback == self.playbackGeneration,
                      item === self.player.currentItem,
                      !self.isRebuilding else { return }
                self.itemReadyCancellable = nil
                if item.status == .failed {
                    _ = self.recoverFailedItemOrSkip(reason: "ready-timeout-failed")
                } else if self.itemIsSafeToStart(item) || item.status == .readyToPlay {
                    // readyToPlay with a thin buffer is OK — AVPlayer will wait.
                    self.restorePlayerOutputVolume()
                    self.player.play()
                } else {
                    // Do NOT force-play into a totally empty pipe (1s blip → stall loop).
                    DromeDiagnostics.logPlayer("ready-timeout without buffer → stall recover")
                    self.scheduleStallRecovery(reason: "ready-timeout", force: true)
                }
                self.flushPendingSharePlaySnapshotIfNeeded()
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
                  expectedPlayback == self.playbackGeneration,
                  item === self.player.currentItem,
                  !self.isRebuilding else { return }
            if item.status == .failed {
                self.itemReadyTimeout?.cancel()
                self.itemReadyCancellable = nil
                if self.recoverFailedItemOrSkip(reason: "item-failed-waiting") {
                    self.flushPendingSharePlaySnapshotIfNeeded()
                    return
                }
                self.flushPendingSharePlaySnapshotIfNeeded()
                return
            }
            if self.itemIsSafeToStart(item) {
                self.itemReadyTimeout?.cancel()
                self.itemReadyCancellable = nil
                self.restorePlayerOutputVolume()
                self.player.play()
                self.flushPendingSharePlaySnapshotIfNeeded()
            }
        }
    }
    #endif

    /// Local files can start immediately; remote streams need a real buffer.
    private func itemIsSafeToStart(_ item: AVPlayerItem) -> Bool {
        let isFile = (item.asset as? AVURLAsset)?.url.isFileURL == true
        if isFile { return item.status != .failed }
        guard item.status == .readyToPlay else { return false }
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
        let minBuffer: TimeInterval
        if sharePlayActive {
            minBuffer = 0.75
        } else if current?.song.needsSoloStream == true {
            minBuffer = 3.5
        } else {
            minBuffer = 1.75
        }
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

    /// Copy only the slice that will be persisted. Connect publishes this
    /// snapshot on a timer; mapping a multi-thousand-song queue first and
    /// trimming after wasted a main-thread pass on every publish.
    private static func snapshotSongs(_ items: [QueueItem], limit: Int, tail: Bool) -> [Song] {
        guard items.count > limit else { return items.map(\.song) }
        let slice = tail ? items.suffix(limit) : items.prefix(limit)
        return slice.map(\.song)
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
            history: Self.snapshotSongs(history, limit: 40, tail: true),
            userQueue: Self.snapshotSongs(userQueue, limit: 50, tail: false),
            contextQueue: Self.snapshotSongs(contextQueue, limit: 120, tail: false),
            originalContextOrder: Self.snapshotSongs(originalContextOrder, limit: 120, tail: false),
            fullContextSongs: Array(fullContextSongs.prefix(160)),
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
        seek(to: time, clampToPartialSeekable: true)
    }

    /// - Parameter clampToPartialSeekable: User scrubbing should stay inside the
    ///   currently buffered window. Stall-recovery seeks must NOT — clamping a
    ///   mid/late-track resume to a 5s seekable window is what made songs jump
    ///   back to a "random" early position after a rebuild.
    private func seek(to time: TimeInterval, clampToPartialSeekable: Bool) {
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

        let itemDuration = resolvedItemDuration(fallback: max(time, 0))

        // Seeking exactly to duration often stalls the item without advancing.
        let maxSeekable = max(0, itemDuration - 0.35)
        var seconds = min(max(0, time), maxSeekable)

        if clampToPartialSeekable,
           let range = item.seekableTimeRanges.last?.timeRangeValue {
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            // Only clamp into a partial buffer when the seekable window clearly
            // does not cover the target. Clamping to an early estimate of "end"
            // is what made scrub-to-end land several seconds early.
            if start.isFinite, end.isFinite, end > start,
               !PlaybackResilience.seekableCovers(target: seconds, seekableEnd: end) {
                seconds = min(max(seconds, start), max(start, end - 0.35))
            }
        }

        let requested = seconds
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        seekEpoch += 1
        let epoch = seekEpoch
        let shouldResume = player.timeControlStatus == .playing
            || player.rate > 0
            || isPlaying
            || wantsToPlay

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
                // Never publish ~0 when we asked for a mid-track seek — the item
                // often still reports 0 until the seek finishes decoding.
                let nextElapsed: TimeInterval
                if actual.isFinite, actual >= 0,
                   !(requested > 2.0 && actual < 0.75) {
                    nextElapsed = actual
                } else {
                    nextElapsed = requested
                }
                let itemDuration = self.player.currentItem?.duration.seconds
                let reported = (itemDuration?.isFinite == true && (itemDuration ?? 0) > 0)
                    ? itemDuration : nil
                self.setPlayhead(elapsed: nextElapsed, duration: reported)
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

    /// Resume at `time` only once the new item can actually seek there.
    private func seekWhenSeekable(to time: TimeInterval, thenPlay: Bool) {
        #if os(tvOS)
        seek(to: time)
        if thenPlay { kickPlaybackIfNeeded() }
        return
        #else
        deferredRecoverySeekTask?.cancel()
        let target = max(0, time)
        setPlayhead(elapsed: target)
        lastObservedPlayhead = target
        lastPlayheadAdvanceAt = .distantPast

        if tryCommitRecoverySeek(to: target, thenPlay: thenPlay) { return }

        deferredRecoverySeekTask = Task { [weak self] in
            for _ in 0..<40 { // ~10s @ 250ms
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let done = await MainActor.run {
                    self?.tryCommitRecoverySeek(to: target, thenPlay: thenPlay) ?? true
                }
                if done { return }
            }
            await MainActor.run {
                guard let self else { return }
                DromeDiagnostics.logPlayer(
                    "recovery seek timeout → force pos=\(Int(target))s")
                self.seek(to: target, clampToPartialSeekable: false)
                if thenPlay {
                    self.activateAudioSession()
                    self.playCurrentWhenReady()
                }
            }
        }
        #endif
    }

    /// Returns true once a recovery seek has been issued (or is impossible).
    private func tryCommitRecoverySeek(to target: TimeInterval, thenPlay: Bool) -> Bool {
        guard let item = player.currentItem, item.status != .failed else { return false }
        let isFile = (item.asset as? AVURLAsset)?.url.isFileURL == true
        if isFile {
            seek(to: target, clampToPartialSeekable: false)
            if thenPlay {
                activateAudioSession()
                playCurrentWhenReady()
            }
            return true
        }
        let seekableEnd = item.seekableTimeRanges.last.flatMap { range -> TimeInterval? in
            let end = CMTimeRangeGetEnd(range.timeRangeValue).seconds
            return end.isFinite ? end : nil
        }
        let durationReady = item.duration.seconds.isFinite && item.duration.seconds >= target - 1
        let covered = PlaybackResilience.seekableCovers(
            target: target, seekableEnd: seekableEnd)
        // Wait until the buffered/seekable window reaches the resume point.
        // Seeking earlier clamps into a short window → "random" early resume.
        guard item.status == .readyToPlay else { return false }
        if !covered, target > 2 { return false }
        guard covered || durationReady else { return false }
        seek(to: target, clampToPartialSeekable: false)
        if thenPlay {
            activateAudioSession()
            playCurrentWhenReady()
        }
        return true
    }

    /// Sticky playhead for stall recovery — never trust a mid-track AV zero.
    private func recoveryElapsed() -> TimeInterval {
        PlaybackResilience.recoveryElapsed(accurate: accurateElapsed(), published: elapsed)
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
        setPlayhead(
            elapsed: safeElapsed,
            duration: safeDuration > 0 ? safeDuration : nil,
            resetDuration: true)
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

    /// - Parameter resetDuration: New track / remote adopt — drop the previous
    ///   song's length before reconciling, otherwise grow-only logic would keep
    ///   a longer prior duration on a shorter next track.
    private func setPlayhead(
        elapsed: TimeInterval,
        duration newDuration: TimeInterval? = nil,
        resetDuration: Bool = false
    ) {
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.elapsed = safeElapsed
        if resetDuration {
            duration = 0
        }
        let metadata = TimeInterval(current?.song.duration ?? 0)
        let reported: TimeInterval? = {
            if let newDuration, newDuration.isFinite, newDuration > 0 { return newDuration }
            return nil
        }()
        // Grow-only reconcile so short library tags / VBR estimates can't pin
        // the scrubber at "0 left" while the file is still playing.
        duration = PlaybackResilience.reconciledDuration(
            metadata: metadata,
            reported: reported,
            elapsed: safeElapsed,
            current: duration)
        clock.set(elapsed: safeElapsed, duration: duration, playing: isPlaying)
    }

    /// Resolved length for seek clamps and UI — never shorter than the live playhead.
    private func resolvedItemDuration(fallback: TimeInterval = 0) -> TimeInterval {
        let live = player.currentItem?.duration.seconds
        let reported = (live?.isFinite == true && (live ?? 0) > 0) ? live : nil
        return PlaybackResilience.reconciledDuration(
            metadata: TimeInterval(current?.song.duration ?? 0),
            reported: reported,
            elapsed: max(elapsed, accurateElapsed()),
            current: duration > 0 ? duration : fallback)
    }

    /// After playback has started, refine duration so the scrubber matches the
    /// real file. Precise probes stay off the tap-to-play path (FLAC cost).
    private func refineDurationMatchingSong(for item: AVPlayerItem, song: Song) {
        durationRefineTask?.cancel()
        durationObservation?.cancel()
        let songID = song.id

        durationObservation = item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cmDuration in
                guard let self, self.current?.song.id == songID else { return }
                let seconds = CMTimeGetSeconds(cmDuration)
                guard seconds.isFinite, seconds > 0 else { return }
                self.setPlayhead(elapsed: self.elapsed, duration: seconds)
            }

        guard let urlAsset = item.asset as? AVURLAsset, urlAsset.url.isFileURL else { return }
        durationRefineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Brief yield so decode/start wins over the duration probe.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, self.current?.song.id == songID else { return }
            guard let cmDuration = try? await urlAsset.load(.duration) else { return }
            let seconds = CMTimeGetSeconds(cmDuration)
            guard seconds.isFinite, seconds > 0 else { return }
            self.setPlayhead(elapsed: self.elapsed, duration: seconds)
        }
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
        playNext([song])
    }

    /// Insert songs at the front of the user queue (first song plays soonest).
    func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        ratings.ingest(songs)
        let items = songs.map { QueueItem(song: $0) }
        if current == nil {
            runLocalPlayback { [self] in
                userQueue.insert(contentsOf: items, at: 0)
                let item = userQueue.removeFirst()
                setCurrent(item, startPlaying: true, allowLowRated: true)
                resyncUpcomingWindow()
            }
            return
        }
        userQueue.insert(contentsOf: items, at: 0)
        resyncUpcomingWindow()
    }

    func addToQueue(_ song: Song) {
        addToQueue([song])
    }

    /// Append songs to the end of the user queue.
    func addToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        ratings.ingest(songs)
        let items = songs.map { QueueItem(song: $0) }
        if current == nil {
            runLocalPlayback { [self] in
                userQueue.append(contentsOf: items)
                let item = userQueue.removeFirst()
                setCurrent(item, startPlaying: true, allowLowRated: true)
                resyncUpcomingWindow()
            }
            return
        }
        userQueue.append(contentsOf: items)
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
        setPlayhead(
            elapsed: 0,
            duration: TimeInterval(playItem.song.duration ?? 0),
            resetDuration: true)
        #if !os(tvOS)
        clearStallRecoveryState(resetForcedResilient: true)
        #endif
        DromeDiagnostics.logPlayer(
            "setCurrent \(playItem.song.id) «\(playItem.song.title)» play=\(startPlaying) \(diagnosticStateLine())")
        if startPlaying {
            AudioFocus.shared.claim(.music)
            onWillStartPlayback?()
            resumeAfterInterruption = false
        }
        // Play first — session pin / artwork / scrobble used to run before
        // rebuild and added noticeable delay on downloaded taps.
        rebuildWindow(startPlaying: startPlaying)
        applyAudioFXVolume(animated: false)
        // Pin playhead at 0 after insert so a crash mid-rebuild doesn't restore
        // the next song at the previous playhead (~⅓).
        persistSessionNow(force: true)
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

    /// Bluetooth A2DP / HFP / LE headphones and car audio.
    private var isBluetoothRouteActive: Bool {
        #if os(tvOS)
        return false
        #else
        let types: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio,
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            types.contains($0.portType)
        }
        #endif
    }

    private static var routeSummary: String {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
    }

    /// Prefer compressed MP3 when on cellular, or when streaming from a
    /// Tailscale / non-LAN host with resilient mode on. Raw FLAC over a flaky
    /// VPN is what made "music dies after a network hop" feel permanent.
    private var shouldUseResilientStream: Bool {
        #if os(tvOS)
        return false
        #else
        // Stall recovery forces MP3/cache for the rest of this track so a
        // rebuild doesn't just reattach the same dying HTTP pipe.
        if stallForcedResilient { return true }
        // Dual-stack phones often report cellular even on Wi‑Fi — only
        // compress when there's no Wi‑Fi/Ethernet path.
        if PlaybackPreferences.compressOnCellular, ConnectivityMonitor.lastIsCellularOnly {
            return true
        }
        if PlaybackPreferences.resilientRemoteStreaming {
            // Use the *active* base URL (home LAN after reachability), not
            // the away serverURL — otherwise LAN home streaming still got MP3.
            if !PlaybackPreferences.isLocalNetworkHost(activeStreamHost) {
                return true
            }
        }
        return false
        #endif
    }

    /// Host we're actually talking to right now (home LAN when preferred).
    private var activeStreamHost: String? {
        client.baseURL.host ?? client.account.homeURL?.host ?? client.account.serverURL.host
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
        let bluetooth = isBluetoothRouteActive
        // Local files decode on-device — fine over A2DP. AirPlay still needs a
        // remote MP3 (can't ship local FLAC to the Apple TV / speaker).
        // SharePlay also prefers remote MP3 so both phones buffer at similar rates.
        if !airPlay, !sharePlayActive, let local = downloads.localURL(songId: song.id) {
            return local
        }
        // Prefer a warm stream-cache MP3 only when we'd stream compressed
        // anyway (remote / cellular / BT). On LAN Wi‑Fi, skip the cache so
        // we don't keep playing leftover MP3 instead of FLAC.
        let wantCompressed = shouldUseResilientStream || bluetooth
        if !airPlay, !sharePlayActive, wantCompressed,
           let cached = streamCache.cachedURL(
            for: song.id,
            minimumBytes: Self.minimumStreamCacheBytes(for: song)) {
            return cached
        }
        // AirPlay, Bluetooth, and SharePlay prefer server-side MP3 — faster to
        // start, and A2DP/coordination stay reliable past the first buffer.
        if airPlay || bluetooth || sharePlayActive {
            return client.streamURL(songId: song.id, compatibleWithAirPlay: true)
        }
        if shouldUseResilientStream {
            return client.streamURL(
                songId: song.id,
                format: "mp3",
                maxBitRate: resilientMaxBitRate,
                estimateContentLength: true)
        }
        // A finished original on disk starts like a download. Anything still
        // downloading is ignored — playback stays on HTTP until the file is whole.
        if let ahead = losslessAhead.cachedURL(for: song.id) {
            return ahead
        }
        return client.streamURL(songId: song.id, compatibleWithAirPlay: false)
        #endif
    }

    /// 192 kbps on Funnel/remote hosts; 256 on cellular against LAN.
    private var resilientMaxBitRate: Int {
        PlaybackPreferences.preferredMaxBitRate(serverHost: activeStreamHost)
    }

    private var remoteAwareCoverSize: Int {
        PlaybackPreferences.clampedCoverSize(1200, serverHost: activeStreamHost)
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
        activeStreamBadge = Self.streamQualityBadge(
            for: song,
            url: url,
            resilientBitRate: resilientMaxBitRate)
        // Never force precise duration on the hot path — library metadata is
        // good enough for UI, and probing FLAC delayed every downloaded tap.
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ])
        let item = AVPlayerItem(asset: asset)
        sharePlayBridge.remember(item, identity: Self.sharePlayContentID(for: song))
        // Hi-res FLAC needs a deep buffer on the network; local files should
        // start with no artificial forward-buffer wait.
        if isFile {
            item.preferredForwardBufferDuration = 0
        } else if sharePlayActive {
            // Coordinated playback waits for every phone — keep the buffer lean
            // so one slow FLAC fill doesn't stall the whole jam.
            item.preferredForwardBufferDuration = 12
        } else if song.needsSoloStream {
            item.preferredForwardBufferDuration = 90
        } else if shouldUseResilientStream {
            // Deeper buffer on Tailscale/cellular so short blips don't underrun.
            item.preferredForwardBufferDuration = 60
        } else if isBluetoothRouteActive {
            // Shorter buffer on BT so underruns surface as stalls (recoverable)
            // instead of ~50s of silent "playing" after the first fill.
            item.preferredForwardBufferDuration = 15
        } else {
            item.preferredForwardBufferDuration = 45
        }
        // Keep filling while paused (route changes, brief background) so resume
        // after a Tailscale hop isn't starting from an empty pipe.
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = !isFile
        item.preferredPeakBitRate = 0
        // Real 5-band EQ via PCM tap (Flat = bypass). ReplayGain stays on volume.
        EqualizerProcessor.shared.attach(to: item)
        return item
    }

    /// Re-apply EQ mix when faders / presets change without rebuilding the queue.
    private func refreshEqualizerOnWindow() {
        for entry in window {
            EqualizerProcessor.shared.attach(to: entry.playerItem)
        }
    }

    /// Badge for the bytes actually playing (transcoded MP3 vs library FLAC).
    static func streamQualityBadge(for song: Song, url: URL, resilientBitRate: Int) -> String? {
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            if ext == "mp3" {
                return "MP3 · \(resilientBitRate) kbps"
            }
            if !ext.isEmpty {
                // Downloaded original (or other local file) — library tags win.
                return song.qualityBadge ?? ext.uppercased()
            }
            return song.qualityBadge
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let format = items.first { $0.name == "format" }?.value?.lowercased()
        let maxBitRate = items.first { $0.name == "maxBitRate" }?.value.flatMap(Int.init)
        if format == "mp3" {
            let br = maxBitRate ?? resilientBitRate
            return br > 0 ? "MP3 · \(br) kbps" : "MP3"
        }
        if format == "aac" {
            let br = maxBitRate ?? 256
            return br > 0 ? "AAC · \(br) kbps" : "AAC"
        }
        if let format, !format.isEmpty, format != "raw" {
            return format.uppercased()
        }
        return song.qualityBadge
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
            setPlayhead(elapsed: 0, duration: duration, resetDuration: true)
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
        durationRefineTask?.cancel()
        durationRefineTask = nil
        durationObservation?.cancel()
        durationObservation = nil
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
        sharePlayBridge.reset()
        // Mute + detach before inserting the next item so Bluetooth headphones
        // cannot keep draining the previous track's buffer alongside the new one.
        silenceAndClearPlayerQueue(reason: "rebuild")

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
                flushPendingSharePlaySnapshotIfNeeded()
            }
        }

        guard let current else { return }
        guard let playerItem = makePlayerItem(for: current.song) else {
            // No playable URL — skip forward once rebuild unwinds.
            pendingAdvanceAfterRebuild = true
            return
        }
        window.append((playerItem, current))
        player.replaceCurrentItem(with: playerItem)
        iosActivePlaybackItemID = current.id
        updateActionAtItemEnd()
        refineDurationMatchingSong(for: playerItem, song: current.song)

        if engagePlayback {
            activateAudioSession()
            setPlaybackIntent(true)
        } else {
            setPlaybackIntent(false)
        }
        // Let the new item buffer before stall/silence detectors can fire.
        // Do NOT pretend the playhead advanced — that aborted recovery while
        // we were still sitting on a clamped early seek after rebuild.
        let playingLocal = (playerItem.asset as? AVURLAsset)?.url.isFileURL == true
        beginRecoveryQuietPeriod(engagePlayback ? (playingLocal ? 6.0 : 3.0) : 1.0)
        lastObservedPlayhead = -1
        lastPlayheadAdvanceAt = .distantPast
        prefetchUpcomingIntoCache()
        // Warm the current track into the disk cache in the background so a
        // later Tailscale / BT blip can rebuild onto a local file.
        let song = current.song
        let shouldWarm = !playingLocal && (shouldUseResilientStream || isBluetoothRouteActive)
        if shouldWarm, streamCache.cachedURL(for: song.id) == nil {
            Task { [weak self] in
                _ = try? await self?.streamCache.fileURL(
                    for: song, maxBitRate: resilientMaxBitRate)
            }
        }
        scheduleLosslessAhead()
    }

    /// After the current track is up, pull the next original onto disk.
    /// Waits a couple of seconds so the playhead buffer wins the network.
    private func scheduleLosslessAhead() {
        losslessWarmTask?.cancel()
        losslessWarmTask = nil
        guard !shouldUseResilientStream,
              !isAirPlayRouteActive,
              !isBluetoothRouteActive,
              !sharePlayActive,
              let next = peekUpcoming(limit: 1).first?.song
        else { return }
        if downloads.localURL(songId: next.id) != nil { return }
        if losslessAhead.cachedURL(for: next.id) != nil { return }
        losslessWarmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.current != nil, !self.shouldUseResilientStream else { return }
            self.losslessAhead.prefetch(next)
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
                    // Don't flip intent from coordinator/route blips — only
                    // reflect UI when we already wanted to play (or remote Play
                    // already set wantsToPlay). Surprise .playing must not
                    // un-pause the user.
                    if self.wantsToPlay, !self.isPlaying {
                        self.isPlaying = true
                    }
                    #if !os(tvOS)
                    // Playhead progress is the health signal — not keepUp, which
                    // flickers false constantly on HTTP streams and caused 1s
                    // play→rebuild thrash when we cleared/armed on keepUp alone.
                    // Do NOT clear stallStartedAt on barren .playing flickers —
                    // waiting↔playing thrash was resetting the 2.5s stall clock
                    // forever so recovery never armed.
                    if self.wantsToPlay, self.playheadRecentlyAdvanced(within: 1.5) {
                        self.clearStallRecoveryState(resetForcedResilient: false)
                    }
                    #endif
                case .waitingToPlayAtSpecifiedRate:
                    // Buffering — keep the button on the sticky intent.
                    if self.isPlaying != self.wantsToPlay {
                        self.isPlaying = self.wantsToPlay
                    }
                    #if !os(tvOS)
                    // Brief waits after a seek/underrun are normal. Only arm
                    // recovery when the playhead has actually stopped.
                    if self.wantsToPlay,
                       !self.isInRecoveryQuietPeriod,
                       !self.playheadRecentlyAdvanced(within: 1.25) {
                        if self.stallStartedAt == nil {
                            self.stallStartedAt = Date()
                            self.stallSoftSeekCount = 0
                            DromeDiagnostics.logPlayer("stall begin \(self.diagnosticStateLine())")
                        }
                        self.scheduleStallRecovery(reason: "waiting")
                    }
                    #endif
                case .paused:
                    #if !os(tvOS)
                    if !self.isRebuilding, !self.wantsToPlay {
                        self.clearStallRecoveryState(resetForcedResilient: false)
                    }
                    #endif
                    if self.isRebuilding || self.wantsToPlay {
                        // Transient pause during skip/rebuild — do not flip UI.
                        if self.isPlaying != self.wantsToPlay {
                            self.isPlaying = self.wantsToPlay
                        }
                        #if !os(tvOS)
                        // Sticky play intent with a paused AVPlayer is the
                        // "isn't playing at all" dead state — re-kick soon.
                        // Skip while a local file is still opening (precise FLAC
                        // probes used to trip this and rebuild mid-start).
                        if !self.isRebuilding, !self.isInRecoveryQuietPeriod {
                            let loadingLocal: Bool = {
                                guard let item = self.player.currentItem,
                                      let url = (item.asset as? AVURLAsset)?.url,
                                      url.isFileURL else { return false }
                                return item.status == .unknown
                            }()
                            if !loadingLocal {
                                self.scheduleStallRecovery(reason: "paused-wanting", force: true)
                            }
                        }
                        #endif
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
                #if !os(tvOS)
                // Health checks must run even when the playhead is stuck — the
                // UI throttle below used to skip them, hiding real stalls while
                // false keepUp flickers during healthy play still fired recovery.
                self.notePlayheadProgress(seconds)
                self.checkPlaybackHealth()
                #endif
                // Skip tiny updates to cut SwiftUI churn while audio stays smooth.
                if abs(seconds - self.lastPublishedElapsed) < 0.2,
                   abs(seconds - self.elapsed) < 0.2 {
                    return
                }
                self.lastPublishedElapsed = seconds
                let itemDuration = self.player.currentItem?.duration.seconds
                let reported = (itemDuration?.isFinite == true && (itemDuration ?? 0) > 0)
                    ? itemDuration : nil
                self.setPlayhead(elapsed: seconds, duration: reported)
                self.applyMixTransitionFadeIfNeeded(elapsed: seconds)
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
                #else
                let err = failed.error?.localizedDescription ?? "unknown"
                DromeDiagnostics.logIncident("failedToPlayToEnd \(err)", player: self)
                // Hard failure — don't go through the coalesced stall scheduler
                // (quiet periods / min-interval used to swallow these entirely).
                _ = self.recoverFailedItemOrSkip(reason: "failedToEnd")
                #endif
            }
            .store(in: &cancellables)

        #if !os(tvOS)
        NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard let stalled = notification.object as? AVPlayerItem,
                      stalled === self.player.currentItem,
                      self.wantsToPlay else { return }
                DromeDiagnostics.logPlayer("playbackStalled → recover")
                self.scheduleStallRecovery(reason: "stalled", force: true)
            }
            .store(in: &cancellables)
        #endif

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
                DromeDiagnostics.logPlayer(
                    "routeChange reason=\(String(describing: reason)) outputs=\(Self.routeSummary)")
                if reason == .oldDeviceUnavailable {
                    // Only pause when we lost the *output* route entirely (e.g.
                    // headphones unplugged with no fallback speaker yet). Bluetooth
                    // handoffs often fire this then immediately re-route — don't
                    // leave music paused/silent after a reconnect.
                    let stillHasOutput = !AVAudioSession.sharedInstance()
                        .currentRoute.outputs.isEmpty
                    if stillHasOutput {
                        // Debounced sample + soft play reassert — avoid immediate
                        // configure/play kicks that fight AirPlay negotiation.
                        self.scheduleRouteFormatSample(reassertPlay: self.wantsToPlay)
                    } else {
                        self.resumeAfterInterruption = false
                        self.pause()
                    }
                    return
                }
                // Entering/leaving AirPlay or Bluetooth may need FLAC ↔ MP3.
                // Do NOT reconfigure the session or force-play on every
                // routeConfigurationChange — AirPlay storms were pausing/playing
                // mid-buffer and looking like the route "moved" on its own.
                if reason == .newDeviceAvailable || reason == .routeConfigurationChange {
                    #if os(iOS)
                    _ = HeadphoneEQProfiles.applyForCurrentRouteIfNeeded()
                    #endif
                    #if os(tvOS)
                    // Keep a light session re-seat on TV; no format debounce path.
                    self.configureAudioSession()
                    if self.wantsToPlay {
                        self.activateAudioSession()
                        if self.player.timeControlStatus != .playing {
                            self.playCurrentWhenReady()
                        }
                    }
                    #else
                    self.scheduleRouteFormatSample()
                    #endif
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
        setPlayhead(
            elapsed: 0,
            duration: TimeInterval(newCurrent.song.duration ?? 0),
            resetDuration: true)
        if isPlaying != wantsToPlay {
            isPlaying = wantsToPlay
        }
        if !wantsToPlay {
            pinPlayheadToStart()
        }
        updateActionAtItemEnd()
        let fadeIn = AudioFXPreferences.resolvedCrossfadeSeconds(for: newCurrent.song) > 0
            && !shouldKeepGapless(from: history.last?.song, to: newCurrent.song)
        applyAudioFXVolume(animated: fadeIn)
        // Prefetch disabled — avoid second-stream races at song boundaries.
        pushNowPlayingInfo()
        scrobbleNowPlaying(newCurrent.song)
        loadArtwork(for: newCurrent.song)
        onTrackStarted?(newCurrent.song)
        ensureAutoplayBuffer()
        broadcastSharePlayIfNeeded()
    }

    /// ReplayGain → AVQueuePlayer.volume. EQ is applied in the PCM tap, not here.
    private func applyAudioFXVolume(animated: Bool = false) {
        let target = min(1.0, AudioFXController.shared.volume(for: current?.song))
        volumeFadeGeneration &+= 1
        let fadeID = volumeFadeGeneration
        let seconds = AudioFXPreferences.resolvedCrossfadeSeconds(for: current?.song)
        if animated, seconds > 0 {
            // Soft rise from ~half level — not near-silence (0.05 felt like cutouts).
            let start = max(0.45, min(player.volume, target) * 0.7)
            player.volume = start
            let steps = max(6, seconds * 10)
            let stepDuration = Double(seconds) / Double(steps)
            for i in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration * Double(i)) { [weak self] in
                    guard let self, self.volumeFadeGeneration == fadeID else { return }
                    let t = Float(i) / Float(steps)
                    self.player.volume = start + (target - start) * t
                }
            }
        } else if abs(player.volume - target) > 0.001 {
            // Skip no-op writes — assigning volume mid-play can click under
            // heavy UI (e.g. Search + keyboard) even when the gain is unchanged.
            player.volume = target
        }
    }

    /// Soft / beat-aligned mix: fade the outgoing track down before it ends so
    /// the next track's fade-in overlaps perceptually (AVQueuePlayer can't dual-play).
    private func applyMixTransitionFadeIfNeeded(elapsed: TimeInterval) {
        guard wantsToPlay, let song = current?.song else { return }
        let seconds = AudioFXPreferences.resolvedCrossfadeSeconds(for: song)
        guard seconds > 0 else { return }
        let total = duration > 1 ? duration : TimeInterval(song.duration ?? 0)
        guard total > Double(seconds) + 2 else { return }
        let remaining = total - elapsed
        guard remaining > 0, remaining <= Double(seconds) else { return }

        let nextSong = peekUpcoming(limit: 1).first?.song
        if shouldKeepGapless(from: song, to: nextSong) { return }

        let target = min(1.0, AudioFXController.shared.volume(for: song))
        let t = Float(remaining / Double(seconds))
        let faded = max(0.05, target * t)
        if abs(player.volume - faded) > 0.02 {
            player.volume = faded
        }
    }

    /// Same-album contiguous tracks stay gapless even when mix transitions are on.
    private func shouldKeepGapless(from a: Song?, to b: Song?) -> Bool {
        guard let a, let b else { return false }
        if let albumA = a.albumId, let albumB = b.albumId, !albumA.isEmpty, albumA == albumB {
            return true
        }
        return false
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
        // Out of Rotation listening: library Infinite Shuffle never returns
        // these tracks, so reshuffle the same collection to keep the vibe.
        if sticksToOutOfRotationPool, autoplayEnabled, repeatMode == .off,
           !fullContextSongs.isEmpty, let context {
            setPlaybackIntent(true)
            if shuffleMode != .off {
                playShuffled(fullContextSongs, context: context, clearUserQueue: false)
            } else {
                play(fullContextSongs, startAt: 0, context: context, clearUserQueue: false)
            }
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
        if sticksToOutOfRotationPool {
            extendOutOfRotationContextIfNeeded(force: true)
        } else {
            maybeExtendWithAutoplay(force: true)
        }
    }

    // MARK: - Shuffle

    private func orderedForShuffle(_ songs: [Song]) -> [Song] {
        let excluded = (context?.allowsOutOfRotation ?? false) ? [] : rotation.excludedIDs
        let taste = TasteAffinity.build(
            ratings: ratings.ratings,
            seeds: Array(songs.prefix(40)),
            knownSongs: songs,
            memory: ratings.memory)
        return ShuffleEngine.order(songs, mode: shuffleMode,
                                   rating: { [weak self] in self?.ratings.rating(for: $0) ?? 0 },
                                   excluded: excluded,
                                   taste: taste)
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
            let eligible = contextQueue.filter { !excluded.contains($0.song.id) }
            // Same as ShuffleEngine: if the whole remaining queue is OOR,
            // reshuffle it rather than emptying Up Next.
            let kept = eligible.isEmpty ? contextQueue : eligible
            let taste = TasteAffinity.build(
                ratings: ratings.ratings,
                seeds: kept.prefix(40).map(\.song),
                knownSongs: kept.map(\.song),
                memory: ratings.memory)
            let songs = ShuffleEngine.order(kept.map(\.song), mode: shuffleMode,
                                            rating: { [weak self] in self?.ratings.rating(for: $0) ?? 0 },
                                            excluded: excluded,
                                            taste: taste)
            var byID: [String: [QueueItem]] = Dictionary(grouping: kept, by: { $0.song.id })
            contextQueue = songs.compactMap { byID[$0.id]?.popLast() }
        }
        resyncUpcomingWindow()
    }

    // MARK: - Autoplay (Infinite Shuffle)

    /// True when the active collection is Out of Rotation (system playlist, or
    /// a playlist that is entirely OOR). Library Infinite Shuffle excludes
    /// these tracks, so we must keep reshuffling this pool instead.
    private var sticksToOutOfRotationPool: Bool {
        ShuffleEngine.sticksToOutOfRotationPool(
            allowsOutOfRotation: context?.allowsOutOfRotation == true,
            contextSongIDs: fullContextSongs.map(\.id),
            excludedIDs: rotation.excludedIDs)
    }

    /// Keeps a healthy upcoming buffer whenever Infinite Shuffle is on.
    /// Call after jumps / play / advances so the last track never leaves an
    /// empty Up Next list.
    private func ensureAutoplayBuffer() {
        guard !applyingSharePlay, autoplayEnabled, repeatMode == .off, current != nil else { return }
        let upcoming = userQueue.count + contextQueue.count
        // Refill early — never wait until the queue is already empty.
        if upcoming < 8 {
            if sticksToOutOfRotationPool {
                extendOutOfRotationContextIfNeeded(force: upcoming < 3)
            } else {
                maybeExtendWithAutoplay(force: upcoming < 3)
            }
        }
    }

    /// Top up Up Next from the same Out of Rotation collection (smart/random
    /// shuffle), never from library Infinite Shuffle.
    ///
    /// Only queues tracks not yet heard this lap. When the lap is done,
    /// `handleQueueExhausted` reshuffles the whole collection.
    private func extendOutOfRotationContextIfNeeded(force: Bool = false) {
        guard !applyingSharePlay, autoplayEnabled, repeatMode == .off, current != nil else { return }
        let upcoming = userQueue.count + contextQueue.count
        if !force {
            guard upcoming < 8 else { return }
        }
        guard !fullContextSongs.isEmpty else { return }

        var excluding = Set(userQueue.map(\.song.id))
        excluding.formUnion(contextQueue.map(\.song.id))
        if let currentID = current?.song.id { excluding.insert(currentID) }
        excluding.formUnion(history.map(\.song.id))

        let unplayed = fullContextSongs.filter { !excluding.contains($0.id) }
        guard !unplayed.isEmpty else { return }

        let ordered = orderedForShuffle(unplayed)
        let need = max(8 - upcoming, force ? 5 : 1)
        let addition = ordered.prefix(need).map { QueueItem(song: $0) }
        guard !addition.isEmpty else { return }
        contextQueue.append(contentsOf: addition)
        topUpWindow()
        broadcastSharePlayIfNeeded()
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

        if sticksToOutOfRotationPool, !fullContextSongs.isEmpty, let context {
            if playImmediately {
                setPlaybackIntent(true)
                if shuffleMode != .off {
                    playShuffled(fullContextSongs, context: context, clearUserQueue: false)
                } else {
                    play(fullContextSongs, startAt: 0, context: context, clearUserQueue: false)
                }
            } else {
                extendOutOfRotationContextIfNeeded(force: true)
            }
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
        if sticksToOutOfRotationPool {
            extendOutOfRotationContextIfNeeded(force: force)
            return
        }
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

        let useNonstop = isNonstop
        let sessionSnapshot = nonstopSession
        autoplayGeneration += 1
        let generation = autoplayGeneration
        autoplayTask = Task { [weak self] in
            let songs: [Song]
            if useNonstop {
                songs = await provider.nonstopBatch(
                    seeds: seeds, excluding: excluding, session: sessionSnapshot, count: 20)
            } else {
                songs = await provider.nextBatch(seeds: seeds, excluding: excluding, count: 20)
            }
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
        let songs: [Song]
        if isNonstop {
            songs = await provider.nonstopBatch(
                seeds: seeds, excluding: excluding, session: nonstopSession, count: 20)
        } else {
            songs = await provider.nextBatch(seeds: seeds, excluding: excluding, count: 20)
        }
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
        // Playing Out of Rotation on purpose — do not strip the queue down to
        // empty and fall into library Infinite Shuffle after the first song.
        if sticksToOutOfRotationPool { return }
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
        // Explicit OOR listening: 1–2★ tracks are the collection, not skips.
        if sticksToOutOfRotationPool { return false }
        let r = ratings.rating(for: song)
        return (1...2).contains(r)
    }

    private func removeAutoplayTail() {
        contextQueue.removeAll(where: \.isAutoplay)
        resyncUpcomingWindow()
    }

    // MARK: - System integration

    private func configureAudioSession(force: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        #if !os(tvOS)
        // Podcasts leave .spokenAudio sticky — never throttle past that, or
        // music keeps HFP and goes silent after ~1 buffer on Bluetooth.
        let stuckOnSpokenAudio = session.mode == .spokenAudio && !sharePlayActive
        let mustForce = force || stuckOnSpokenAudio
        // Re-setCategory on every stall recover used to glitch Bluetooth A2DP.
        if !mustForce, Date().timeIntervalSince(lastAudioSessionConfigAt) < 1.0 {
            try? session.setActive(true, options: [])
            return
        }
        lastAudioSessionConfigAt = Date()
        #endif
        if sharePlayActive {
            // Mix with FaceTime so Drome can play on each phone during the call.
            try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        } else {
            #if os(tvOS)
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            #else
            // Always re-apply .playback/.default — podcasts leave .spokenAudio
            // sticky, which can force Bluetooth HFP and go silent after ~1 buffer.
            try? session.setCategory(
                .playback,
                mode: .default,
                options: [.allowBluetoothA2DP])
            #endif
        }
        try? session.setActive(true, options: [])
    }

    private func activateAudioSession() {
        // Force when clearing leftover podcast spokenAudio; otherwise throttle.
        #if os(tvOS)
        configureAudioSession()
        #else
        let force = AVAudioSession.sharedInstance().mode == .spokenAudio
        configureAudioSession(force: force)
        #endif
    }

    private func configureRemoteCommands() {
        nowPlaying.configureCommands()
        // Play must resume (not toggle) — the old playPause wiring paused
        // mid-buffer when CarPlay / lock screen re-sent Play.
        nowPlaying.onPlay = { [weak self] in
            guard AudioFocus.shared.isOwner(.music) else { return }
            self?.resume()
        }
        nowPlaying.onPause = { [weak self] in
            guard AudioFocus.shared.isOwner(.music) else { return }
            self?.pause()
        }
        nowPlaying.onToggle = { [weak self] in
            guard AudioFocus.shared.isOwner(.music) else { return }
            self?.playPause()
        }
        nowPlaying.onNext = { [weak self] in
            guard AudioFocus.shared.isOwner(.music) else { return }
            self?.next()
        }
        nowPlaying.onPrevious = { [weak self] in
            guard AudioFocus.shared.isOwner(.music) else { return }
            self?.previous()
        }
        nowPlaying.onSeek = { [weak self] time in
            guard AudioFocus.shared.isOwner(.music) else { return }
            self?.seek(to: time)
        }
    }

    private func pushNowPlayingInfo() {
        // NowPlayingCenter no-ops / refuses to clear when podcast owns focus.
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
        let coverSize = remoteAwareCoverSize
        let remoteURL: URL? = candidates.lazy
            .compactMap { self.client.coverArtURL(id: $0, size: coverSize) }
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
                    guard let self else { break }
                    guard let alt = self.client.coverArtURL(id: id, size: self.remoteAwareCoverSize) else { continue }
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
            DromeDiagnostics.logPlayer(
                "interruption began resumeAfter=\(resumeAfterInterruption) \(diagnosticStateLine())")
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
            DromeDiagnostics.logPlayer(
                "interruption ended shouldResume=\(shouldResume) canResume=\(canResume)")
            if canResume {
                resume()
            }
        @unknown default:
            break
        }
    }

    #if !os(tvOS)
    /// One resilient rebuild before skipping a failed item. Avoids dumping the
    /// rest of a track after a long underrun killed the HTTP AVPlayerItem.
    @discardableResult
    private func recoverFailedItemOrSkip(reason: String) -> Bool {
        guard wantsToPlay, let current else {
            DromeDiagnostics.logPlayer("\(reason) → skip (no current)")
            advanceAfterCurrentEnds(playImmediately: wantsToPlay)
            return true
        }
        // Second failure while a rebuild is already in flight must NOT skip —
        // that race turned one bad packet into an immediate track change.
        if isRebuilding || rebuildDepth > 0 {
            DromeDiagnostics.logPlayer("\(reason) → ignored (rebuild in flight)")
            return false
        }
        let position = recoveryElapsed()
        if PlaybackResilience.shouldAdvanceNearEnd(position: position, duration: duration) {
            DromeDiagnostics.logPlayer("\(reason) near end → advance")
            advanceAfterCurrentEnds(playImmediately: wantsToPlay)
            return true
        }
        // Drop any stream-cache file we were playing — a truncated MP3 is the
        // classic "1 second then fail" source, and rebuild must not reuse it.
        if let url = (player.currentItem?.asset as? AVURLAsset)?.url,
           url.isFileURL,
           url.path.contains("DromeStreamCache") {
            streamCache.invalidate(songID: current.song.id)
            DromeDiagnostics.logPlayer("\(reason) → invalidated stream cache")
        } else if let url = (player.currentItem?.asset as? AVURLAsset)?.url,
                  url.isFileURL,
                  url.path.contains("DromeLosslessAhead") {
            losslessAhead.invalidate(songID: current.song.id)
            DromeDiagnostics.logPlayer("\(reason) → invalidated lossless ahead cache")
        }
        if stallRebuildCountForTrack < PlaybackResilience.maxRebuildsPerTrack {
            DromeDiagnostics.logPlayer("\(reason) → resilient rebuild")
            rebuildFromCacheOrStream(position: position, reason: reason)
            return true
        }
        DromeDiagnostics.logPlayer("\(reason) → skip")
        advanceAfterCurrentEnds(playImmediately: wantsToPlay)
        return true
    }

    private static func minimumStreamCacheBytes(for song: Song) -> Int {
        PlaybackResilience.minimumStreamCacheBytes(durationSeconds: song.duration)
    }

    private func isHardFailureReason(_ reason: String) -> Bool {
        PlaybackResilience.isHardFailure(reason)
    }

    private func scheduleStallRecovery(reason: String, force: Bool = false) {
        guard wantsToPlay, current != nil, !isRebuilding else { return }
        let hard = isHardFailureReason(reason)
        // Quiet period protects healthy buffering — never swallow hard failures.
        if isInRecoveryQuietPeriod, !hard { return }
        if !force, !hard, let started = stallStartedAt, Date().timeIntervalSince(started) < 2.5 {
            return
        }
        // Coalesce even forced recovers — playbackStalled used to fire every
        // ~400ms with force:true, cancelling the rebuild escalation forever.
        let minInterval: TimeInterval = hard ? 1.0 : (force ? 2.5 : 4.5)
        if Date().timeIntervalSince(lastStallRecoveryAt) < minInterval { return }
        stallRecoveryTask?.cancel()
        stallRecoveryTask = Task { [weak self] in
            // Give the buffer a moment on transient waits.
            if hard {
                try? await Task.sleep(nanoseconds: 200_000_000)
            } else if !force {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.performStallRecovery(reason: reason)
            }
        }
    }

    private func performStallRecovery(reason: String) {
        guard wantsToPlay, let current, !isRebuilding else { return }
        let hard = isHardFailureReason(reason)
        if isInRecoveryQuietPeriod, !hard { return }

        // Playhead still moving ⇒ audio pipeline is alive. Bail out.
        if !hard, playheadRecentlyAdvanced(within: 2.0) {
            if player.timeControlStatus == .playing {
                clearStallRecoveryState(resetForcedResilient: false)
            }
            return
        }

        let item = player.currentItem
        if !hard,
           player.timeControlStatus == .playing,
           reason != "silent-buffer",
           item?.isPlaybackBufferEmpty != true {
            clearStallRecoveryState(resetForcedResilient: false)
            return
        }

        lastStallRecoveryAt = Date()
        let position = recoveryElapsed()
        DromeDiagnostics.logIncident(
            "stall-recover:\(reason) pos=\(Int(position))s softSeek=\(stallSoftSeekCount) rebuilds=\(stallRebuildCountForTrack)",
            player: self)

        // Near the end, advance — soft-seek/rebuild here restarts or clamps oddly.
        if PlaybackResilience.shouldAdvanceNearEnd(position: position, duration: duration) {
            DromeDiagnostics.logPlayer("stall near end → advance")
            clearStallRecoveryState(resetForcedResilient: false)
            advanceAfterCurrentEnds(playImmediately: wantsToPlay)
            return
        }

        // Sticky play intent + paused transport: re-assert play() first. Soft
        // seeking a fully buffered ready item just thrashes the seek epoch.
        if reason == "paused-wanting",
           player.currentItem?.status == .readyToPlay {
            beginRecoveryQuietPeriod(2.0)
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
            kickPlaybackIfNeeded()
            armStallRebuildEscalation(position: position, reason: reason)
            return
        }

        // Soft seek at most once per stall episode. Further stalls / failed
        // items go to a cache-or-MP3 rebuild. Keep escalation on a separate
        // task so another playbackStalled can't cancel it.
        let hasCachedFile = streamCache.cachedURL(
            for: current.song.id,
            minimumBytes: Self.minimumStreamCacheBytes(for: current.song)) != nil
        let canSoftSeek = player.currentItem != nil
            && player.currentItem?.status != .failed
            && PlaybackResilience.canSoftSeek(
                softSeekCount: stallSoftSeekCount,
                rebuildCount: stallRebuildCountForTrack,
                reason: reason,
                hasCachedFile: hasCachedFile)

        if canSoftSeek {
            stallSoftSeekCount += 1
            beginRecoveryQuietPeriod(2.5)
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
            seek(to: position, clampToPartialSeekable: false)
            playCurrentWhenReady()
            armStallRebuildEscalation(position: position, reason: reason)
            return
        }

        rebuildFromCacheOrStream(position: position, reason: reason)
    }

    /// Follow-up rebuild if a soft seek didn't unstick playback.
    private func armStallRebuildEscalation(position: TimeInterval, reason: String) {
        guard stallRebuildTask == nil else { return }
        stallRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.stallRebuildTask = nil
                guard self.wantsToPlay, !self.isRebuilding else { return }
                if self.isInRecoveryQuietPeriod {
                    // Soft seek / playhead jump extended quiet past this timer —
                    // re-arm so we don't abort recovery forever.
                    let delay = max(0.3, self.recoveryQuietUntil.timeIntervalSinceNow + 0.3)
                    self.stallRebuildTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard let self else { return }
                            self.stallRebuildTask = nil
                            self.armStallRebuildEscalation(position: position, reason: reason)
                        }
                    }
                    return
                }
                // Require a stuck playhead — never escalate on keepUp flicker.
                guard !self.playheadRecentlyAdvanced(within: 2.0) else { return }
                let item = self.player.currentItem
                let stillStuck = self.player.timeControlStatus != .playing
                    || item?.isPlaybackBufferEmpty == true
                    || item?.status == .failed
                guard stillStuck else { return }
                self.rebuildFromCacheOrStream(position: position, reason: "\(reason)-retry")
            }
        }
    }

    private func clearStallRecoveryState(resetForcedResilient: Bool) {
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        stallRebuildTask?.cancel()
        stallRebuildTask = nil
        deferredRecoverySeekTask?.cancel()
        deferredRecoverySeekTask = nil
        stallStartedAt = nil
        stallSoftSeekCount = 0
        silentBufferTicks = 0
        if resetForcedResilient {
            stallForcedResilient = false
            stallRebuildCountForTrack = 0
            lastObservedPlayhead = -1
            lastPlayheadAdvanceAt = Date()
            recoveryQuietUntil = .distantPast
        }
    }

    private var isInRecoveryQuietPeriod: Bool {
        Date() < recoveryQuietUntil
    }

    private func beginRecoveryQuietPeriod(_ seconds: TimeInterval) {
        recoveryQuietUntil = Date().addingTimeInterval(seconds)
        silentBufferTicks = 0
    }

    private func playheadRecentlyAdvanced(within seconds: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastPlayheadAdvanceAt) < seconds
    }

    private func notePlayheadProgress(_ seconds: TimeInterval) {
        if lastObservedPlayhead < 0 {
            lastObservedPlayhead = seconds
            lastPlayheadAdvanceAt = Date()
            return
        }
        // Forward progress of ≥0.3s counts as healthy playback — but only while
        // actually playing. Waiting/paused time jumps (FLAC probe quirks) must
        // not look like healthy audio or they'll poison stall recovery.
        if PlaybackResilience.playheadAdvanced(previous: lastObservedPlayhead, next: seconds) {
            if player.timeControlStatus == .playing, player.rate > 0.01 {
                lastPlayheadAdvanceAt = Date()
            }
            lastObservedPlayhead = seconds
        } else if abs(seconds - lastObservedPlayhead) > 1.5 {
            lastObservedPlayhead = seconds
            // Only quiet recovery for jumps we caused (seek / rebuild).
            if seekEpoch != appliedSeekEpoch || isRebuilding {
                lastPlayheadAdvanceAt = Date()
                beginRecoveryQuietPeriod(2.0)
            }
        }
    }

    /// Wall-clock probe so frozen AVPlayer timebases still get health checks.
    private func startPlaybackHealthProbe() {
        healthProbeCancellable?.cancel()
        healthProbeCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.wantsToPlay, !self.isRebuilding else { return }
                let seconds = self.player.currentTime().seconds
                guard seconds.isFinite, seconds >= 0 else {
                    self.checkPlaybackHealth()
                    return
                }
                self.notePlayheadProgress(seconds)
                self.checkPlaybackHealth()
            }
    }

    /// Detect truly stuck playback. Never use `isPlaybackLikelyToKeepUp` alone.
    private func checkPlaybackHealth() {
        guard wantsToPlay, !isRebuilding, let item = player.currentItem else {
            silentBufferTicks = 0
            return
        }
        let failed = item.status == .failed
        // Hard failures pierce the quiet period — otherwise a bad cache file
        // that dies during the post-rebuild quiet sits dead until the user skips.
        if failed {
            silentBufferTicks = 0
            _ = recoverFailedItemOrSkip(reason: "failedToEnd")
            return
        }
        if isInRecoveryQuietPeriod {
            silentBufferTicks = 0
            return
        }
        let pausedWhileWanting = PlaybackResilience.isPausedWhileWanting(
            wantsToPlay: true,
            isPaused: player.timeControlStatus == .paused,
            rate: Double(player.rate))
        // Intent says play but AVPlayer is fully paused — the live-report
        // dead state. Kick play() and escalate; do not ignore as "not engaged".
        if pausedWhileWanting {
            let threshold = PlaybackResilience.stuckTickThreshold(
                bufferEmpty: false, waiting: false, playingFrozen: false,
                pausedWhileWanting: true)
            silentBufferTicks += 1
            if silentBufferTicks >= threshold {
                silentBufferTicks = 0
                DromeDiagnostics.logIncident("health-paused-while-wanting", player: self)
                kickPlaybackIfNeeded()
                scheduleStallRecovery(reason: "paused-wanting", force: true)
            }
            return
        }
        let engaged = player.timeControlStatus == .playing
            || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            || player.rate > 0.01
        guard engaged else {
            silentBufferTicks = 0
            return
        }
        // Healthy if the clock is moving while actually playing.
        if playheadRecentlyAdvanced(within: 2.0) {
            silentBufferTicks = 0
            return
        }
        let bufferEmpty = item.isPlaybackBufferEmpty
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let playingFrozen = player.timeControlStatus == .playing || player.rate > 0.01
        // Empty/waiting: recover after ~3s. Playing-but-frozen (classic BT
        // silence with a stale non-empty buffer): wait longer (~5s) to avoid
        // false positives during intentional slow buffering.
        let threshold = PlaybackResilience.stuckTickThreshold(
            bufferEmpty: bufferEmpty, waiting: waiting, playingFrozen: playingFrozen)
        if bufferEmpty || waiting || playingFrozen {
            silentBufferTicks += 1
            if silentBufferTicks >= threshold {
                silentBufferTicks = 0
                DromeDiagnostics.logIncident(
                    "health-stuck bufEmpty=\(bufferEmpty) waiting=\(waiting) playing=\(playingFrozen)",
                    player: self)
                scheduleStallRecovery(
                    reason: waiting ? "waiting" : "silent-buffer",
                    force: true)
            }
        } else {
            silentBufferTicks = 0
        }
    }

    private func rebuildFromCacheOrStream(position: TimeInterval, reason: String) {
        guard wantsToPlay, let song = current?.song else { return }
        stallRebuildCountForTrack += 1
        if stallRebuildCountForTrack > PlaybackResilience.maxRebuildsPerTrack {
            DromeDiagnostics.logIncident(
                "circuit-break:\(reason) after \(stallRebuildCountForTrack) → skip",
                player: self)
            clearStallRecoveryState(resetForcedResilient: true)
            advanceAfterCurrentEnds(playImmediately: wantsToPlay)
            return
        }
        // 2nd+ rebuild: nuke stream cache so we don't reattach a truncated file.
        if PlaybackResilience.shouldInvalidateCache(rebuildAttempt: stallRebuildCountForTrack) {
            streamCache.invalidate(songID: song.id)
        }
        let resumeAt = PlaybackResilience.recoveryElapsed(
            accurate: position, published: elapsed)
        DromeDiagnostics.logPlayer(
            "stall rebuild (\(reason)) #\(stallRebuildCountForTrack) pos=\(Int(resumeAt))s")
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        stallRebuildTask?.cancel()
        stallRebuildTask = nil
        deferredRecoverySeekTask?.cancel()
        deferredRecoverySeekTask = nil
        stallSoftSeekCount = 0
        silentBufferTicks = 0
        // Force resilient URL selection for the rebuild (and rest of track).
        stallForcedResilient = true
        lastCellularCompressed = true
        beginRecoveryQuietPeriod(4.0)
        let resume = wantsToPlay
        // Build paused, seek once seekable covers resumeAt, then play — avoids
        // audible start-at-0 and partial-seekable clamps to a random early spot.
        rebuildWindow(startPlaying: false)
        if resume { setPlaybackIntent(true) }
        if resumeAt > 0.5 {
            seekWhenSeekable(to: resumeAt, thenPlay: resume)
        } else if resume {
            kickPlaybackIfNeeded()
        }
        // Kick a cache fill so the *next* stall can play from disk.
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.streamCache.fileURL(
                for: song, maxBitRate: resilientMaxBitRate)
            await MainActor.run {
                self.prefetchUpcomingIntoCache()
            }
        }
    }

    private func prefetchUpcomingIntoCache() {
        // Warm cache on cellular-only / resilient / Bluetooth — A2DP is where
        // HTTP underruns hurt most, and local MP3 survives path flaps.
        // Skip on LAN Wi‑Fi so we don't seed MP3 that would override FLAC.
        guard shouldUseResilientStream
                || ConnectivityMonitor.lastIsCellularOnly
                || isBluetoothRouteActive else { return }
        var songs: [Song] = []
        if let current { songs.append(current.song) }
        songs.append(contentsOf: peekUpcoming(limit: AudioFXPreferences.prefetchCount).map(\.song))
        streamCache.prefetch(songs, maxBitRate: resilientMaxBitRate)
    }
    #endif

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
        sharePlayDidSync = false
        lastSharePlaySnapshot = nil
        pendingSharePlaySnapshot = nil
        configureAudioSession()
    }

    private func joinSharePlay(_ session: GroupSession<DromeListenTogether>) {
        sharePlaySessionTasks.forEach { $0.cancel() }
        sharePlaySessionTasks.removeAll()
        sharePlaySession?.leave()

        sharePlaySession = session
        sharePlayDidSync = false
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
                await MainActor.run {
                    // Only answer catch-up once we have a queue worth sharing —
                    // otherwise a cold joiner can echo an empty state.
                    self?.broadcastSharePlay(force: true)
                }
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
                    self.sharePlayDidSync = false
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
                // Existing members push state when someone new arrives.
                if grew, self.sharePlayDidSync || self.current != nil {
                    self.broadcastSharePlay(force: true)
                }
            }
        })

        session.join()
        sharePlayActive = true
        configureAudioSession(force: true)
        // Flip current item onto jam MP3 before coordinating — attaching the
        // coordinator to a mid-buffer FLAC item caused long one-sided mute.
        if current != nil {
            if isPlayerTransitioning {
                pendingNetworkRebuild = true
            } else {
                performStreamFormatRebuild()
            }
        }
        player.playbackCoordinator.coordinateWithSession(session)
        // Do NOT broadcast our local queue on join — a guest mid-song would
        // overwrite the host. Pull theirs, and only seed if nobody answers.
        requestSharePlayCatchUp()
        ensureAutoplayBuffer()

        sharePlaySessionTasks.append(Task { [weak self] in
            for delay in [350_000_000, 1_000_000_000, 2_500_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.sharePlayActive else { return }
                    if self.sharePlayDidSync {
                        // Keep coordinated playhead honest after late joins.
                        if self.sharePlayParticipantCount > 1 {
                            self.broadcastSharePlay(force: false)
                        }
                        return
                    }
                    if self.sharePlayParticipantCount > 1 {
                        // Others are in the jam — don't push our local queue over
                        // theirs; keep asking until a snapshot lands.
                        self.requestSharePlayCatchUp()
                        return
                    }
                    // Nobody else here yet — seed the jam from this phone.
                    if self.current != nil {
                        DromeDiagnostics.logPlayer("sharePlay seed as host")
                        self.sharePlayDidSync = true
                        self.broadcastSharePlay(force: true)
                    } else {
                        self.requestSharePlayCatchUp()
                    }
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
        DromeDiagnostics.logPlayer(
            "sharePlay broadcast «\(snapshot.current.title)» playing=\(snapshot.isPlaying) upcoming=\(snapshot.upcoming.count)")
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

    /// Snapshots deferred during rebuild / buffer-wait used to sit forever.
    private func flushPendingSharePlaySnapshotIfNeeded() {
        guard sharePlayActive,
              let pending = pendingSharePlaySnapshot,
              !applyingSharePlay,
              !isPlayerTransitioning else { return }
        #if !os(tvOS)
        // Don't tear down mid stall-recovery for a jam queue update unless the
        // remote track actually changed.
        if isInRecoveryQuietPeriod || stallForcedResilient {
            let remoteID = Self.sharePlayContentID(for: pending.current)
            let localID = current.map { Self.sharePlayContentID(for: $0.song) }
            if localID == remoteID {
                return
            }
        }
        #endif
        pendingSharePlaySnapshot = nil
        Task { await applySharePlaySnapshot(pending) }
    }

    private func applySharePlaySnapshot(_ snapshot: SharePlaySnapshot) async {
        if isPlayerTransitioning || applyingSharePlay {
            pendingSharePlaySnapshot = snapshot
            return
        }
        if let last = lastSharePlaySnapshot, snapshot.sentAt + 0.05 < last.sentAt {
            return
        }
        if snapshot == lastSharePlaySnapshot {
            lastSharePlaySnapshot = snapshot
            sharePlayDidSync = true
            // Same track — still honor play/pause if we somehow drifted.
            if snapshot.isPlaying != wantsToPlay {
                if snapshot.isPlaying {
                    resume(bypassConnectGate: true)
                } else {
                    pause()
                }
            }
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
                flushPendingSharePlaySnapshotIfNeeded()
            }
        }

        let currentMatches = current.map {
            Self.sharePlayContentID(for: $0.song) == Self.sharePlayContentID(for: snapshot.current)
        } ?? false

        if currentMatches {
            lastSharePlaySnapshot = snapshot
            sharePlayDidSync = true
            // Don't block play/pause on resolving the whole upcoming list.
            if snapshot.isPlaying != wantsToPlay {
                if snapshot.isPlaying {
                    resume(bypassConnectGate: true)
                } else {
                    pause()
                }
            }
            let upcoming = snapshot.upcoming
            Task { @MainActor [weak self] in
                guard let self, self.sharePlayActive else { return }
                let upcomingSongs = await self.resolveSharePlayTracks(upcoming)
                guard self.current.map({
                    Self.sharePlayContentID(for: $0.song) == Self.sharePlayContentID(for: snapshot.current)
                }) == true else { return }
                self.userQueue = upcomingSongs.map { QueueItem(song: $0) }
                self.contextQueue.removeAll()
                self.resyncUpcomingWindow()
            }
            return
        }

        DromeDiagnostics.logPlayer(
            "sharePlay apply «\(snapshot.current.title)» playing=\(snapshot.isPlaying)")
        // Resolve the current track first and start immediately — waiting on
        // the whole upcoming queue was the multi-second jam start lag.
        guard let currentSong = await resolveSharePlayTrack(snapshot.current) else {
            // Fall back to first resolvable upcoming track.
            let upcomingSongs = await resolveSharePlayTracks(Array(snapshot.upcoming.prefix(4)))
            guard let fallback = upcomingSongs.first else {
                sharePlayNotice = "“\(snapshot.current.title)” isn’t in your library."
                return
            }
            sharePlayNotice = "“\(snapshot.current.title)” isn’t in your library — playing the next shared track."
            await startSharePlayQueue(
                current: fallback,
                upcoming: Array(upcomingSongs.dropFirst()),
                snapshot: snapshot)
            return
        }

        lastSharePlaySnapshot = snapshot
        sharePlayDidSync = true
        cancelAutoplayWork()
        context = PlaybackContext(label: "Jam", kind: .mix)
        fullContextSongs = [currentSong]
        originalContextOrder = []
        contextQueue = []
        userQueue.removeAll()
        history.removeAll()
        setCurrent(QueueItem(song: currentSong), startPlaying: snapshot.isPlaying, allowLowRated: true)
        NowPlayingPresenter.open()
        sharePlayNotice = nil

        let upcoming = snapshot.upcoming
        Task { @MainActor [weak self] in
            guard let self, self.sharePlayActive else { return }
            let upcomingSongs = await self.resolveSharePlayTracks(upcoming)
            guard self.current.map({
                Self.sharePlayContentID(for: $0.song) == Self.sharePlayContentID(for: snapshot.current)
            }) == true else { return }
            self.userQueue = upcomingSongs.map { QueueItem(song: $0) }
            self.contextQueue.removeAll()
            self.fullContextSongs = [currentSong] + upcomingSongs
            self.originalContextOrder = upcomingSongs.map { QueueItem(song: $0) }
            self.resyncUpcomingWindow()
        }
    }

    private func startSharePlayQueue(
        current: Song,
        upcoming: [Song],
        snapshot: SharePlaySnapshot
    ) async {
        lastSharePlaySnapshot = snapshot
        sharePlayDidSync = true
        cancelAutoplayWork()
        context = PlaybackContext(label: "Jam", kind: .mix)
        fullContextSongs = [current] + upcoming
        originalContextOrder = upcoming.map { QueueItem(song: $0) }
        contextQueue = originalContextOrder
        userQueue.removeAll()
        history.removeAll()
        setCurrent(QueueItem(song: current), startPlaying: snapshot.isPlaying, allowLowRated: true)
        NowPlayingPresenter.open()
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
