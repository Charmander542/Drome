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
    @State private var nowPlayingStep: OnboardingNowPlayingStep = .artSwipe
    @State private var nowPlayingStepDirection: Int = 1
    /// One physical swipe → one advance (blocks art+page double-fire).
    @State private var gestureLockUntil: Date = .distantPast
    /// Cover frame in the tour coordinate space (step 1 art tip only).
    @State private var artCoverFrame: CGRect = .null
    /// When entering NP by swiping back from Playlists, land on tip 6.
    @State private var enterNowPlayingAtEnd = false

    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    private let searchPageIndex = 2
    private let nowPlayingControlsPageIndex = 4
    private let nowPlayingStepCount = OnboardingNowPlayingStep.allCases.count

    /// Named space so tour drag can exclude the cover hit target.
    private let tourSpace = "onboardingTour"

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
            title: "Now Playing",
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

    private var displayedTitle: String { pages[page].title }

    private var displayedCaption: String {
        if isNowPlayingLesson {
            return "\(nowPlayingStep.title) — \(nowPlayingStep.caption(compact: accessibilityLayout))"
        }
        return pages[page].caption
    }

    private var pageAccessibilityLabel: String {
        if isNowPlayingLesson { return nowPlayingStep.accessibilityLabel }
        return pages[page].accessibilityMockLabel
    }

    private var continueLabel: String {
        if isNowPlayingLesson {
            let n = nowPlayingStep.rawValue + 1
            if n < nowPlayingStepCount {
                return accessibilityLayout ? "\(n)/\(nowPlayingStepCount)" : "Continue · \(n) of \(nowPlayingStepCount)"
            }
            return "Continue"
        }
        if page < pages.count - 1 { return "Continue" }
        return "Start listening"
    }

    /// Fixed caption slot so 2- vs 3-line copy doesn’t shift mock/title.
    private var captionSlotHeight: CGFloat { accessibilityLayout ? 96 : 64 }

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

                pageChrome
                    .id(page)
                    .transition(pageTransition)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Not highPriority — cover’s highPriorityGesture must win on step 1.
                    .gesture(tourDragGesture)
                    .coordinateSpace(name: tourSpace)
                    .onPreferenceChange(OnboardingArtCoverFrameKey.self) { artCoverFrame = $0 }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomChrome
            }
        }
        .preferredColorScheme(.dark)
        .animation(chromeAnimation, value: page)
        .onChange(of: page) { oldPage, newPage in
            if newPage == searchPageIndex { restartSearchCycle() }
            if newPage == nowPlayingControlsPageIndex {
                if enterNowPlayingAtEnd || oldPage > nowPlayingControlsPageIndex {
                    nowPlayingStep = .lyrics
                    nowPlayingStepDirection = -1
                } else {
                    nowPlayingStep = .artSwipe
                    nowPlayingStepDirection = 1
                }
                enterNowPlayingAtEnd = false
            }
        }
        .onAppear {
            if page == searchPageIndex { restartSearchCycle() }
        }
        .task(id: searchCycleToken) {
            await runSearchHighlightCycle()
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: OnboardingTourChrome.pageTransitionX)),
            removal: .opacity.combined(with: .offset(x: -OnboardingTourChrome.pageTransitionX)))
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let x = OnboardingTourChrome.stepTransitionX * CGFloat(nowPlayingStepDirection)
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: x)),
            removal: .opacity.combined(with: .offset(x: -x)))
    }

    private var chromeAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.28)
    }

    private var tourDragGesture: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .named(tourSpace))
            .onEnded { value in
                // Drags that begin on the cover are owned by the art tip.
                if isNowPlayingLesson,
                   nowPlayingStep == .artSwipe,
                   artCoverFrame.contains(value.startLocation) {
                    return
                }
                guard Date() >= gestureLockUntil else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.25, abs(dx) > 48 else { return }
                lockGesture()
                if dx < 0 {
                    advance(allowFinish: false)
                } else {
                    goBack()
                }
            }
    }

    private func lockGesture() {
        gestureLockUntil = Date().addingTimeInterval(0.45)
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
        if newPage == nowPlayingControlsPageIndex, page > nowPlayingControlsPageIndex {
            enterNowPlayingAtEnd = true
        }
        page = newPage
    }

    /// - Parameter allowFinish: Swipes never dismiss; only Start listening does.
    private func advance(allowFinish: Bool = true) {
        if isNowPlayingLesson,
           let next = OnboardingNowPlayingStep(rawValue: nowPlayingStep.rawValue + 1) {
            nowPlayingStepDirection = 1
            nowPlayingStep = next
            return
        }
        if page < pages.count - 1 {
            commitPage(page + 1)
        } else if allowFinish {
            finish()
        }
    }

    private func goBack() {
        if isNowPlayingLesson, nowPlayingStep.rawValue > 0,
           let prev = OnboardingNowPlayingStep(rawValue: nowPlayingStep.rawValue - 1) {
            nowPlayingStepDirection = -1
            nowPlayingStep = prev
            return
        }
        if page > 0 {
            // Leaving Playlists (or later) back into NP → tip 6.
            if page - 1 == nowPlayingControlsPageIndex {
                enterNowPlayingAtEnd = true
            }
            commitPage(page - 1)
        }
    }

    // MARK: - Unified page chrome (mock → title → caption)

    private var pageChrome: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    phonePreview(for: page)
                        .frame(
                            maxWidth: accessibilityLayout
                                ? OnboardingTourChrome.mockMaxWidthAX
                                : OnboardingTourChrome.mockMaxWidth)
                        .frame(
                            maxHeight: accessibilityLayout
                                ? OnboardingTourChrome.mockMaxHeightAX
                                : OnboardingTourChrome.mockMaxHeight)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, OnboardingTourChrome.mockHorizontalPadding)
                        .padding(
                            .bottom,
                            accessibilityLayout
                                ? OnboardingTourChrome.mockBottomSpacingAX
                                : OnboardingTourChrome.mockBottomSpacing)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(pageAccessibilityLabel)

                    Text(displayedTitle)
                        .font(DromeTheme.titleFont)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .lineLimit(accessibilityLayout ? 3 : 2)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, OnboardingTourChrome.captionHorizontalPadding)
                        .padding(
                            .bottom,
                            accessibilityLayout
                                ? OnboardingTourChrome.titleBottomSpacingAX
                                : OnboardingTourChrome.titleBottomSpacing)
                        .accessibilityAddTraits(.isHeader)

                    captionBlock
                        .padding(.horizontal, OnboardingTourChrome.captionHorizontalPadding)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard isNowPlayingLesson else { return }
                            lockGesture()
                            advance(allowFinish: false)
                        }
                        .id(isNowPlayingLesson ? "np-cap-\(nowPlayingStep.rawValue)" : "tour-caption")
                        .transition(stepTransition)
                        .animation(chromeAnimation, value: nowPlayingStep)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, accessibilityLayout ? 2 : 6)
                // Keep last lines clear of the opaque bottom chrome.
                .padding(.bottom, accessibilityLayout ? 12 : 8)
                .frame(
                    minHeight: accessibilityLayout ? nil : max(geo.size.height - 8, 0),
                    alignment: .center)
            }
            .scrollIndicators(accessibilityLayout ? .visible : .automatic)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Non-AX: fixed slot so layout doesn’t shift. AX5: grow with full text (scrollable).
    @ViewBuilder
    private var captionBlock: some View {
        let text = Text(displayedCaption)
            .font(.body)
            .foregroundStyle(DromeTheme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .top)

        if accessibilityLayout {
            text
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: captionSlotHeight, alignment: .top)
        } else {
            text
                .lineLimit(3)
                .minimumScaleFactor(0.9)
                .frame(height: captionSlotHeight, alignment: .top)
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
                    case 4:
                        OnboardingNowPlayingControlsMock(
                            step: nowPlayingStep,
                            reduceMotion: reduceMotion,
                            tourCoordinateSpace: tourSpace)
                    case 5:
                        OnboardingPlaylistsMock(reduceMotion: reduceMotion)
                    default:
                        OnboardingSettingsMock(reduceMotion: reduceMotion)
                    }
                }
                .allowsHitTesting(index == nowPlayingControlsPageIndex)
            }
        }
    }

    private var bottomChrome: some View {
        VStack(spacing: 10) {
            pageDots

            Button {
                lockGesture()
                advance(allowFinish: true)
            } label: {
                Text(continueLabel)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, OnboardingTourChrome.continueVerticalPadding)
                    .background(
                        DromeTheme.accent,
                        in: RoundedRectangle(
                            cornerRadius: OnboardingTourChrome.continueCorner,
                            style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("onboarding-continue")
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        // Opaque so scroll content never peeks under dots / CTA (AX5).
        .background(DromeTheme.background)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pages.count, id: \.self) { index in
                Button {
                    lockGesture()
                    commitPage(index)
                } label: {
                    // Reserve pill width on every active page so page 5 doesn’t shift.
                    ZStack {
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
                    .frame(width: index == page ? 56 : 7, height: 7)
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
                lockGesture(); advance(allowFinish: true)
            case .decrement:
                lockGesture(); goBack()
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

/// Cover hit target reported by the NP art tip (tour coordinate space).
struct OnboardingArtCoverFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        // Always take the latest report so leaving the art tip clears the hit target.
        value = nextValue()
    }
}

private struct OnboardingStepProgressPill: View {
    let progress: CGFloat
    var reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(DromeTheme.divider)
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
