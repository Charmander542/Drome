import SwiftUI

// MARK: - Spotlight chrome

/// Accent ring around a control. Labels are drawn separately so they never
/// resize the control (see `OnboardingCalloutLabel`).
struct OnboardingSpotlightRing<Content: View>: View {
    let isActive: Bool
    let reduceMotion: Bool
    var cornerRadius: CGFloat = 10
    @ViewBuilder var content: () -> Content

    @State private var pulse = false

    var body: some View {
        content()
            .padding(3)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DromeTheme.accent.opacity(0.12))
                }
            }
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(DromeTheme.accent, lineWidth: 2)
                        .scaleEffect(pulse && !reduceMotion ? 1.04 : 1)
                        .opacity(pulse && !reduceMotion ? 0.55 : 1)
                }
            }
            .onAppear { restartPulse() }
            .onChange(of: isActive) { _, active in
                if active { restartPulse() } else { pulse = false }
            }
            .onChange(of: reduceMotion) { _, _ in restartPulse() }
    }

    private func restartPulse() {
        pulse = false
        guard isActive, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// Fixed-size callout chip — never uses Dynamic Type.
struct OnboardingCalloutLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DromeTheme.accent, in: Capsule())
            .allowsHitTesting(false)
    }
}

/// Convenience: ring + optional above-layout callout for non-segment controls.
struct OnboardingSpotlight<Content: View>: View {
    let label: String
    let isActive: Bool
    let reduceMotion: Bool
    /// When true, callout sits in a fixed-height slot above the control (no layout jump).
    var overlayCallout: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 4) {
            if overlayCallout {
                ZStack {
                    if isActive {
                        OnboardingCalloutLabel(text: label)
                            .transition(.opacity)
                    }
                }
                .frame(height: 20)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: isActive)
            } else if isActive {
                OnboardingCalloutLabel(text: label)
            }

            OnboardingSpotlightRing(isActive: isActive, reduceMotion: reduceMotion) {
                content()
            }
        }
    }
}

enum OnboardingMockDesign {
    /// Intrinsic canvas — mocks always lay out at this size, then scale to fit.
    static let width: CGFloat = 300
    static let height: CGFloat = 420
}

struct OnboardingPhoneFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Cap type inside the mock; sizing/clipping handled by OnboardingScaledPhonePreview.
        content()
            .dynamicTypeSize(...DynamicTypeSize.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DromeTheme.background)
    }
}

/// Renders the phone mock at a fixed design size, then `scaleEffect`s to fit
/// the available frame (aspect-fit) so AX short frames shrink the whole mock
/// — including rings/callouts — instead of clipping highlighted controls.
struct OnboardingScaledPhonePreview<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Color.clear
            .aspectRatio(
                OnboardingMockDesign.width / OnboardingMockDesign.height,
                contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let scale = min(
                        geo.size.width / OnboardingMockDesign.width,
                        geo.size.height / OnboardingMockDesign.height)
                    content()
                        .frame(
                            width: OnboardingMockDesign.width,
                            height: OnboardingMockDesign.height)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        }
                        .scaleEffect(scale)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }
}

struct OnboardingMockTabBar: View {
    var selected: Int
    var dimmed: Bool = false
    var highlightAll: Bool = false
    var reduceMotion: Bool = false

    private let tabs: [(title: String, symbol: String)] = [
        ("Home", "house.fill"),
        ("Search", "magnifyingglass"),
        ("Your Library", "rectangle.stack.fill"),
        ("Podcasts", "headphones"),
    ]

    var body: some View {
        let bar = HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                VStack(spacing: 2) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .semibold))
                    Text(tab.title)
                        .font(.system(size: 6, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .foregroundStyle(index == selected ? DromeTheme.accent : DromeTheme.muted)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 5)
        .padding(.bottom, 4)
        .background(DromeTheme.elevated)
        .overlay(alignment: .top) {
            Rectangle().fill(DromeTheme.divider).frame(height: 0.5)
        }
        .opacity(dimmed && !highlightAll ? 0.4 : 1)

        if highlightAll {
            // Inset so the spotlight ring isn't clipped by the phone-frame corners.
            OnboardingSpotlight(
                label: "Tabs",
                isActive: true,
                reduceMotion: reduceMotion,
                overlayCallout: true
            ) {
                bar
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        } else {
            bar
        }
    }
}

