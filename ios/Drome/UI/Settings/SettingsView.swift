import SwiftUI

/// SubSonify-inspired settings hub: large title, Done pill, Server card, then
/// green-icon rows that push into focused sub-pages (Playback, Streaming, …).
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject private var accentStore = AccentStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var path = NavigationPath()
    @State private var showAccounts = false
    @State private var listeningPreview: ListeningStats = .empty

    enum Route: Hashable {
        case playback
        case streaming
        case appearance
        case siriShortcuts
        case librarySync
        case listeningStats
        case appleWatch
        case connections
        case homeNetwork
        case downloads
        case diagnostics
        case tvPairing
        case connect
        case equalizer
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build { return "\(version) · build \(build)" }
        return version
    }

    private var homeNetworkLabel: String {
        if let home = session.account.homeURL {
            return home.host ?? home.absoluteString
        }
        return "Off"
    }

    private var listeningSubtitle: String {
        if listeningPreview.isEmpty { return "Hours, plays, and your top five" }
        let hours = listeningPreview.hoursListened
        let hoursText = hours >= 10
            ? String(format: "%.0f h", hours.rounded())
            : (hours >= 1 ? String(format: "%.1f h", hours) : "\(max(0, listeningPreview.totalSeconds / 60))m")
        return "\(hoursText) · \(listeningPreview.totalPlays) plays · \(listeningPreview.activeDays) days"
    }

    var body: some View {
        NavigationStack(path: $path) {
            hub
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .tint(accentStore.color)
        .onDisappear { accentStore.bumpRevision() }
        .sheet(isPresented: $showAccounts) {
            AccountSwitcherSheet().environmentObject(env)
        }
        .preferredColorScheme(.dark)
        .task { refreshListeningPreview() }
    }

    // MARK: - Hub

    private var hub: some View {
        List {
            titleRow
            brandCard
            serverSection
            featuresSection
            aboutSection
            versionFooter
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(20)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .settingsNavChrome()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DromeTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(DromeTheme.elevated2, in: Capsule(style: .continuous))
                    .accessibilityIdentifier("drome.settings.close")
            }
        }
        .accessibilityIdentifier("drome.settings.screen")
    }

    private var titleRow: some View {
        Text("Settings")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
    }

    /// Top card (SubSonify Pro slot) → Drome feature tour / identity.
    private var brandCard: some View {
        Section {
            Button {
                OnboardingPresenter.replay()
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drome")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Offline · Discover · CarPlay · Watch")
                            .font(.subheadline)
                            .foregroundStyle(DromeTheme.muted)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.28))
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .listRowBackground(DromeTheme.elevated)
        }
    }

    private var serverSection: some View {
        Section {
            settingsValueRow("Server", value: "Navidrome")
            settingsValueRow(
                "Host",
                value: session.account.serverURL.host ?? session.account.serverURL.absoluteString)
            settingsValueRow("Username", value: session.account.username)

            Button {
                path.append(Route.homeNetwork)
            } label: {
                HStack {
                    Text("Home network")
                        .foregroundStyle(DromeTheme.accent)
                    Spacer()
                    Text(homeNetworkLabel)
                        .foregroundStyle(DromeTheme.muted)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.28))
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Server")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var featuresSection: some View {
        Section {
            settingsLink(
                title: "Playback",
                systemImage: "play.circle",
                route: .playback)
            settingsLink(
                title: "Streaming & Downloads",
                systemImage: "dot.radiowaves.left.and.right",
                route: .streaming,
                accessibilityId: "drome.settings.tile.downloads")
            settingsLink(
                title: "Appearance",
                systemImage: "paintbrush",
                route: .appearance)
            settingsLink(
                title: "Siri & Shortcuts",
                systemImage: "waveform",
                route: .siriShortcuts,
                subtitle: "Play vibes, playlists, and liked songs",
                accessibilityId: "drome.settings.siri")
            settingsLink(
                title: "Library sync",
                systemImage: "arrow.triangle.2.circlepath",
                route: .librarySync,
                accessibilityId: "drome.settings.tile.scan")
            settingsLink(
                title: "Your listening",
                systemImage: "chart.bar",
                route: .listeningStats,
                subtitle: listeningSubtitle,
                accessibilityId: "drome.settings.listening")
            settingsLink(
                title: "Apple Watch",
                systemImage: "applewatch",
                route: .appleWatch)
            settingsLink(
                title: "Connections",
                systemImage: "hifispeaker.2",
                route: .connections,
                accessibilityId: "drome.settings.tile.connect")
        }
        .listRowBackground(DromeTheme.elevated)
    }

    private var aboutSection: some View {
        Section {
            Button {
                path.append(Route.diagnostics)
            } label: {
                settingsIconLabel(title: "Diagnostics", systemImage: "ladybug")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("drome.settings.tile.diagnostics")

            Button {
                showAccounts = true
            } label: {
                settingsIconLabel(title: "Switch account", systemImage: "person.2")
            }
            .buttonStyle(.borderless)

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

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .playback:
            SettingsPlaybackView { path.append(Route.equalizer) }
                .settingsNavChrome()
        case .streaming:
            SettingsStreamingView {
                path.append(Route.downloads)
            }
            .settingsNavChrome()
        case .appearance:
            SettingsAppearanceView()
                .settingsNavChrome()
        case .siriShortcuts:
            SettingsSiriShortcutsView()
                .settingsNavChrome()
        case .librarySync:
            SettingsLibrarySyncView()
                .settingsNavChrome()
        case .listeningStats:
            ListeningStatsView()
                .settingsNavChrome()
                .scrollIndicators(.hidden)
        case .appleWatch:
            SettingsWatchInfoView()
                .settingsNavChrome()
        case .connections:
            SettingsConnectionsView(path: $path)
                .settingsNavChrome()
        case .homeNetwork:
            SettingsHomeNetworkView()
                .settingsNavChrome()
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
                ConnectDevicePicker(connect: connect, embedded: true)
                    .settingsNavChrome()
                    .scrollIndicators(.hidden)
            } else {
                EmptyView()
            }
        case .equalizer:
            EqualizerSheet(detent: .constant(.large))
                .settingsNavChrome()
        }
    }

    // MARK: - Row helpers

    private func settingsValueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func settingsLink(
        title: String,
        systemImage: String,
        route: Route,
        subtitle: String? = nil,
        accessibilityId: String? = nil
    ) -> some View {
        Button {
            path.append(route)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DromeTheme.accent)
                    .frame(width: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(DromeTheme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.28))
            }
            .padding(.vertical, subtitle == nil ? 2 : 4)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(accessibilityId ?? "drome.settings.link.\(title.lowercased())")
    }

    private func settingsIconLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(DromeTheme.accent)
                .frame(width: 28, alignment: .center)
            Text(title)
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.28))
        }
    }

    private func refreshListeningPreview() {
        let database = session.database
        let userKey = session.account.userKey
        Task.detached(priority: .utility) {
            let next = (try? database.listeningStats(userKey: userKey, period: .allTime)) ?? .empty
            await MainActor.run { listeningPreview = next }
        }
    }
}

// MARK: - Shared chrome

extension View {
    /// Same solid inline bar on Settings root and every push — keeps List
    /// safe-area inset stable so content doesn’t start high then drop.
    func settingsNavChrome() -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .preferredColorScheme(.dark)
    }
}
