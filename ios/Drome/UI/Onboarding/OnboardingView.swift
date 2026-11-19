import SwiftUI

/// First-run walkthrough after sign-in. Device-style mocks show where
/// controls live — skip anytime.
struct OnboardingView: View {
    let userKey: String
    var onFinished: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var searchFocus: OnboardingSearchFocus = .library
    @State private var searchCycleToken = 0
    @State private var nowPlayingFocus: OnboardingNowPlayingFocus = .shuffle
    @State private var nowPlayingCycleToken = 0

    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    /// Fixed heights — do not scale with Dynamic Type (mocks cap type internally).
    private var mockHeight: CGFloat { accessibilityLayout ? 200 : 340 }
    private var mockMaxWidth: CGFloat { accessibilityLayout ? 260 : 300 }

    /// Page indices for highlight cycles.
    private let searchPageIndex = 2
    private let nowPlayingControlsPageIndex = 4

    private let pages: [OnboardingTourPage] = [
        OnboardingTourPage(
            title: "Welcome to Drome",
            caption: "Daily Mixes and Vibe Tuner live on Home — your private library, tuned to you.",
            accessibilityMockLabel: "Home screen preview with Vibe Tuner near the top and the tab bar at the bottom."),
        OnboardingTourPage(
            title: "Browse your library",
            caption: "Home, Search, Your Library, and Podcasts sit in the tab bar.",
            accessibilityMockLabel: "Your Library preview. The Home, Search, Your Library, and Podcasts tabs are highlighted in the tab bar."),
        OnboardingTourPage(
            title: "Search three ways",
            caption: "Library, Spotify wishlist, and Podcasts — tap the quote icon for lyrics in Library.",
            accessibilityMockLabel: "Search screen. Use the Library, Spotify, and Podcasts segmented control; the quote button enables lyrics search when Library is selected."),
        OnboardingTourPage(
            title: "Rate with stars",
            caption: "High ratings shape mixes; one or two stars send a track to Out of Rotation.",
            accessibilityMockLabel: "Star rating is on the Now Playing screen, below the track title. One or two stars move a track to Out of Rotation."),
        OnboardingTourPage(
            title: "Now Playing controls",
            caption: "Swipe album art left for next, right for previous. ∞ is Keep Playing when the queue ends.",
            accessibilityMockLabel: "Music Now Playing: swipe album art left for next song and right for previous. Also Song and Lyrics, Smart shuffle, repeat, Keep Playing infinity, queue, and AirPlay."),
        OnboardingTourPage(
            title: "Playlists & sharing",
            caption: "Create with + in Your Library; Share Playlist is in a playlist’s ··· menu.",
            accessibilityMockLabel: "Your Library plus button creates a playlist. Share Playlist is in the playlist detail more menu."),
        OnboardingTourPage(
            title: "Keep the music going",
            caption: "The same Keep Playing switch also lives under Avatar → Settings → Playback.",
            accessibilityMockLabel: "Settings is opened from the Home avatar menu. Keep Playing is in the Playback section — the same setting as the Now Playing infinity button."),
    ]

    var body: some View {
        ZStack {
            DromeTheme.background.ignoresSafeArea()
            ambientGlow
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { finish() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .padding(.horizontal, 12)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        pageContent(item, index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.28), value: page)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomChrome
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: page) { _, newPage in
            if newPage == searchPageIndex { restartSearchCycle() }
            if newPage == nowPlayingControlsPageIndex { restartNowPlayingCycle() }
        }
        .onAppear {
            if page == searchPageIndex { restartSearchCycle() }
            if page == nowPlayingControlsPageIndex { restartNowPlayingCycle() }
        }
        .task(id: searchCycleToken) {
            await runSearchHighlightCycle()
        }
        .task(id: nowPlayingCycleToken) {
            await runNowPlayingHighlightCycle()
        }
    }

    private func restartSearchCycle() {
        searchFocus = .library
        searchCycleToken &+= 1
    }

    private func restartNowPlayingCycle() {
        nowPlayingFocus = .artSwipe
        nowPlayingCycleToken &+= 1
    }

