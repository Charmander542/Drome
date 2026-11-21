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

    private enum Route: Hashable {
        case downloads
        case diagnostics
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
            quickAccessGrid

            accountSection
            appearanceSection
            companionSection
            if session.connect != nil {
                connectSection
            }
            networkSection
            playbackSection
            launchSection
            lyricsSection
            storageSection
            librarySection
            aboutSection
            signOutSection
            versionFooter
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(20)
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

    private var quickAccessGrid: some View {
        Section {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
            LazyVGrid(columns: columns, spacing: 10) {
                quickTile(
                    icon: isOnline ? "checkmark.circle.fill" : "xmark.circle.fill",
                    label: isOnline ? "Online" : "Offline",
                    color: isOnline ? Color(red: 0.35, green: 0.82, blue: 0.45) : .red,
                    accessibilityId: "drome.settings.tile.online"
                ) {
                    Task { await refreshLibrary() }
                }

                quickTile(
                    icon: "arrow.down.circle.fill",
                    label: "Downloads",
                    color: Color(red: 0.35, green: 0.55, blue: 0.95),
                    accessibilityId: "drome.settings.tile.downloads"
                ) {
                    path.append(Route.downloads)
                }

                quickTile(
                    icon: "arrow.triangle.2.circlepath",
                    label: isScanning ? "Scanning" : "Scan",
                    color: Color(red: 0.35, green: 0.85, blue: 0.72),
                    accessibilityId: "drome.settings.tile.scan"
                ) {
                    Task { await refreshLibrary() }
                }

                quickTile(
                    icon: "ladybug.fill",
                    label: "Diagnostics",
                    color: Color(red: 0.95, green: 0.55, blue: 0.35),
                    accessibilityId: "drome.settings.tile.diagnostics"
                ) {
                    path.append(Route.diagnostics)
                }

                if session.connect != nil {
                    quickTile(
                        icon: "hifispeaker.2.fill",
                        label: "Connect",
                        color: Color(red: 0.72, green: 0.58, blue: 0.95),
                        accessibilityId: "drome.settings.tile.connect"
                    ) {
                        path.append(Route.connect)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func quickTile(
        icon: String,
        label: String,
        color: Color,
        accessibilityId: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(color)
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 32)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(DromeTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        // List rows swallow `.plain` taps; borderless keeps the tile actionable.
        .buttonStyle(.borderless)
        .accessibilityIdentifier(accessibilityId ?? "drome.settings.tile.\(label.lowercased())")
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        Section {
            AccentColourPicker()
        } header: {
            Text("Appearance")
        } footer: {
            Text("Accent colours buttons, tabs, and highlights. Amber is Drome’s default.")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var accountSection: some View {
        Section {
            LabeledContent("User", value: session.account.username)
            LabeledContent("Server", value: session.account.serverURL.absoluteString)
            Button {
                showAccounts = true
            } label: {
                Label("Switch Account", systemImage: "person.2")
            }
            Button {
                path.append(Route.tvPairing)
            } label: {
                Label("Send to Apple TV", systemImage: "appletv")
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
        } header: {
            Text("Account")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var companionSection: some View {
        Section {
            TextField(companionPlaceholder, text: $wishlistURLText)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button {
                saveWishlistURL()
            } label: {
                Label("Save Wishlist Server", systemImage: "checkmark.circle")
            }
            if let savedMessage {
                Text(savedMessage)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.accent)
            }
        } header: {
            Text("Wishlist companion")
        } footer: {
            Text("Companion for Spotify wishlist downloads and Drome Connect. LAN example: http://host:4534")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    @ViewBuilder
    private var connectSection: some View {
        if let connect = session.connect {
            Section {
                Button {
                    path.append(Route.connect)
                } label: {
                    Label(
                        connect.isRemote ? "Playing elsewhere" : "Connect devices",
                        systemImage: "hifispeaker.2"
                    )
                }
                LabeledContent("This device", value: connect.deviceName)
                LabeledContent("Online", value: "\(max(connect.devices.count, 1))")
            } header: {
                Text("Connect")
            } footer: {
                Text("Same login on another Drome app. Tap a device to move playback there.")
            }
            .listRowBackground(DromeTheme.elevated)
        }
    }

    private var networkSection: some View {
        Section {
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
            Text("Home / Away")
        } footer: {
            Text("When a home URL is set, Drome prefers it on your LAN. Custom headers help with Cloudflare Access and reverse proxies.")
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
            Toggle(isOn: Binding(
                get: { AudioFXPreferences.autoDownloadStarred },
                set: { AudioFXPreferences.autoDownloadStarred = $0 }
            )) {
                Label("Auto-download starred", systemImage: "star.fill")
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
        } header: {
            Text("Playback")
        } footer: {
            Text("Equalizer lives on Now Playing. Compress on cellular uses MP3 over LTE/5G. Station steering reshapes Infinite Shuffle.")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var launchSection: some View {
        Section {
            Button {
                OnboardingPresenter.replay()
                dismiss()
            } label: {
                Label("Replay feature tour", systemImage: "sparkles")
            }
        } header: {
            Text("Launch")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var lyricsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { lyricsIndexer.isEnabled },
                set: { lyricsIndexer.isEnabled = $0 }
            )) {
                Label("Background indexer", systemImage: "text.quote")
            }
            LabeledContent("Cached lyrics", value: "\(lyricsIndexer.cachedCount)")
            if lyricsIndexer.isRunning {
                LabeledContent("Status", value: lyricsIndexer.statusText)
            }
            Button {
                lyricsIndexer.reindexFromStart()
            } label: {
                Label("Reindex from start", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("Lyrics")
        } footer: {
            Text("Fetches lyrics (Navidrome first, LRCLIB fallback) so Deep Search can find songs by half-remembered lines.")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Downloads", value: Formatters.fileSize(downloads.totalBytesUsed))
            Button {
                path.append(Route.downloads)
            } label: {
                Label("Manage downloads", systemImage: "arrow.down.circle")
            }
        } header: {
            Text("Storage")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var librarySection: some View {
        Section {
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
                    Label("Refresh Library", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isScanning {
                        ProgressView()
                    }
                }
            }
            .disabled(isScanning)
            if let scanMessage {
                Text(scanMessage)
                    .font(.caption)
                    .foregroundStyle(scanFailed ? Color.red.opacity(0.9) : DromeTheme.accent)
            }
        } header: {
            Text("Library")
        } footer: {
            Text("Hide feature credits removes artists with no albums who only appear on other people's tracks.")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var aboutSection: some View {
        Section {
            Button {
                path.append(Route.diagnostics)
            } label: {
                Label("Diagnostics", systemImage: "ladybug")
            }
            .accessibilityIdentifier("drome.settings.diagnostics")
            #if DEBUG
            NavigationLink {
                DromeDesignSystemGuide()
            } label: {
                Label("Design System", systemImage: "paintpalette")
            }
            #endif
        } header: {
            Text("About")
        } footer: {
            Text("When something sounds wrong: Diagnostics → Copy report for Cursor → paste into chat.")
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