private struct MockArtTile: View {
    let colors: [Color]
    var corner: CGFloat = 8
    var symbol: String = "music.note"

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
    }
}

// MARK: - Page mocks

struct OnboardingHomeMock: View {
    var reduceMotion: Bool
    var highlightVibe: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Real Home has no large title — only the account avatar.
            HStack {
                Spacer()
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(DromeTheme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .opacity(0.7)

            VStack(alignment: .leading, spacing: 10) {
                OnboardingSpotlight(
                    label: "Vibe Tuner",
                    isActive: highlightVibe,
                    reduceMotion: reduceMotion,
                    overlayCallout: true
                ) {
                    vibeCard
                }
                .padding(.horizontal, 10)

                dailyMixes
                    .opacity(highlightVibe ? 0.42 : 1)
                    .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            OnboardingMockTabBar(selected: 0, dimmed: highlightVibe)
        }
        .background(DromeTheme.background)
    }

    private var vibeCard: some View {
        // Match real Vibe Tuner: orange Hype wash + full 7-station dial.
        let vibe = MoodVibe.hype
        return VStack(alignment: .leading, spacing: 8) {
            Text("VIBE TUNER")
                .font(.system(size: 8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(vibe.ink.opacity(0.75))
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vibe.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text(vibe.blurb)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                Text("Play")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(vibe.ink, in: Capsule())
            }
            HStack(spacing: 0) {
                ForEach(MoodVibe.spectrum, id: \.id) { item in
                    VStack(spacing: 3) {
                        Circle()
                            .fill(item == vibe ? vibe.ink : Color.white.opacity(0.22))
                            .frame(width: item == vibe ? 12 : 7, height: item == vibe ? 12 : 7)
                        Text(item.shortLabel)
                            .font(.system(size: 6, weight: .medium))
                            .foregroundStyle(item == vibe ? .white : Color.white.opacity(0.45))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(vibe.wash.opacity(0.95))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(vibe.ink.opacity(0.22), lineWidth: 1)
                }
        }
    }

    private var dailyMixes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Daily Mixes")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        MockArtTile(
                            colors: index == 0
                                ? [Color(hex: "#2A9D8F"), Color(hex: "#1D3557")]
                                : index == 1
                                    ? [Color(hex: "#E76F51"), Color(hex: "#264653")]
                                    : [Color(hex: "#9B5DE5"), Color(hex: "#1D3557")],
                            corner: 6)
                            .frame(width: 56, height: 56)
                        Text("Daily Mix \(index + 1)")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct OnboardingBrowseMock: View {
    var reduceMotion: Bool

    private let filters = ["Playlists", "Artists", "Albums", "Songs", "Genres"]

    var body: some View {
        VStack(spacing: 0) {
            // Match real Library chrome: heart · Your Library · +
            HStack {
                Image(systemName: "heart")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(DromeTheme.muted)
                    .frame(width: 22)
                Spacer()
                Text("Your Library")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DromeTheme.muted)
                    .frame(width: 22)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .opacity(0.55)

            HStack(spacing: 0) {
                ForEach(filters, id: \.self) { title in
                    Text(title)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(title == "Playlists" ? .white : DromeTheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)
                        .overlay(alignment: .bottom) {
                            if title == "Playlists" {
                                Capsule().fill(DromeTheme.accent).frame(height: 2)
                            }
                        }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .opacity(0.55)

            VStack(spacing: 0) {
                libraryRow("Create playlist", "plus.circle.fill", accent: true)
                libraryRow("Downloaded", "arrow.down.circle.fill")
                libraryRow("Wishlist", "heart.fill")
                libraryRow("Top Rated", "star.fill")
                libraryRow("Out of Rotation", "lock.fill")
            }
            .padding(.horizontal, 8)
            .opacity(0.45)

            Spacer(minLength: 0)

            OnboardingMockTabBar(selected: 2, highlightAll: true, reduceMotion: reduceMotion)
        }
        .background(DromeTheme.background)
    }

    private func libraryRow(_ title: String, _ symbol: String, accent: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent ? DromeTheme.accent : DromeTheme.muted)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent ? DromeTheme.accent : .white)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(DromeTheme.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.bottom, 3)
    }
}

enum OnboardingSearchFocus: Int, CaseIterable {
    case library
    case spotify
    case podcasts
    case lyrics

    var callout: String {
        switch self {
        case .library: return "Library"
        case .spotify: return "Spotify"
        case .podcasts: return "Podcasts"
        case .lyrics: return "Lyrics"
        }
    }
}

struct OnboardingSearchMock: View {
    var focus: OnboardingSearchFocus
    var reduceMotion: Bool
    var showAllCallouts: Bool = false

    private var selectedSource: OnboardingSearchFocus {
        switch focus {
        case .lyrics: return .library
        default: return focus
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Real Search uses a small centered nav title.
            Text("Search")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 6)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .opacity(0.55)

            searchControls
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            resultsPlaceholder
                .opacity(0.4)
                .padding(.horizontal, 12)

            Spacer(minLength: 0)

            OnboardingMockTabBar(selected: 1, dimmed: true)
        }
        .background(DromeTheme.background)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(DromeTheme.muted)
            Text(prompt)
                .font(.system(size: 11))
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var prompt: String {
        switch selectedSource {
        case .library, .lyrics: return "Artists, songs, albums…"
        case .spotify: return "Search Spotify tracks, albums…"
        case .podcasts: return "Search podcasts or paste feed URL…"
        }
    }

    /// Per-control callout above its own ring (so Lyrics sits over the quote
    /// button, not the center of the row). Rings switch instantly to avoid
    /// two rings during crossfade; callouts fade.
    private var searchControls: some View {
        Group {
            if showAllCallouts {
                VStack(spacing: 4) {
                    OnboardingCalloutLabel(text: "Library · Spotify · Podcasts · Lyrics")
                        .frame(height: 20)
                    HStack(spacing: 8) {
                        sourceSegments(ringMode: nil)
                        lyricsChip(ringActive: false)
                    }
                    .frame(height: 32)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    sourceSegments(ringMode: focus)
                    controlColumn(callout: "Lyrics", showCallout: focus == .lyrics) {
                        lyricsChip(ringActive: focus == .lyrics)
                    }
                }
            }
        }
    }

    private func controlColumn<Control: View>(
        callout: String,
        showCallout: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 4) {
            ZStack {
                if showCallout {
                    OnboardingCalloutLabel(text: callout)
                        .transition(.opacity)
                }
            }
            .frame(height: 20)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: showCallout)

            control()
                .frame(height: 32)
                // Rings snap — only the callout crossfades.
                .transaction { $0.animation = nil }
        }
    }

    private func sourceSegments(ringMode: OnboardingSearchFocus?) -> some View {
        HStack(spacing: 0) {
            segment(.library, title: "Library", ringMode: ringMode)
            segment(.spotify, title: "Spotify", ringMode: ringMode)
            segment(.podcasts, title: "Podcasts", ringMode: ringMode)
        }
        .padding(2)
        .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func segment(
        _ mode: OnboardingSearchFocus,
        title: String,
        ringMode: OnboardingSearchFocus?
    ) -> some View {
        let selected = selectedSource == mode
        let ringActive = ringMode == mode
        let chip = OnboardingSpotlightRing(
            isActive: ringActive,
            reduceMotion: reduceMotion,
            cornerRadius: 6
        ) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? .white : DromeTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(DromeTheme.elevated)
                    }
                }
        }

        // Each segment owns its callout column so the label stays centered on it.
        if ringMode != nil {
            return AnyView(
                controlColumn(callout: title, showCallout: ringMode == mode) { chip }
                    .frame(maxWidth: .infinity)
            )
        }
        return AnyView(chip.frame(maxWidth: .infinity))
    }

