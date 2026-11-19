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
    /// Sub-steps on the Now Playing controls lesson.
    @State private var nowPlayingStep: OnboardingNowPlayingStep = .artSwipe
    /// Direction for the small step slide (+1 forward, -1 back).
    @State private var nowPlayingStepDirection: Int = 1
    /// Lets programmatic page changes bypass the NP swipe interceptor.
    @State private var allowTabPageChange = false

    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    private let searchPageIndex = 2
    private let nowPlayingControlsPageIndex = 4
    private let nowPlayingStepCount = OnboardingNowPlayingStep.allCases.count

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
            caption: "Library, Spotify, and Podcasts — in Library, pick Lyrics in the filter chips to search lyrics.",
            accessibilityMockLabel: "Search screen. Use Library, Spotify, or Podcasts. In Library mode, the filter chips are All, Songs, Albums, Artists, and Lyrics."),
        OnboardingTourPage(
            title: "Rate with stars",
            caption: "High ratings shape mixes; one or two stars send a track to Out of Rotation.",
            accessibilityMockLabel: "Star rating is on the Now Playing screen, below the track title. One or two stars move a track to Out of Rotation."),
        OnboardingTourPage(
            title: "Now Playing controls",
            caption: "",
            accessibilityMockLabel: ""),
        OnboardingTourPage(
            title: "Playlists & sharing",
            caption: "Create with + in Your Library; Share Playlist is in a playlist’s ··· menu.",
            accessibilityMockLabel: "Your Library plus button creates a playlist. Share Playlist is in the playlist detail more menu."),
        OnboardingTourPage(
            title: "Keep the music going",
            caption: "The same Keep Playing switch also lives under Avatar → Settings → Playback.",
            accessibilityMockLabel: "Settings is opened from the Home avatar menu. Keep Playing is in the Playback section — the same setting as the Now Playing infinity button."),
    ]

    private var isNowPlayingLesson: Bool { page == nowPlayingControlsPageIndex }

    private var pageAccessibilityLabel: String {
        if isNowPlayingLesson {
            return "Now Playing, step \(nowPlayingStep.rawValue + 1) of \(nowPlayingStepCount). \(nowPlayingStep.caption(compact: accessibilityLayout))"
        }
        return pages[page].accessibilityMockLabel
    }

    private var continueLabel: String {
        if isNowPlayingLesson {
            let n = nowPlayingStep.rawValue + 1
            if n < nowPlayingStepCount {
                return "Continue · \(n) of \(nowPlayingStepCount)"
            }
            return "Continue"
        }
        if page < pages.count - 1 { return "Continue" }
        return "Start listening"
    }

    /// Intercept TabView swipes on the Now Playing lesson so they move steps, not pages.
    private var pageSelection: Binding<Int> {
        Binding(
            get: { page },
            set: { newPage in
                if allowTabPageChange {
                    page = newPage
                    return
                }
                if page == nowPlayingControlsPageIndex, newPage != page {
                    // On the swipe-art tip, horizontal drags only animate the mock
                    // cover — Continue / caption tap advance. Reject TabView paging.
                    if nowPlayingStep == .artSwipe { return }
                    if newPage > page {
                        advance()
                    } else {
                        goBack()
                    }
                    return
                }
                page = newPage
            })
    }

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

                TabView(selection: pageSelection) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, _ in
                        pageContent(index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.28), value: page)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.28), value: nowPlayingStep)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomChrome
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: page) { _, newPage in
            if newPage == searchPageIndex { restartSearchCycle() }
            if newPage == nowPlayingControlsPageIndex {
                nowPlayingStep = .artSwipe
                nowPlayingStepDirection = 1
            }
        }
        .onAppear {
            if page == searchPageIndex { restartSearchCycle() }
        }
        .task(id: searchCycleToken) {
            await runSearchHighlightCycle()
        }
    }

    private func restartSearchCycle() {
        searchFocus = .library
        searchCycleToken &+= 1
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

    private func commitPage(_ newPage: Int) {
        allowTabPageChange = true
        page = newPage
        allowTabPageChange = false
    }

    private func advance() {
        if isNowPlayingLesson,
           let next = OnboardingNowPlayingStep(rawValue: nowPlayingStep.rawValue + 1) {
            nowPlayingStepDirection = 1
            withAnimation(stepAnimation) { nowPlayingStep = next }
            return
        }
        if page < pages.count - 1 {
            withAnimation(.easeInOut(duration: 0.28)) { commitPage(page + 1) }
        } else {
            finish()
        }
    }

    private func goBack() {
        if isNowPlayingLesson, nowPlayingStep.rawValue > 0,
           let prev = OnboardingNowPlayingStep(rawValue: nowPlayingStep.rawValue - 1) {
            nowPlayingStepDirection = -1
            withAnimation(stepAnimation) { nowPlayingStep = prev }
            return
        }
        if page > 0 {
            withAnimation(.easeInOut(duration: 0.28)) { commitPage(page - 1) }
        }
    }

    private var stepAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.28)
    }

    private func pageContent(index: Int) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    if index == nowPlayingControlsPageIndex {
                        OnboardingNowPlayingLessonView(
                            step: nowPlayingStep,
                            stepDirection: nowPlayingStepDirection,
                            reduceMotion: reduceMotion,
                            accessibilityLayout: accessibilityLayout,
                            onAdvance: advance)
                            .padding(.horizontal, accessibilityLayout ? 12 : 16)
                            .padding(.bottom, accessibilityLayout ? 8 : 10)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(pageAccessibilityLabel)
                            .accessibilityHint("Double tap to continue")
                            .accessibilityAction(.default) { advance() }
                    } else {
                        phonePreview(for: index)
                            .frame(maxWidth: accessibilityLayout ? 280 : 320)
                            .frame(maxHeight: accessibilityLayout ? 220 : 380)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 28)
                            .padding(.bottom, accessibilityLayout ? 12 : 14)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(pages[index].accessibilityMockLabel)

                        Text(pages[index].title)
                            .font(DromeTheme.titleFont)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .lineLimit(accessibilityLayout ? 3 : 2)
                            .minimumScaleFactor(0.85)
                            .padding(.horizontal, 28)
                            .padding(.bottom, accessibilityLayout ? 6 : 8)
                            .accessibilityAddTraits(.isHeader)

                        Text(pages[index].caption)
                            .font(.body)
                            .foregroundStyle(DromeTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 28)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, accessibilityLayout ? 2 : 6)
                .padding(.bottom, accessibilityLayout ? 20 : 8)
                .frame(
                    minHeight: accessibilityLayout ? nil : max(geo.size.height - 8, 0),
                    alignment: index == nowPlayingControlsPageIndex ? .top : .center)
            }
            .scrollIndicators(accessibilityLayout ? .visible : .automatic)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, DromeTheme.background],
                startPoint: .top,
                endPoint: .bottom)
                .frame(height: accessibilityLayout ? 28 : 16)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func phonePreview(for index: Int) -> some View {
        OnboardingScaledPhonePreview {
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
                    case 5:
                        OnboardingPlaylistsMock(reduceMotion: reduceMotion)
                    default:
                        OnboardingSettingsMock(reduceMotion: reduceMotion)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var bottomChrome: some View {
        VStack(spacing: 10) {
            pageDots

            Button(action: advance) {
                Text(continueLabel)
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
                    withAnimation(.easeInOut(duration: 0.28)) { commitPage(index) }
                } label: {
                    Group {
                        if index == page, isNowPlayingLesson {
                            OnboardingStepProgressPill(
                                progress: CGFloat(nowPlayingStep.rawValue + 1) / CGFloat(nowPlayingStepCount),
                                reduceMotion: reduceMotion)
                        } else {
                            Capsule()
                                .fill(index == page ? DromeTheme.accent : DromeTheme.divider)
                                .frame(width: index == page ? 18 : 7, height: 7)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tour")
        .accessibilityValue(tourPageValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                advance()
            case .decrement:
                goBack()
            @unknown default:
                break
            }
        }
    }

    private var tourPageValue: String {
        if isNowPlayingLesson {
            return "Page \(page + 1) of \(pages.count), Now Playing step \(nowPlayingStep.rawValue + 1) of \(nowPlayingStepCount)"
        }
        return "Page \(page + 1) of \(pages.count)"
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

/// Wider active page pill that fills left→right across Now Playing sub-steps.
private struct OnboardingStepProgressPill: View {
    let progress: CGFloat
    var reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DromeTheme.divider)
                Capsule()
                    .fill(DromeTheme.accent)
                    .frame(width: max(geo.size.width * clamped, geo.size.height))
                    .animation(
                        reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.28),
                        value: clamped)
            }
        }
        .frame(width: 56, height: 7)
    }
}

private struct OnboardingTourPage {
    let title: String
    let caption: String
    let accessibilityMockLabel: String
}
