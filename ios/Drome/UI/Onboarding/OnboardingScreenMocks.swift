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

    private let filterChips = ["All", "Songs", "Albums", "Artists", "Lyrics"]

    var body: some View {
        VStack(spacing: 0) {
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

            sourceSegments
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            if selectedSource == .library {
                filterChipRow
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

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

    private var sourceSegments: some View {
        Group {
            if showAllCallouts {
                VStack(spacing: 4) {
                    OnboardingCalloutLabel(text: "Library · Spotify · Podcasts")
                        .frame(height: 20)
                    segmentsRow(ringMode: nil)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach([OnboardingSearchFocus.library, .spotify, .podcasts], id: \.rawValue) { mode in
                        segmentColumn(mode)
                    }
                }
                .padding(2)
                .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func segmentsRow(ringMode: OnboardingSearchFocus?) -> some View {
        HStack(spacing: 0) {
            ForEach([OnboardingSearchFocus.library, .spotify, .podcasts], id: \.rawValue) { mode in
                segmentChip(mode, ringActive: ringMode == mode)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(2)
        .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(height: 32)
    }

    private func segmentColumn(_ mode: OnboardingSearchFocus) -> some View {
        let title = mode.callout
        let showCallout = focus == mode
        return VStack(spacing: 4) {
            ZStack {
                if showCallout {
                    OnboardingCalloutLabel(text: title)
                        .transition(.opacity)
                }
            }
            .frame(height: 20)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: showCallout)

            segmentChip(mode, ringActive: focus == mode)
                .frame(height: 32)
                .transaction { $0.animation = nil }
        }
        .frame(maxWidth: .infinity)
    }

    private func segmentChip(_ mode: OnboardingSearchFocus, ringActive: Bool) -> some View {
        let selected = selectedSource == mode
        return OnboardingSpotlightRing(
            isActive: ringActive,
            reduceMotion: reduceMotion,
            cornerRadius: 6
        ) {
            Text(mode.callout)
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
    }

    /// Library-mode result filters — Lyrics replaces the old quote toggle.
    private var filterChipRow: some View {
        Group {
            if showAllCallouts {
                VStack(spacing: 4) {
                    OnboardingCalloutLabel(text: "All · Songs · Albums · Artists · Lyrics")
                        .frame(height: 20)
                    chips(highlightLyrics: false)
                }
            } else {
                VStack(spacing: 4) {
                    ZStack {
                        if focus == .lyrics {
                            OnboardingCalloutLabel(text: "Lyrics")
                                .transition(.opacity)
                        }
                    }
                    .frame(height: 20)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: focus == .lyrics)

                    chips(highlightLyrics: focus == .lyrics)
                        .transaction { $0.animation = nil }
                }
            }
        }
    }

    private func chips(highlightLyrics: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(filterChips, id: \.self) { title in
                let isLyrics = title == "Lyrics"
                let selected = isLyrics ? (focus == .lyrics || showAllCallouts) : (title == "All" && focus != .lyrics && !showAllCallouts)
                let ring = isLyrics && highlightLyrics
                OnboardingSpotlightRing(
                    isActive: ring,
                    reduceMotion: reduceMotion,
                    cornerRadius: 10
                ) {
                    Text(title)
                        .font(.system(size: 9, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            selected ? DromeTheme.accent : DromeTheme.elevated2,
                            in: Capsule())
                }
            }
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
                    ZStack {
                        Circle().fill(Color.white).frame(width: 26, height: 26)
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                    }
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
    func caption(compact: Bool) -> String {
        switch self {
        case .artSwipe:
            return compact
                ? "Swipe art left for next, right for previous."
                : "Swipe album art left for the next song, right for the previous."
        case .shuffle:
            return compact
                ? "Off: in order. Smart: higher-rated. Random: any order."
                : "Shuffle: Off plays in list order. Smart favors higher-rated tracks. Random plays this list in random order."
        case .repeat:
            return compact
                ? "Tap once for the list, twice for one song."
                : "Repeat: tap once to repeat the list, twice for one song, again to turn off."
        case .keepPlaying:
            return compact
                ? "On: similar songs when the queue ends."
                : "∞ Keep Playing: when your queue ends, Drome keeps playing similar songs."
        case .queue:
            return compact
                ? "Opens upcoming tracks to reorder or clear."
                : "Queue: opens the upcoming tracks so you can reorder or clear what’s next."
        case .lyrics:
            return compact
                ? "Song / Lyrics panes. Swipe up on art opens Lyrics."
                : "Song / Lyrics: switch panes for the player or synced lyrics. Swipe up on art also opens Lyrics."
        }
    }

    var accessibilityLabel: String {
        "Now Playing, step \(rawValue + 1) of \(Self.allCases.count). \(title). \(caption(compact: true))"
    }

    var symbolName: String {
        switch self {
        case .artSwipe: return "hand.draw"
        case .shuffle: return "shuffle"
        case .repeat: return "repeat"
        case .keepPlaying: return "infinity"
        case .queue: return "list.bullet"
        case .lyrics: return "text.alignleft"
        }
    }
}

/// One fixed Now Playing mock; each step only changes the highlight + caption.
struct OnboardingNowPlayingLessonView: View {
    let step: OnboardingNowPlayingStep
    var stepDirection: Int = 1
    var reduceMotion: Bool
    var accessibilityLayout: Bool
    var onAdvance: (() -> Void)? = nil

    @State private var artDragX: CGFloat = 0
    @State private var artIndex: Int = 0
    @State private var swipeHintOffset: CGFloat = 0

    private let artPalettes: [[Color]] = [
        [Color(hex: "#264653"), Color(hex: "#2A9D8F")],
        [Color(hex: "#E76F51"), Color(hex: "#264653")],
        [Color(hex: "#1D3557"), Color(hex: "#457B9D")],
    ]

    var body: some View {
        VStack(spacing: accessibilityLayout ? 10 : 14) {
            // Fixed title card — stays for all 6 steps.
            HStack(spacing: 10) {
                Image(systemName: "play.square.fill")
                    .font(.system(size: accessibilityLayout ? 18 : 16, weight: .semibold))
                    .foregroundStyle(DromeTheme.accent)
                Text("Now Playing")
                    .font(accessibilityLayout ? .headline.weight(.bold) : .subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)

            playerMock
                .frame(maxWidth: .infinity)
                .padding(.vertical, accessibilityLayout ? 6 : 10)
                .padding(.horizontal, accessibilityLayout ? 6 : 10)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(DromeTheme.elevated))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(DromeTheme.accent.opacity(0.28), lineWidth: 1.5)
                }

            // Step name + caption slide a few points (or crossfade with Reduce Motion).
            stepCopy
                .id(step)
                .transition(stepTransition)
                .contentShape(Rectangle())
                .onTapGesture { onAdvance?() }

            if showsStateChips {
                stateChips
                    .padding(.top, 2)
            }
        }
        .onAppear { restartSwipeHint() }
        .onChange(of: step) { _, _ in
            artDragX = 0
            restartSwipeHint()
        }
        .onChange(of: reduceMotion) { _, _ in restartSwipeHint() }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        let x = CGFloat(14 * stepDirection)
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: x)),
            removal: .opacity.combined(with: .offset(x: -x)))
    }

    private var stepCopy: some View {
        VStack(spacing: accessibilityLayout ? 6 : 8) {
            Text(step.title)
                .font(accessibilityLayout ? .title3.weight(.bold) : .title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: step.symbolName)
                    .font(.system(size: accessibilityLayout ? 22 : 20, weight: .semibold))
                    .foregroundStyle(DromeTheme.accent)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(step.caption(compact: accessibilityLayout))
                    .font(accessibilityLayout ? .subheadline : .body)
                    .foregroundStyle(DromeTheme.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Single player mock

    private var playerMock: some View {
        VStack(spacing: accessibilityLayout ? 8 : 10) {
            songLyricsPicker
            albumArt
            trackMeta
            progressBar
            transportRow
            bottomBar
        }
    }

    private var songLyricsPicker: some View {
        let active = step == .lyrics
        return HStack(spacing: 0) {
            pickerChip("Song", selected: step != .lyrics)
            pickerChip("Lyrics", selected: active)
        }
        .padding(3)
        .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            if active {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(DromeTheme.accent, lineWidth: 2)
            }
        }
        .padding(.horizontal, accessibilityLayout ? 8 : 28)
        .opacity(active ? 1 : 0.55)
    }

    private func pickerChip(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: accessibilityLayout ? 12 : 13, weight: .semibold))
            .foregroundStyle(selected ? .white : DromeTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, accessibilityLayout ? 7 : 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DromeTheme.elevated)
                }
            }
    }

    private var albumArt: some View {
        let active = step == .artSwipe
        let size: CGFloat = accessibilityLayout ? 120 : 148
        return ZStack {
            HStack(spacing: 12) {
                artTile(index: artIndex)
                    .frame(width: size, height: size)
                    .offset(x: artDragX + (reduceMotion || !active ? 0 : swipeHintOffset))
                artTile(index: (artIndex + 1) % artPalettes.count)
                    .frame(width: size, height: size)
                    .offset(x: artDragX + (reduceMotion || !active ? 10 : swipeHintOffset + 10))
            }
            .frame(width: size + 8, height: size)
            .clipped()

            if active, reduceMotion {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("swipe")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.55), in: Capsule())
            } else if active {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .offset(x: swipeHintOffset * 0.45)
            }
        }
        .padding(active ? 4 : 0)
        .background {
            if active {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DromeTheme.accent.opacity(0.12))
            }
        }
        .overlay {
            if active {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DromeTheme.accent, lineWidth: 2)
            }
        }
        .opacity(active || step == .lyrics ? 1 : 0.7)
        .highPriorityGesture(artSwipeGesture(artWidth: size))
        .accessibilityLabel("Album artwork. Swipe left or right to preview next or previous.")
    }

    private func artTile(index: Int) -> some View {
        let colors = artPalettes[index % artPalettes.count]
        return MockArtTile(colors: colors, corner: 12, symbol: "music.note")
    }

    /// Fake song change only — never advances the tour page/step.
    private func artSwipeGesture(artWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard step == .artSwipe else { return }
                guard abs(value.translation.width) > abs(value.translation.height) * 0.7 else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { artDragX = value.translation.width }
            }
            .onEnded { value in
                guard step == .artSwipe else {
                    withAnimation(.easeOut(duration: 0.2)) { artDragX = 0 }
                    return
                }
                let dx = value.translation.width
                let threshold = min(70, artWidth * 0.28)
                if dx < -threshold {
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.28)) {
                        artDragX = -artWidth * 0.85
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.16 : 0.28)) {
                        artIndex = (artIndex + 1) % artPalettes.count
                        artDragX = artWidth * 0.35
                        withAnimation(.easeOut(duration: 0.22)) { artDragX = 0 }
                    }
                } else if dx > threshold {
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.28)) {
                        artDragX = artWidth * 0.85
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.16 : 0.28)) {
                        artIndex = (artIndex + artPalettes.count - 1) % artPalettes.count
                        artDragX = -artWidth * 0.35
                        withAnimation(.easeOut(duration: 0.22)) { artDragX = 0 }
                    }
                } else {
                    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                        artDragX = 0
                    }
                }
            }
    }

    private func restartSwipeHint() {
        swipeHintOffset = 0
        guard step == .artSwipe, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
            swipeHintOffset = -18
        }
    }

    private var trackMeta: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(artIndex == 0 ? "Midnight Drive" : (artIndex == 1 ? "Neon Harbor" : "Glass Roads"))
                .font(.system(size: accessibilityLayout ? 14 : 15, weight: .bold))
                .foregroundStyle(.white)
            Text(artIndex == 0 ? "Neon Harbor" : (artIndex == 1 ? "Glass Roads" : "Midnight Drive"))
                .font(.system(size: accessibilityLayout ? 11 : 12))
                .foregroundStyle(Color.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, accessibilityLayout ? 8 : 16)
        .opacity(0.85)
    }

    private var progressBar: some View {
        Capsule()
            .fill(Color.white.opacity(0.18))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.white)
                    .frame(width: 64, height: 3)
            }
            .padding(.horizontal, accessibilityLayout ? 8 : 16)
            .opacity(0.55)
    }

    private var transportRow: some View {
        HStack {
            controlIcon(
                "shuffle",
                tint: step == .shuffle ? DromeTheme.accent : Color.white.opacity(0.45),
                active: step == .shuffle,
                badge: step == .shuffle)
            Spacer(minLength: 6)
            Image(systemName: "backward.fill")
                .font(.system(size: accessibilityLayout ? 16 : 18, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.35))
            // Real Now Playing: white filled disc + black glyph.
            ZStack {
                Circle().fill(Color.white).frame(width: accessibilityLayout ? 44 : 52, height: accessibilityLayout ? 44 : 52)
                Image(systemName: "pause.fill")
                    .font(.system(size: accessibilityLayout ? 14 : 16, weight: .bold))
                    .foregroundStyle(.black)
            }
            Image(systemName: "forward.fill")
                .font(.system(size: accessibilityLayout ? 16 : 18, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.35))
            Spacer(minLength: 6)
            controlIcon(
                step == .repeat ? "repeat" : "repeat",
                tint: step == .repeat ? DromeTheme.accent : Color.white.opacity(0.45),
                active: step == .repeat)
        }
        .padding(.horizontal, accessibilityLayout ? 8 : 14)
    }

    private var bottomBar: some View {
        HStack {
            controlIcon("hifispeaker", tint: Color.white.opacity(0.35), active: false)
            Spacer()
            controlIcon(
                "infinity",
                tint: step == .keepPlaying ? DromeTheme.accent : Color.white.opacity(0.45),
                active: step == .keepPlaying)
            Spacer()
            controlIcon(
                "list.bullet",
                tint: step == .queue ? .white : Color.white.opacity(0.45),
                active: step == .queue)
        }
        .padding(.horizontal, accessibilityLayout ? 12 : 22)
        .padding(.bottom, 2)
    }

    private func controlIcon(
        _ systemName: String,
        tint: Color,
        active: Bool,
        badge: Bool = false
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: accessibilityLayout ? 16 : 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: accessibilityLayout ? 36 : 40, height: accessibilityLayout ? 36 : 40)
            .overlay(alignment: .topTrailing) {
                if badge {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(DromeTheme.accent)
                        .offset(x: -2, y: 8)
                }
            }
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DromeTheme.accent.opacity(0.14))
                }
            }
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DromeTheme.accent, lineWidth: 2)
                }
            }
    }

    // MARK: On / off chips

    private var showsStateChips: Bool {
        switch step {
        case .shuffle, .repeat, .keepPlaying: return true
        default: return false
        }
    }

    @ViewBuilder
    private var stateChips: some View {
        let chips: [(String, String, String, Bool, Bool)] = {
            switch step {
            case .shuffle:
                return [
                    ("shuffle", "Off", "In order", false, false),
                    ("shuffle", "Smart", "★ weighted", true, true),
                    ("shuffle", "Random", "Any order", true, false),
                ]
            case .repeat:
                return [
                    ("repeat", "Off", "No loop", false, false),
                    ("repeat", "List", "Once", true, false),
                    ("repeat.1", "One", "Twice", true, false),
                ]
            case .keepPlaying:
                return [
                    ("infinity", "Off", "Ends", false, false),
                    ("infinity", "On", "Similar", true, false),
                ]
            default:
                return []
            }
        }()

        Group {
            if accessibilityLayout {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        stateChipRow(icon: chip.0, label: chip.1, detail: chip.2, on: chip.3, badge: chip.4)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        stateChipColumn(icon: chip.0, label: chip.1, detail: chip.2, on: chip.3, badge: chip.4)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func stateChipColumn(
        icon: String, label: String, detail: String, on: Bool, badge: Bool
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(on ? DromeTheme.accent : Color.white.opacity(0.4))
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(DromeTheme.accent)
                            .offset(x: 6, y: -2)
                    }
                }
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }

    private func stateChipRow(
        icon: String, label: String, detail: String, on: Bool, badge: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(on ? DromeTheme.accent : Color.white.opacity(0.4))
                .frame(width: 24)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(DromeTheme.accent)
                            .offset(x: 4, y: -2)
                    }
                }
            Text(label)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("·")
                .foregroundStyle(DromeTheme.muted)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text(on ? "On" : "Off")
                .font(.caption.weight(.semibold))
                .foregroundStyle(on ? DromeTheme.accent : DromeTheme.muted)
        }
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