    private func lyricsChip(ringActive: Bool) -> some View {
        OnboardingSpotlightRing(
            isActive: ringActive,
            reduceMotion: reduceMotion,
            cornerRadius: 7
        ) {
            Image(systemName: "text.quote")
                .symbolVariant(focus == .lyrics || showAllCallouts ? .fill : .none)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focus == .lyrics || showAllCallouts ? DromeTheme.accent : Color.white.opacity(0.7))
                .frame(width: 26, height: 26)
                .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var resultsPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 8) {
                    MockArtTile(
                        colors: [DromeTheme.elevated2, DromeTheme.elevated],
                        corner: index == 0 ? 14 : 5,
                        symbol: index == 0 ? "person.crop.circle" : "music.note")
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 84 - CGFloat(index * 12), height: 6)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 52, height: 5)
                    }
                    Spacer()
                }
            }
        }
    }
}

struct OnboardingNowPlayingMock: View {
    var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 34, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .opacity(0.5)

            MockArtTile(
                colors: [Color(hex: "#264653"), Color(hex: "#2A9D8F")],
                corner: 10,
                symbol: "music.note")
                .frame(width: 110, height: 110)
                .padding(.bottom, 10)
                .opacity(0.45)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Midnight Drive")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Neon Harbor")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .opacity(0.45)

            OnboardingSpotlight(
                label: "Stars",
                isActive: true,
                reduceMotion: reduceMotion,
                overlayCallout: true
            ) {
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= 2 ? "star.fill" : "star")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(star <= 2 ? RatingStyle.color(for: 2) : DromeTheme.muted)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            Text("1–2★ → Out of Rotation")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DromeTheme.accent)
                .padding(.bottom, 8)

            VStack(spacing: 8) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.white)
                            .frame(width: 48, height: 3)
                    }
                    .padding(.horizontal, 16)
                HStack(spacing: 24) {
                    Image(systemName: "shuffle")
                    Image(systemName: "backward.fill")
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 24))
                    Image(systemName: "forward.fill")
                    Image(systemName: "repeat")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            }
            .opacity(0.4)

            Spacer(minLength: 4)
        }
        .background(DromeTheme.background)
    }
}

