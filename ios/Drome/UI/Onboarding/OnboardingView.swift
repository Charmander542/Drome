import SwiftUI

/// First-run walkthrough after sign-in. Device-style mocks show where
/// controls live — skip anytime.
struct OnboardingView: View {
    let userKey: String
    var onFinished: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var accentStore = AccentStore.shared
    @State private var page = 0
    @State private var searchFocus: OnboardingSearchFocus = .library
    @State private var searchCycleToken = 0
    @State private var nowPlayingStep: OnboardingNowPlayingStep = .navigate
    @State private var nowPlayingStepDirection: Int = 1
    /// One physical swipe → one advance (blocks art+page double-fire).
    @State private var gestureLockUntil: Date = .distantPast
    /// Cover frame in the tour coordinate space (navigate tip only).
    @State private var artCoverFrame: CGRect = .null
    /// When entering NP by swiping back from Playlists, land on the last tip.
    @State private var enterNowPlayingAtEnd = false
    /// Measured height of brand + title + caption + controls (excludes the phone mock).
    @State private var measuredCopyHeight: CGFloat = 180

    /// Grows with Dynamic Type so Large XXL captions aren’t clipped.
    @ScaledMetric(relativeTo: .body) private var captionBaseHeight: CGFloat = 72
    /// Stable title slot so pages don’t shift ~20pt when titles wrap differently.
    @ScaledMetric(relativeTo: .largeTitle) private var titleBaseHeight: CGFloat = 52

    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var liveAccent: Color { accentStore.color }

    private let searchPageIndex = 2
    private let nowPlayingControlsPageIndex = 4
    /// Final page — theme accent chooser after Keep Playing.
    private let accentPageIndex = 7
    private let nowPlayingStepCount = OnboardingNowPlayingStep.allCases.count

    /// Named space so tour drag can exclude the cover hit target.
    private let tourSpace = "onboardingTour"

    private let pages: [OnboardingTourPage] = [
        OnboardingTourPage(
            title: "Your music, tuned to you",
            caption: "Daily Mixes and Vibe Tuner on Home — private listening that learns what you love.",
            accessibilityMockLabel: "Home screen preview with the DROME wordmark, Settings gear, Vibe Tuner near the top, and the tab bar at the bottom."),
        OnboardingTourPage(
            title: "Everything in reach",
            caption: "Jump between Home, Search, Your Library, and Podcasts from the tab bar.",
            accessibilityMockLabel: "Your Library preview. The Home, Search, Your Library, and Podcasts tabs are highlighted in the tab bar."),
        OnboardingTourPage(
            title: "Find it fast",
            caption: "Search your library, Spotify, or podcasts — then filter songs, albums, artists, or playlists.",
            accessibilityMockLabel: "Search screen. Use Library, Spotify, or Podcasts. In Library mode, the filter chips are All, Songs, Albums, Artists, and Playlists."),
        OnboardingTourPage(
            title: "Shape what plays next",
            caption: "High ratings feed your mixes; one or two stars quietly park a track in Out of Rotation.",
            accessibilityMockLabel: "Star rating is on the Now Playing screen, below the track title. One or two stars move a track to Out of Rotation."),
        OnboardingTourPage(
            title: "Now Playing",
            caption: "",
            accessibilityMockLabel: ""),
        OnboardingTourPage(
            title: "Share the vibe",
            caption: "Build a playlist from Your Library, then share it from the playlist ··· menu.",
            accessibilityMockLabel: "Your Library plus button creates a playlist. Share Playlist is in the playlist detail more menu."),
        OnboardingTourPage(
            title: "Never hit silence",
            caption: "Keep Playing adds more when the queue ends — same switch lives in Settings → Playback.",
            accessibilityMockLabel: "Settings is opened from the Home gear button. Keep Playing is in the Playback section — the same Autoplay switch as Now Playing ··· → Keep Playing."),
        OnboardingTourPage(
            title: "Make it yours",
            caption: "Pick a theme color — buttons, highlights, and vibes follow it. Change it anytime in Settings.",
            accessibilityMockLabel: "Choose a theme accent color. Preset swatches and a custom color picker update the tour preview live. You can change this later in Settings."),
    ]

    private var isNowPlayingLesson: Bool { page == nowPlayingControlsPageIndex }

    private var displayedTitle: String {
        if isNowPlayingLesson { return nowPlayingStep.title }
        return pages[page].title
    }

