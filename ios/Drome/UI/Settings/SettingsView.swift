import SwiftUI

/// Aura-inspired settings: large in-list title, quick-access tile grid,
/// elevated grouped cards on a darker page.
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var lyricsIndexer: LyricsIndexer
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var accentStore = AccentStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var wishlistURLText = ""
    @State private var homeURLText = ""
    @State private var customHeadersText = ""
    @State private var savedMessage: String?
    @State private var networkSavedMessage: String?
    @State private var isScanning = false
    @State private var scanMessage: String?
    @State private var scanFailed = false
    @State private var showAccounts = false
    @State private var path = NavigationPath()
    @State private var listeningPreview: ListeningStats = .empty

    private enum Route: Hashable {
        case downloads
        case diagnostics
        case listeningStats
        case tvPairing
        case connect
    }

    private var companionPlaceholder: String {
        dynamicTypeSize.isAccessibilitySize
            ? "Companion URL"
            : "https://wishlist.example.com"
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build { return "\(version) · build \(build)" }
        return version
    }

    private var isOnline: Bool { ConnectivityMonitor.lastIsOnline }

    var body: some View {
        NavigationStack(path: $path) {
            settingsRoot
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .tint(accentStore.color)
        .onAppear {
            wishlistURLText = session.account.wishlistURL?.absoluteString ?? ""
            homeURLText = session.account.homeURL?.absoluteString ?? ""
            customHeadersText = session.account.customHeaders
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        }
        .onDisappear {
            // Custom colour updates tint live; remount the app shell when leaving
            // so every `DromeTheme.accent` call site picks it up.
            accentStore.bumpRevision()
        }
        .sheet(isPresented: $showAccounts) {
            AccountSwitcherSheet().environmentObject(env)
        }
        .preferredColorScheme(.dark)
    }

    private var settingsRoot: some View {
        List {
            titleRow
            listeningHeroSection
            youSection
            playbackSection
            transitionsSection
            libraryOfflineSection
            connectionsSection
            moreSection
            signOutSection
            versionFooter
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .background(DromeTheme.background)
        // Solid inline bar on root and pushes so List safe-area inset never
        // changes mid-transition (hidden → visible caused the vertical jump).
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .settingsNavChrome()
        .toolbar {
            if ProcessInfo.processInfo.arguments.contains("-UITestWalk")
                || ProcessInfo.processInfo.arguments.contains("-UITestPodcastMini") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("drome.settings.close")
                }
            }
        }
        .accessibilityIdentifier("drome.settings.screen")
        .task { refreshListeningPreview() }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .downloads:
            DownloadsView()
                .settingsNavChrome()
                .scrollIndicators(.hidden)
        case .diagnostics:
            DiagnosticsView()
                .settingsNavChrome()
                .scrollIndicators(.hidden)
        case .listeningStats:
            ListeningStatsView()
                .settingsNavChrome()
                .scrollIndicators(.hidden)
        case .tvPairing:
            TVPairingView()
                .navigationTitle("Apple TV")
                .settingsNavChrome()
                .scrollIndicators(.hidden)
        case .connect:
            if let connect = session.connect {
                // `embedded: true` — no inner NavigationStack (that breaks Settings path).
                ConnectDevicePicker(connect: connect, embedded: true)
                    .settingsNavChrome()
                    .scrollIndicators(.hidden)
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - Title + quick tiles

    private var titleRow: some View {
        Text("Settings")
            .font(.system(size: 34, weight: .bold, design: .default))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Stable top inset for the sheet grabber (nav bar is hidden).
            .padding(.top, 8)
            .padding(.bottom, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 10, trailing: 4))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
    }

    /// Subsonify-style “Your listening” hero — hours / plays / days at a glance.
    private var listeningHeroSection: some View {
        Section {
            Button {
                path.append(Route.listeningStats)
            } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(DromeTheme.accent.opacity(0.22))
                            Image(systemName: "chart.bar.fill")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(DromeTheme.accent)
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your listening")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                            Text(listeningPreview.isEmpty
                                 ? "Play something to fill your stats"
                                 : "Top artists, albums, and songs")
                                .font(.caption)
                                .foregroundStyle(DromeTheme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DromeTheme.muted)
                    }

                    HStack(spacing: 0) {
                        heroStat(
                            value: heroHoursLabel,
                            label: "Hours")
                        Divider().frame(height: 28).overlay(DromeTheme.divider)
                        heroStat(
                            value: "\(listeningPreview.totalPlays)",
                            label: "Plays")
                        Divider().frame(height: 28).overlay(DromeTheme.divider)
                        heroStat(
                            value: "\(listeningPreview.activeDays)",
                            label: "Days")
                    }
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("drome.settings.listening")
            .listRowBackground(DromeTheme.elevated)
        }
    }

    private func heroStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DromeTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private var heroHoursLabel: String {
        let hours = listeningPreview.hoursListened
        if hours >= 10 { return String(format: "%.0f", hours.rounded()) }
        if hours >= 1 { return String(format: "%.1f", hours) }
        let minutes = max(0, listeningPreview.totalSeconds / 60)
        return minutes > 0 ? "\(minutes)m" : "0"
    }

    // MARK: - Sections

    private var youSection: some View {
        Section {
            AccentColourPicker()
            Button {
                Task { await refreshLibrary() }
            } label: {
                HStack {
                    Label(
                        isOnline ? "Online" : "Offline",
                        systemImage: isOnline ? "checkmark.circle.fill" : "wifi.slash")
                    Spacer()
                    Text(session.account.username)
                        .foregroundStyle(DromeTheme.muted)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("drome.settings.tile.online")
        } header: {
            Text("You")
        } footer: {
            Text("Accent colours buttons, tabs, and highlights. Amber is Drome’s default.")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var playbackSection: some View {
        Section {
            Toggle(isOn: $player.autoplayEnabled) {
                Label("Keep playing", systemImage: "infinity")
            }
            Toggle(isOn: Binding(
                get: { PlaybackPreferences.skipLowRatedEverywhere },
                set: { PlaybackPreferences.skipLowRatedEverywhere = $0 }
            )) {
                Label("Skip low-rated songs", systemImage: "hand.thumbsdown")
            }
            Toggle(isOn: Binding(
                get: { PlaybackPreferences.compressOnCellular },
                set: { PlaybackPreferences.compressOnCellular = $0 }
            )) {
                Label("Compress on cellular", systemImage: "antenna.radiowaves.left.and.right")
            }
            Toggle(isOn: Binding(
                get: { PlaybackPreferences.resilientRemoteStreaming },
                set: { PlaybackPreferences.resilientRemoteStreaming = $0 }
            )) {
                Label("Resilient streaming", systemImage: "wifi.exclamationmark")
            }
            Picker(selection: Binding(
                get: { player.shuffleMode },
                set: { player.shuffleMode = $0 }
            )) {
                Text("Off").tag(ShuffleMode.off)
                Text("Smart (rating-weighted)").tag(ShuffleMode.smart)
                Text("Random").tag(ShuffleMode.random)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            Picker(selection: Binding(
                get: { StationSteeringStore.current },
                set: { StationSteeringStore.current = $0 }
            )) {
                ForEach(StationSteering.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Label("Station steering", systemImage: "dial.medium")
            }
            Picker(selection: Binding(
                get: { Int(PlaybackPreferences.autoplayRecencyHours) },
                set: { PlaybackPreferences.autoplayRecencyHours = Double($0) }
            )) {
                Text("24 hours").tag(24)
                Text("3 days").tag(72)
                Text("7 days").tag(168)
                Text("30 days").tag(720)
            } label: {
                Label("Autoplay recency", systemImage: "clock.arrow.circlepath")
            }
            Picker(selection: Binding(
                get: { AudioFXPreferences.prefetchCount },
                set: { AudioFXPreferences.prefetchCount = $0 }
            )) {
                Text("2 tracks").tag(2)
                Text("3 tracks").tag(3)
                Text("5 tracks").tag(5)
                Text("8 tracks").tag(8)
            } label: {
                Label("Pre-cache upcoming", systemImage: "arrow.down.to.line")
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Equalizer (10-band + headphone profiles) opens from Now Playing. Compress on cellular uses MP3 over LTE/5G.")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var transitionsSection: some View {
        Section {
            Picker(selection: Binding(
                get: { AudioFXPreferences.mixTransitionMode },
                set: { AudioFXPreferences.mixTransitionMode = $0 }
            )) {
                ForEach(AudioFXPreferences.MixTransitionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Label("Mix", systemImage: "waveform.path")
            }
            if AudioFXPreferences.mixTransitionMode != .off {
                Picker(selection: Binding(
                    get: { AudioFXPreferences.crossfadeSeconds == 0 ? 6 : AudioFXPreferences.crossfadeSeconds },
                    set: { AudioFXPreferences.crossfadeSeconds = $0 }
                )) {
                    Text("3s").tag(3)
                    Text("6s").tag(6)
                    Text("9s").tag(9)
                    Text("12s").tag(12)
                } label: {
                    Label("Crossfade", systemImage: "arrow.left.arrow.right")
                }
            }
        } header: {
            Text("Transitions")
        } footer: {
            Text(AudioFXPreferences.mixTransitionMode.detail + " Same-album tracks stay gapless.")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var libraryOfflineSection: some View {
        Section {
            Button {
                path.append(Route.downloads)
            } label: {
                HStack {
                    Label("Downloads", systemImage: "arrow.down.circle.fill")
                    Spacer()
                    Text(Formatters.fileSize(downloads.totalBytesUsed))
                        .foregroundStyle(DromeTheme.muted)
                }
            }
            .accessibilityIdentifier("drome.settings.tile.downloads")
            Toggle(isOn: Binding(
                get: { AudioFXPreferences.autoDownloadStarred },
                set: { AudioFXPreferences.autoDownloadStarred = $0 }
            )) {
                Label("Auto-download starred", systemImage: "star.fill")
            }
            Toggle(isOn: Binding(
                get: { LibraryArtistFilter.hideCreditOnlyArtists },
                set: { LibraryArtistFilter.hideCreditOnlyArtists = $0 }
            )) {
                Label("Hide feature credits", systemImage: "person.crop.circle.badge.minus")
            }
            Button {
                Task { await refreshLibrary() }
            } label: {
                HStack {
                    Label("Refresh library", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isScanning {
                        ProgressView()
                    }
                }
            }
            .disabled(isScanning)
            .accessibilityIdentifier("drome.settings.tile.scan")
            if let scanMessage {
                Text(scanMessage)
                    .font(.caption)
                    .foregroundStyle(scanFailed ? Color.red.opacity(0.9) : DromeTheme.accent)
            }
        } header: {
            Text("Library & offline")
        } footer: {
            Text("Hide feature credits removes artists with no albums who only appear on other people's tracks.")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var connectionsSection: some View {
        Section {
            LabeledContent("Server", value: session.account.serverURL.host ?? session.account.serverURL.absoluteString)
            Button {
                showAccounts = true
            } label: {
                Label("Switch account", systemImage: "person.2")
            }
            Button {
                path.append(Route.tvPairing)
            } label: {
                Label("Send to Apple TV", systemImage: "appletv")
            }
            if session.connect != nil {
                Button {
                    path.append(Route.connect)
                } label: {
                    Label(
                        session.connect?.isRemote == true ? "Playing elsewhere" : "Connect devices",
                        systemImage: "hifispeaker.2")
                }
                .accessibilityIdentifier("drome.settings.tile.connect")
            }
            Toggle(isOn: Binding(
                get: { session.account.allowSelfSigned },
                set: { newValue in
                    var account = session.account
                    account.allowSelfSigned = newValue
                    env.accounts.update(account)
                    env.activate(account)
                }
            )) {
                Label("Allow self-signed cert", systemImage: "lock.open")
            }
            TextField(companionPlaceholder, text: $wishlistURLText)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button {
                saveWishlistURL()
            } label: {
                Label("Save companion URL", systemImage: "checkmark.circle")
            }
            if let savedMessage {
                Text(savedMessage)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.accent)
            }
            TextField("Home / LAN URL (optional)", text: $homeURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Custom headers (Header: value per line)", text: $customHeadersText, axis: .vertical)
                .font(.caption.monospaced())
                .lineLimit(2...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                saveNetworkSettings()
            } label: {
                Label("Save network", systemImage: "network")
            }
            if let networkSavedMessage {
                Text(networkSavedMessage)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.accent)
            }
        } header: {
            Text("Connections")
        } footer: {
            Text("Companion powers wishlist downloads and Connect. Home URL is preferred on LAN; custom headers help with Cloudflare Access.")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var moreSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { lyricsIndexer.isEnabled },
                set: { lyricsIndexer.isEnabled = $0 }
            )) {
                Label("Lyrics indexer", systemImage: "text.quote")
            }
            LabeledContent("Cached lyrics", value: "\(lyricsIndexer.cachedCount)")
            if lyricsIndexer.isRunning {
                LabeledContent("Status", value: lyricsIndexer.statusText)
            }
            Button {
                lyricsIndexer.reindexFromStart()
            } label: {
                Label("Reindex lyrics", systemImage: "arrow.counterclockwise")
            }
            Button {
                OnboardingPresenter.replay()
                dismiss()
            } label: {
                Label("Replay feature tour", systemImage: "sparkles")
            }
            Button {
                path.append(Route.diagnostics)
            } label: {
                Label("Diagnostics", systemImage: "ladybug")
            }
            .accessibilityIdentifier("drome.settings.tile.diagnostics")
            #if DEBUG
            NavigationLink {
                DromeDesignSystemGuide()
            } label: {
                Label("Design System", systemImage: "paintpalette")
            }
            #endif
        } header: {
            Text("More")
        } footer: {
            Text("Lyrics power Deep Search. Diagnostics → Copy report for Cursor when something sounds wrong.")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var signOutSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                env.signOut()
                dismiss()
            }
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var versionFooter: some View {
        Text(appVersionLabel)
            .font(.footnote)
            .foregroundStyle(DromeTheme.muted)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 16, leading: 0, bottom: 24, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityLabel("Version \(appVersionLabel)")
    }

    // MARK: - Actions

    private func saveNetworkSettings() {
        var account = session.account
        let homeTrimmed = homeURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if homeTrimmed.isEmpty {
            account.homeURL = nil
        } else if let url = ServerURLNormalization.normalize(homeTrimmed) {
            account.homeURL = url
        } else {
            networkSavedMessage = "Invalid home URL"
            return
        }
        var headers: [String: String] = [:]
        for line in customHeadersText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            headers[parts[0]] = parts[1]
        }
        account.customHeaders = headers
        env.accounts.update(account)
        env.activate(account)
        if let home = account.homeURL {
            session.client.setBaseURL(home)
        } else {
            session.client.setBaseURL(account.serverURL)
        }
        networkSavedMessage = "Saved"
        Task { await ServerReachability.probeAndSelect(client: session.client, account: account) }
    }

    private func saveWishlistURL() {
        var account = session.account
        let trimmed = wishlistURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            account.wishlistURL = nil
        } else {
            guard let url = ServerURLNormalization.normalize(trimmed) else {
                savedMessage = "Invalid URL"
                return
            }
            account.wishlistURL = url
        }
        env.accounts.update(account)
        env.activate(account)
        savedMessage = "Saved"
    }

    private func refreshListeningPreview() {
        let database = session.database
        let userKey = session.account.userKey
        Task.detached(priority: .utility) {
            let next = (try? database.listeningStats(userKey: userKey, period: .allTime)) ?? .empty
            await MainActor.run { listeningPreview = next }
        }
    }

    private func refreshLibrary() async {
        isScanning = true
        scanFailed = false
        scanMessage = "Starting scan…"
        defer { isScanning = false }
        do {
            try await session.client.startScan()
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 500_000_000)
                let status = try await session.client.scanStatus()
                if status.scanning == true {
                    let count = status.count.map(String.init) ?? "…"
                    scanMessage = "Scanning… \(count) items"
                } else {
                    let count = status.count.map(String.init) ?? "…"
                    scanMessage = "Scan complete (\(count) items)"
                    scanFailed = false
                    return
                }
            }
            scanMessage = "Scan still running on the server"
        } catch {
            scanFailed = true
            scanMessage = error.localizedDescription
        }
    }
}

private extension View {
    /// Same solid inline bar on Settings root and every push — keeps List
    /// safe-area inset stable so content doesn’t start high then drop.
    func settingsNavChrome() -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DromeTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