/// Manual steps on the Now Playing controls lesson (Continue advances).
enum OnboardingNowPlayingStep: Int, CaseIterable {
    case artSwipe
    case shuffle
    case `repeat`
    case keepPlaying
    case queue
    case lyrics

    var title: String {
        switch self {
        case .artSwipe: return "Swipe the artwork"
        case .shuffle: return "Shuffle"
        case .repeat: return "Repeat"
        case .keepPlaying: return "Keep Playing ∞"
        case .queue: return "Queue"
        case .lyrics: return "Song & Lyrics"
        }
    }

    /// Plain-language caption matching real PlayerEngine / NowPlayingView behavior.
    var caption: String {
        switch self {
        case .artSwipe:
            return "Swipe album art left for the next song, right for the previous."
        case .shuffle:
            return "Shuffle: Off plays in list order. Smart favors higher-rated tracks. Random plays this list in random order."
        case .repeat:
            return "Repeat: tap once to repeat the list, twice for one song, again to turn off."
        case .keepPlaying:
            return "∞ Keep Playing: when your queue ends, Drome keeps playing similar songs."
        case .queue:
            return "Queue: opens the upcoming tracks so you can reorder or clear what’s next."
        case .lyrics:
            return "Song / Lyrics: switch panes for the player or synced lyrics. Swipe up on art also opens Lyrics."
        }
    }

    var accessibilityLabel: String { "\(title). \(caption)" }

    var symbolName: String {
        switch self {
        case .artSwipe: return "hand.draw"
        case .shuffle: return "shuffle"
        case .repeat: return "repeat"
        case .keepPlaying: return "infinity"
        case .queue: return "list.bullet"
        case .lyrics: return "text.quote"
        }
    }
}

/// Close-up Now Playing control lesson — large buttons, one step at a time.
struct OnboardingNowPlayingLessonView: View {
    let step: OnboardingNowPlayingStep
    var reduceMotion: Bool
    /// Tap the lesson (or Continue) to advance within the page.
    var onAdvance: (() -> Void)? = nil