    private func runSearchHighlightCycle() async {
        guard page == searchPageIndex, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            guard page == searchPageIndex, !reduceMotion else { return }
            let all = OnboardingSearchFocus.allCases
            let next = (searchFocus.rawValue + 1) % all.count
            withAnimation(.easeInOut(duration: 0.28)) {
                searchFocus = OnboardingSearchFocus(rawValue: next) ?? .library
            }
        }
    }

    private func runNowPlayingHighlightCycle() async {
        guard page == nowPlayingControlsPageIndex, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            guard page == nowPlayingControlsPageIndex, !reduceMotion else { return }
            let all = OnboardingNowPlayingFocus.allCases
            let next = (nowPlayingFocus.rawValue + 1) % all.count
            withAnimation(.easeInOut(duration: 0.28)) {
                nowPlayingFocus = OnboardingNowPlayingFocus(rawValue: next) ?? .shuffle
            }
        }
    }

    private func pageContent(_ item: OnboardingTourPage, index: Int) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                deviceMock(for: index)
                    .frame(maxWidth: mockMaxWidth)
                    .frame(height: mockHeight)
                    .frame(maxWidth: .infinity)
                    // Clip after sizing so mock content can't spill over title/caption.
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
                    .padding(.horizontal, 28)
                    .padding(.bottom, accessibilityLayout ? 12 : 14)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityMockLabel)

                Text(item.title)
                    .font(DromeTheme.titleFont)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .lineLimit(accessibilityLayout ? 3 : 1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 28)
                    .padding(.bottom, accessibilityLayout ? 6 : 8)
                    .accessibilityAddTraits(.isHeader)

                Text(item.caption)
                    .font(.body)
                    .foregroundStyle(DromeTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, accessibilityLayout ? 2 : 6)
            .padding(.bottom, accessibilityLayout ? 24 : 8)
        }
        .scrollIndicators(accessibilityLayout ? .visible : .automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, DromeTheme.background],
                startPoint: .top,
                endPoint: .bottom)
                .frame(height: accessibilityLayout ? 36 : 16)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func deviceMock(for index: Int) -> some View {
        OnboardingPhoneFrame {
            Group {
                switch index {
                case 0:
                    OnboardingHomeMock(reduceMotion: reduceMotion, highlightVibe: true)
                case 1:
                    OnboardingBrowseMock(reduceMotion: reduceMotion)
                case 2:
                    OnboardingSearchMock(
                        focus: searchFocus,
                        reduceMotion: reduceMotion,
                        showAllCallouts: reduceMotion)
                case 3:
                    OnboardingNowPlayingMock(reduceMotion: reduceMotion)
                case 4:
                    OnboardingNowPlayingControlsMock(
                        focus: nowPlayingFocus,
                        reduceMotion: reduceMotion,
                        showAllCallouts: reduceMotion)
                case 5:
                    OnboardingPlaylistsMock(reduceMotion: reduceMotion)
                default:
                    OnboardingSettingsMock(reduceMotion: reduceMotion)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var bottomChrome: some View {
        VStack(spacing: 10) {
            pageDots

            Button {
                if page < pages.count - 1 {
                    withAnimation(.easeInOut(duration: 0.28)) { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page < pages.count - 1 ? "Continue" : "Start listening")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(DromeTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("onboarding-continue")
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(DromeTheme.background.opacity(0.001))
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pages.count, id: \.self) { index in
                Button {
                    withAnimation(.easeInOut(duration: 0.28)) { page = index }
                } label: {
                    Capsule()
                        .fill(index == page ? DromeTheme.accent : DromeTheme.divider)
                        .frame(width: index == page ? 18 : 7, height: 7)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tour")
        .accessibilityValue("Page \(page + 1) of \(pages.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                guard page < pages.count - 1 else { return }
                withAnimation(.easeInOut(duration: 0.28)) { page += 1 }
            case .decrement:
                guard page > 0 else { return }
                withAnimation(.easeInOut(duration: 0.28)) { page -= 1 }
            @unknown default:
                break
            }
        }
    }

    private var ambientGlow: some View {
        RadialGradient(
            colors: [DromeTheme.accent.opacity(0.12), DromeTheme.accent.opacity(0.03), .clear],
            center: UnitPoint(x: 0.5, y: 0.16),
            startRadius: 20,
            endRadius: 380)
        .ignoresSafeArea()
    }

    private func finish() {
        OnboardingPreference.markCompleted(userKey: userKey)
        onFinished()
    }
}

private struct OnboardingTourPage {
    let title: String
    let caption: String
    let accessibilityMockLabel: String
}