    private var displayedCaption: String {
        if isNowPlayingLesson {
            return nowPlayingStep.caption(compact: accessibilityLayout)
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
                return accessibilityLayout ? "Next" : "Continue · \(n) of \(nowPlayingStepCount)"
            }
            return "Continue"
        }
        if page < pages.count - 1 { return "Continue" }
        return "Start listening"
    }

    /// Tallest caption across tour + NP tips — reserves space so pages don’t jump.
    private var longestCaption: String {
        let tour = pages.map(\.caption).filter { !$0.isEmpty }
        let np = OnboardingNowPlayingStep.allCases.map { $0.caption(compact: accessibilityLayout) }
        return (tour + np).max(by: { $0.count < $1.count }) ?? displayedCaption
    }

    private var longestTitle: String {
        let tour = pages.map(\.title)
        let np = OnboardingNowPlayingStep.allCases.map(\.title)
        return (tour + np).max(by: { $0.count < $1.count }) ?? displayedTitle
    }

    private var skipHeader: some View {
        HStack {
            Spacer()
            Button("Skip") { finish() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.88))
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                // Survives parent screen ID — tests look up this button directly.
                .accessibilityIdentifier("drome.onboarding.skip")
                .accessibilityLabel("Skip onboarding")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 2)
        // Fade into the ambient amber glow — no flat opaque band / hard seam.
        .background {
            LinearGradient(
                stops: [
                    .init(color: DromeTheme.background.opacity(0.92), location: 0),
                    .init(color: DromeTheme.background.opacity(0.55), location: 0.55),
                    .init(color: DromeTheme.background.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom)
            .padding(.bottom, -22)
            .allowsHitTesting(false)
        }
        .zIndex(1)
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        ZStack {
            DromeTheme.background.ignoresSafeArea()
            ambientGlow
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                skipHeader

                pageChrome
                    .id(page)
                    .transition(pageTransition)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Not highPriority — cover’s highPriorityGesture must win on navigate tip.
                    .gesture(tourDragGesture)
                    .coordinateSpace(name: tourSpace)
                    .onPreferenceChange(OnboardingArtCoverFrameKey.self) { artCoverFrame = $0 }
                    .accessibilityIdentifier("drome.onboarding.screen")
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
                    nowPlayingStep = OnboardingNowPlayingStep.allCases.last ?? .more
                    nowPlayingStepDirection = -1
                } else {
                    nowPlayingStep = .navigate
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
                   nowPlayingStep == .navigate,
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
            // Leaving Playlists (or later) back into NP → last tip.
            if page - 1 == nowPlayingControlsPageIndex {
                enterNowPlayingAtEnd = true
            }
            commitPage(page - 1)
        }
    }

    // MARK: - Unified page chrome (mock → title → caption)

    private var pageChrome: some View {
        GeometryReader { geo in
            let hardCap = accessibilityLayout
                ? OnboardingTourChrome.mockMaxHeightAX
                : (page == 0
                    ? OnboardingTourChrome.mockMaxHeightHero
                    : (page == accentPageIndex
                        ? OnboardingTourChrome.mockMaxHeightAccent
                        : OnboardingTourChrome.mockMaxHeight))
            // Scroll padding + mock bottom spacing aren’t in the measured copy stack.
            let chromePad: CGFloat = accessibilityLayout ? 46 : 36
            let mockBottom: CGFloat = accessibilityLayout
                ? OnboardingTourChrome.mockBottomSpacingAX
                : OnboardingTourChrome.mockBottomSpacing
            let leftover = geo.size.height - measuredCopyHeight - chromePad - mockBottom
            // Mock only gets leftover space — never steal caption lines.
            // Short screens (SE): hard-cap at ~42% so title/caption/swatches always fit.
            // No 0.48×height floor (that was clipping captions on SE / xxxLarge).
            let shortScreen = geo.size.height < 700
            let shortCap = shortScreen ? geo.size.height * 0.42 : .infinity
            let mockCap = min(hardCap, shortCap, max(160, leftover))
            let contentFits = (mockCap + measuredCopyHeight + chromePad + mockBottom)
                <= geo.size.height + 1
            let showScrollIndicators = accessibilityLayout
                || dynamicTypeSize >= .xxxLarge
                || !contentFits

            ScrollView {
                VStack(spacing: 0) {
                    if page == 0 {
                        Text("DROME")
                            .font(DromeTheme.brandFont)
                            .foregroundStyle(liveAccent)
                            .tracking(1.6)
                            .padding(.bottom, accessibilityLayout ? 6 : 10)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityHidden(true)
                            .onboardingReserveHeight()
                    }

                    phonePreview(for: page)
                        .frame(
                            maxWidth: accessibilityLayout
                                ? OnboardingTourChrome.mockMaxWidthAX
                                : OnboardingTourChrome.mockMaxWidth)
                        .frame(maxHeight: mockCap)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, OnboardingTourChrome.mockHorizontalPadding)
                        .padding(.bottom, mockBottom)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(pageAccessibilityLabel)

                    VStack(spacing: 0) {
                        if isNowPlayingLesson {
                            Text("NOW PLAYING")
                                .font(DromeTheme.overlineFont)
                                .tracking(1.4)
                                .foregroundStyle(liveAccent.opacity(0.95))
                                .padding(.bottom, 4)
                                .accessibilityHidden(true)
                        }

                        titleBlock
                            .padding(.horizontal, OnboardingTourChrome.captionHorizontalPadding)
                            .padding(
                                .bottom,
                                accessibilityLayout
                                    ? OnboardingTourChrome.titleBottomSpacingAX
                                    : OnboardingTourChrome.titleBottomSpacing)

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

                        if page == accentPageIndex {
                            OnboardingAccentChooser(reduceMotion: reduceMotion)
                                .padding(.horizontal, OnboardingTourChrome.captionHorizontalPadding)
                                .padding(.top, accessibilityLayout ? 10 : 6)
                        }
                    }
                    .onboardingReserveHeight()
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, accessibilityLayout ? 6 : 8)
                // Keep last lines clear of the soft bottom chrome fade.
                .padding(.bottom, accessibilityLayout ? 28 : 20)
                .frame(
                    minHeight: max(geo.size.height - 8, 0),
                    // Only center when everything fits — otherwise top-align so
                    // captions scroll into view instead of sitting under the bar.
                    alignment: contentFits ? .center : .top)
            }
            .scrollIndicators(showScrollIndicators ? .visible : .automatic)
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(OnboardingReservedHeightKey.self) { height in
                // Avoid feedback loops from sub-point noise.
                if abs(height - measuredCopyHeight) > 1 {
                    measuredCopyHeight = height
                }
            }
            .onChange(of: page) { _, _ in
                // Seed until the next preference pass; avoids one-frame oversize mock.
                measuredCopyHeight = page == accentPageIndex ? 220 : 180
            }
        }
    }

    /// Reserved height from the longest title so pages don’t jump.
    private var titleBlock: some View {
        ZStack {
            Text(longestTitle)
                .font(DromeTheme.titleFont)
                .multilineTextAlignment(.center)
                .lineLimit(accessibilityLayout ? 3 : 2)
                .minimumScaleFactor(0.85)
                .hidden()
                .accessibilityHidden(true)
            Text(displayedTitle)
                .font(DromeTheme.titleFont)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .lineLimit(accessibilityLayout ? 3 : 2)
                .minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, minHeight: titleBaseHeight)
    }

    /// Grows with Dynamic Type; reserves height from the longest caption so pages don’t jump.
    @ViewBuilder
    private var captionBlock: some View {
        let style = captionText(displayedCaption)
        ZStack(alignment: .top) {
            captionText(longestCaption)
                .hidden()
                .accessibilityHidden(true)
            style
        }
        .frame(maxWidth: .infinity, minHeight: captionBaseHeight, alignment: .top)
    }

    private func captionText(_ string: String) -> some View {
        Text(string)
            .font(.body)
            .foregroundStyle(DromeTheme.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
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
                    case 6:
                        OnboardingSettingsMock(reduceMotion: reduceMotion)
                    default:
                        OnboardingAccentMock(reduceMotion: reduceMotion, compact: true)
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
                        liveAccent,
                        in: RoundedRectangle(
                            cornerRadius: OnboardingTourChrome.continueCorner,
                            style: .continuous))
                    .foregroundStyle(DromeTheme.contrastingInk(on: liveAccent))
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.78),
                        value: accentStore.preset)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.78),
                        value: accentStore.customRGB)
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("onboarding-continue")
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        // Opaque fill over the whole chrome (including dots) so AX5 text can’t
        // peek between dots; fade lives only above the bar.
        .background {
            DromeTheme.background
                .ignoresSafeArea(edges: .bottom)
                .padding(.top, -24)
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [DromeTheme.background.opacity(0), DromeTheme.background],
                startPoint: .top,
                endPoint: .bottom)
                .frame(height: 24)
                .offset(y: -24)
                .allowsHitTesting(false)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pages.count, id: \.self) { index in
                Button {
                    lockGesture()
                    commitPage(index)
                } label: {
                    ZStack {
                        if index == page, isNowPlayingLesson {
                            OnboardingStepProgressPill(
                                progress: CGFloat(nowPlayingStep.rawValue + 1) / CGFloat(nowPlayingStepCount),
                                reduceMotion: reduceMotion)
                        } else {
                            Capsule()
                                .fill(index == page ? liveAccent : Color.white.opacity(0.35))
                                .frame(width: index == page ? 18 : 7, height: 7)
                        }
                    }
                    .frame(width: index == page ? 56 : 7, height: 7)
                    // Expand hit target to 44pt without pushing neighbors apart.
                    .padding(18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-18)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
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
            colors: [liveAccent.opacity(0.16), liveAccent.opacity(0.04), .clear],
            center: UnitPoint(x: 0.5, y: 0.16),
            startRadius: 20,
            endRadius: 380)
        .ignoresSafeArea()
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.28),
            value: accentStore.preset)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.28),
            value: accentStore.customRGB)
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

/// Sums measured heights of brand + copy/controls so the mock only takes leftover space.
private struct OnboardingReservedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private extension View {
    /// Reports this view’s laid-out height into `OnboardingReservedHeightKey`.
    func onboardingReserveHeight() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: OnboardingReservedHeightKey.self,
                    value: geo.size.height)
            }
        }
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
                    .fill(AccentStore.shared.color)
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