    @State private var swipeHintOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 18) {
            stepBadge

            Group {
                switch step {
                case .artSwipe:
                    artSwipeCloseup
                case .shuffle:
                    shuffleCloseup
                case .repeat:
                    repeatCloseup
                case .keepPlaying:
                    keepPlayingCloseup
                case .queue:
                    queueCloseup
                case .lyrics:
                    lyricsCloseup
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(DromeTheme.elevated))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(DromeTheme.accent.opacity(0.35), lineWidth: 1.5)
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: step.symbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(DromeTheme.accent)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                Text(step.caption)
                    .font(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            if onAdvance != nil {
                Text("Tap anywhere to continue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DromeTheme.muted)
            }
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { onAdvance?() }
        .onAppear { restartSwipeHint() }
        .onChange(of: step) { _, _ in restartSwipeHint() }
        .onChange(of: reduceMotion) { _, _ in restartSwipeHint() }
    }

    private var stepBadge: some View {
        Text("Now Playing · \(step.rawValue + 1) of \(OnboardingNowPlayingStep.allCases.count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(DromeTheme.muted)
    }

    // MARK: Art swipe

    private var artSwipeCloseup: some View {
        ZStack {
            HStack(spacing: 10) {
                MockArtTile(
                    colors: [Color(hex: "#264653"), Color(hex: "#2A9D8F")],
                    corner: 12,
                    symbol: "music.note")
                    .frame(width: 120, height: 120)
                    .offset(x: reduceMotion ? 0 : swipeHintOffset)

                MockArtTile(
                    colors: [Color(hex: "#E76F51"), Color(hex: "#264653")],
                    corner: 12,
                    symbol: "music.note")
                    .frame(width: 120, height: 120)
                    .opacity(0.9)
                    .offset(x: reduceMotion ? 8 : swipeHintOffset + 8)
            }
            .frame(width: 200, height: 120)
            .clipped()

            if reduceMotion {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("swipe")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.55), in: Capsule())
            } else {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .offset(x: swipeHintOffset * 0.5)
            }
        }
        .padding(.vertical, 16)
        .accessibilityLabel("Swipe album art left for next, right for previous")
    }

    private func restartSwipeHint() {
        swipeHintOffset = 0
        guard step == .artSwipe, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
            swipeHintOffset = -22
        }
    }

    // MARK: Shuffle — Off vs Smart (on)

    private var shuffleCloseup: some View {
        VStack(spacing: 14) {
            largeTransportRow(highlight: .shuffle)
            HStack(spacing: 16) {
                stateChip(
                    icon: "shuffle",
                    label: "Off",
                    detail: "In order",
                    on: false)
                stateChip(
                    icon: "shuffle",
                    label: "Smart",
                    detail: "Rating-weighted",
                    on: true,
                    badge: true)
                stateChip(
                    icon: "shuffle",
                    label: "Random",
                    detail: "Uniform",
                    on: true)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 14)
    }

    // MARK: Repeat — Off / All / One

    private var repeatCloseup: some View {
        VStack(spacing: 14) {
            largeTransportRow(highlight: .repeat)
            HStack(spacing: 16) {
                stateChip(icon: "repeat", label: "Off", detail: "No loop", on: false)
                stateChip(icon: "repeat", label: "List", detail: "Tap once", on: true)
                stateChip(icon: "repeat.1", label: "One", detail: "Tap twice", on: true)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 14)
    }

    // MARK: Keep Playing ∞

    private var keepPlayingCloseup: some View {
        VStack(spacing: 14) {
            largeBottomBar(highlight: .keepPlaying)
            HStack(spacing: 20) {
                stateChip(icon: "infinity", label: "Off", detail: "Queue ends", on: false)
                stateChip(icon: "infinity", label: "On", detail: "Adds similar", on: true)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 14)
    }

    // MARK: Queue

    private var queueCloseup: some View {
        VStack(spacing: 14) {
            largeBottomBar(highlight: .queue)
            stateChip(icon: "list.bullet", label: "Queue", detail: "Up next", on: true)
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 14)
    }

    // MARK: Lyrics

    private var lyricsCloseup: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                pickerChip("Song", selected: true)
                pickerChip("Lyrics", selected: false)
            }
            .padding(3)
            .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DromeTheme.accent, lineWidth: 2)
            }
            .padding(.horizontal, 28)

            Text("Also: swipe up on artwork")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DromeTheme.muted)
        }
        .padding(.vertical, 18)
    }

    private func pickerChip(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(selected ? .white : DromeTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DromeTheme.elevated)
                }
            }
    }

    // MARK: Large chrome rows

    private enum TransportHighlight { case shuffle, `repeat` }
    private enum BottomHighlight { case keepPlaying, queue }

    private func largeTransportRow(highlight: TransportHighlight) -> some View {
        HStack {
            largeIcon(
                "shuffle",
                tint: highlight == .shuffle ? DromeTheme.accent : Color.white.opacity(0.35),
                ring: highlight == .shuffle,
                badge: highlight == .shuffle)
            Spacer(minLength: 8)
            Image(systemName: "backward.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.3))
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.white.opacity(0.4))
            Image(systemName: "forward.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.3))
            Spacer(minLength: 8)
            largeIcon(
                highlight == .repeat ? "repeat" : "repeat",
                tint: highlight == .repeat ? DromeTheme.accent : Color.white.opacity(0.35),
                ring: highlight == .repeat)
        }
        .padding(.horizontal, 20)
    }

    private func largeBottomBar(highlight: BottomHighlight) -> some View {
        HStack {
            largeIcon("hifispeaker", tint: Color.white.opacity(0.35), ring: false)
            Spacer()
            largeIcon(
                "infinity",
                tint: highlight == .keepPlaying ? DromeTheme.accent : Color.white.opacity(0.35),
                ring: highlight == .keepPlaying)
            Spacer()
            largeIcon(
                "list.bullet",
                tint: highlight == .queue ? .white : Color.white.opacity(0.35),
                ring: highlight == .queue)
        }
        .padding(.horizontal, 28)
    }

    private func largeIcon(
        _ systemName: String,
        tint: Color,
        ring: Bool,
        badge: Bool = false
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 52, height: 52)
            .overlay(alignment: .topTrailing) {
                if badge {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DromeTheme.accent)
                        .offset(x: -4, y: 10)
                }
            }
            .background {
                if ring {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DromeTheme.accent.opacity(0.14))
                }
            }
            .overlay {
                if ring {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DromeTheme.accent, lineWidth: 2)
                }
            }
    }

    private func stateChip(
        icon: String,
        label: String,
        detail: String,
        on: Bool,
        badge: Bool = false
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on ? DromeTheme.accent : Color.white.opacity(0.4))
                .frame(width: 40, height: 40)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(DromeTheme.accent)
                            .offset(x: 2, y: 6)
                    }
                }
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(DromeTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

struct OnboardingPlaylistsMock: View {
    var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Library chrome with + for create.
            HStack {
                Image(systemName: "heart")
                    .font(.system(size: 12))
                    .foregroundStyle(DromeTheme.muted)
                    .frame(width: 20)
                Spacer()
                Text("Your Library")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                OnboardingSpotlight(
                    label: "New",
                    isActive: true,
                    reduceMotion: reduceMotion,
                    overlayCallout: true
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)

            // Playlist detail sheet with real Share Playlist action.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Road Trip")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .opacity(0.55)

                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 30, height: 3)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)

                menuRow("Add Songs", "plus")
                    .opacity(0.4)
                menuRow("Rename", "pencil")
                    .opacity(0.4)
                menuRow("Edit & Reorder", "arrow.up.arrow.down")
                    .opacity(0.4)

                OnboardingSpotlight(
                    label: "Share Playlist",
                    isActive: true,
                    reduceMotion: reduceMotion,
                    overlayCallout: true
                ) {
                    menuRow("Share Playlist", "square.and.arrow.up")
                }
                .padding(.horizontal, 4)

                menuRow("Make Public on Server", "person.2")
                    .opacity(0.4)
            }
            .background(DromeTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Spacer(minLength: 0)
        }
        .background(DromeTheme.background)
    }

    private func menuRow(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

struct OnboardingSettingsMock: View {
    var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Settings is reached from Home's avatar menu — not a tab.
            HStack {
                Spacer()
                OnboardingSpotlight(
                    label: "Avatar",
                    isActive: true,
                    reduceMotion: reduceMotion,
                    overlayCallout: true
                ) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)

            Text("Avatar → Settings")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DromeTheme.accent)
                .padding(.bottom, 6)

            Text("Settings")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("Playback")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DromeTheme.muted)
                    .padding(.horizontal, 4)

                OnboardingSpotlight(
                    label: "Keep Playing",
                    isActive: true,
                    reduceMotion: reduceMotion,
                    overlayCallout: true
                ) {
                    settingsRow(
                        "Keep playing (∞ adds songs when the queue ends)",
                        on: true)
                }

                settingsRow("Skip low-rated songs everywhere", on: false)
                    .opacity(0.4)
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
        .background(DromeTheme.background)
    }

    private func settingsRow(_ title: String, on: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Capsule()
                .fill(on ? DromeTheme.accent : DromeTheme.divider)
                .frame(width: 32, height: 18)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .padding(2)
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(DromeTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
