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
                        .fill(DromeTheme.accent.opacity(OnboardingTourChrome.highlightFillOpacity))
                }
            }
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(DromeTheme.accent, lineWidth: OnboardingTourChrome.highlightStroke)
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

/// Shared tour chrome — keep every page (including Now Playing tips) in sync.
enum OnboardingTourChrome {
    // Phone mock canvas
    static let mockWidth: CGFloat = 300
    static let mockHeight: CGFloat = 420
    static let mockCornerRadius: CGFloat = 28
    static let mockBorderOpacity: Double = 0.14
    static let mockBorderWidth: CGFloat = 1
    static let mockShadowRadius: CGFloat = 18
    static let mockShadowY: CGFloat = 10
    static let mockShadowOpacity: Double = 0.45

    // Highlight ring (spotlight)
    static let highlightStroke: CGFloat = 2
    static let highlightFillOpacity: Double = 0.12
    static let highlightCorner: CGFloat = 10

    // Page copy
    static let mockMaxWidth: CGFloat = 320
    static let mockMaxWidthAX: CGFloat = 280
    static let mockMaxHeight: CGFloat = 380
    static let mockMaxHeightAX: CGFloat = 240
    static let mockHorizontalPadding: CGFloat = 28
    static let mockBottomSpacing: CGFloat = 14
    static let mockBottomSpacingAX: CGFloat = 12
    static let titleBottomSpacing: CGFloat = 8
    static let titleBottomSpacingAX: CGFloat = 6
    static let captionHorizontalPadding: CGFloat = 28

    // Continue CTA
    static let continueCorner: CGFloat = 14
    static let continueVerticalPadding: CGFloat = 16

    // Transitions
    static let pageTransitionX: CGFloat = 18
    static let stepTransitionX: CGFloat = 14

    // Cover art in player mocks — matches NowPlayingView coverCard radius.
    static let coverCorner: CGFloat = 8
}

enum OnboardingMockDesign {
    /// Intrinsic canvas — mocks always lay out at this size, then scale to fit.
    static let width: CGFloat = OnboardingTourChrome.mockWidth
    static let height: CGFloat = OnboardingTourChrome.mockHeight
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
                        .clipShape(RoundedRectangle(cornerRadius: OnboardingTourChrome.mockCornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: OnboardingTourChrome.mockCornerRadius, style: .continuous)
                                .stroke(Color.white.opacity(OnboardingTourChrome.mockBorderOpacity), lineWidth: OnboardingTourChrome.mockBorderWidth)
                        }
                        .scaleEffect(scale)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .shadow(
                color: .black.opacity(OnboardingTourChrome.mockShadowOpacity),
                radius: OnboardingTourChrome.mockShadowRadius,
                y: OnboardingTourChrome.mockShadowY)
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
    case playlists

    var callout: String {
        switch self {
        case .library: return "Library"
        case .spotify: return "Spotify"
        case .podcasts: return "Podcasts"
        case .playlists: return "Playlists"
        }
    }
}

struct OnboardingSearchMock: View {
    var focus: OnboardingSearchFocus
    var reduceMotion: Bool
    var showAllCallouts: Bool = false

    private var selectedSource: OnboardingSearchFocus {
        switch focus {
        case .playlists: return .library
        default: return focus
        }
    }

    private let filterChips = ["All", "Songs", "Albums", "Artists", "Playlists"]

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
        case .library, .playlists: return "Artists, songs, albums, playlists…"
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

    /// Library-mode result filters — Playlists replaces the old Lyrics chip.
    private var filterChipRow: some View {
        Group {
            if showAllCallouts {
                VStack(spacing: 4) {
                    OnboardingCalloutLabel(text: "All · Songs · Albums · Artists · Playlists")
                        .frame(height: 20)
                    chips(highlightPlaylists: false)
                }
            } else {
                VStack(spacing: 4) {
                    ZStack {
                        if focus == .playlists {
                            OnboardingCalloutLabel(text: "Playlists")
                                .transition(.opacity)
                        }
                    }
                    .frame(height: 20)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: focus == .playlists)

                    chips(highlightPlaylists: focus == .playlists)
                        .transaction { $0.animation = nil }
                }
            }
        }
    }

    private func chips(highlightPlaylists: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(filterChips, id: \.self) { title in
                let isPlaylists = title == "Playlists"
                let selected = isPlaylists
                    ? (focus == .playlists || showAllCallouts)
                    : (title == "All" && focus != .playlists && !showAllCallouts)
                let ring = isPlaylists && highlightPlaylists
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
                corner: OnboardingTourChrome.coverCorner,
                symbol: "music.note")
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
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
                    Text("FLAC · 24-bit")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DromeTheme.accent.opacity(0.95))
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
                OnboardingScrubberMock(
                    fraction: 0.38,
                    dimmed: true,
                    reduceMotion: reduceMotion)
                    .padding(.horizontal, 16)
                HStack(spacing: 24) {
                    Image(systemName: "shuffle")
                        .foregroundStyle(.white.opacity(0.55))
                    Image(systemName: "backward.fill")
                        .foregroundStyle(.white.opacity(0.55))
                    // Match real Now Playing / NP lesson: white disc + black glyph.
                    ZStack {
                        Circle().fill(Color.white).frame(width: 28, height: 28)
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                    }
                    Image(systemName: "forward.fill")
                        .foregroundStyle(.white.opacity(0.55))
                    Image(systemName: "repeat")
                        .foregroundStyle(.white.opacity(0.55))
                }
                .font(.system(size: 13, weight: .semibold))
            }

            Spacer(minLength: 4)
        }
        .background(DromeTheme.background)
    }
}

/// Shared scrubber chrome — elapsed left, remaining (−m:ss) right, like NowPlayingView.
private struct OnboardingScrubberMock: View {
    var fraction: CGFloat = 0.42
    var dimmed: Bool = false
    var highlighted: Bool = false
    var reduceMotion: Bool = false

    var body: some View {
        let fill = min(max(fraction, 0.08), 0.92)
        return OnboardingSpotlightRing(
            isActive: highlighted,
            reduceMotion: reduceMotion,
            cornerRadius: 10
        ) {
            VStack(spacing: 5) {
                GeometryReader { geo in
                    let width = max(0, geo.size.width)
                    let thumbX = width * fill
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 4)
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(8, thumbX), height: 4)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 12, height: 12)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                            .offset(x: max(0, thumbX - 6))
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 16)

                HStack {
                    Text("1:24")
                        .frame(minWidth: 32, alignment: .leading)
                    Spacer()
                    Text("-2:11")
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.7))
            }
            .padding(.vertical, highlighted ? 4 : 0)
            .padding(.horizontal, highlighted ? 4 : 0)
        }
        .opacity(dimmed && !highlighted ? 0.5 : 1)
    }
}

/// Manual steps on the Now Playing controls lesson (Continue / swipe advances).
/// Order follows the real player: art → scrubber → transport → panes → bottom bar → ···.
enum OnboardingNowPlayingStep: Int, CaseIterable {
    case artSwipe
    case scrubber
    case shuffle
    case `repeat`
    case lyrics
    case addToPlaylist
    case queue
    case sleep
    case output
    case equalizer
    case share
    case more

    var title: String {
        switch self {
        case .artSwipe: return "Swipe the artwork"
        case .scrubber: return "Scrubber"
        case .shuffle: return "Shuffle"
        case .repeat: return "Repeat"
        case .lyrics: return "Song & Lyrics"
        case .addToPlaylist: return "Add to Playlist"
        case .queue: return "Queue"
        case .sleep: return "Sleep Timer"
        case .output: return "Output"
        case .equalizer: return "Equalizer"
        case .share: return "Share"
        case .more: return "More"
        }
    }

    /// Plain-language caption matching real PlayerEngine / NowPlayingView behavior.
    func caption(compact: Bool) -> String {
        switch self {
        case .artSwipe:
            return compact
                ? "Swipe art left for next, right for previous."
                : "Swipe album art left for the next song, right for the previous."
        case .scrubber:
            return compact
                ? "Elapsed left, time left (−) right. Drag to seek."
                : "Elapsed on the left, time remaining on the right. Drag the scrubber — it tracks the real song."
        case .shuffle:
            return compact
                ? "Off: order. Smart: ★ rated. Random: any."
                : "Off plays in list order. Smart favors higher-rated tracks. Random plays this list in random order."
        case .repeat:
            return compact
                ? "Once: list. Twice: one song."
                : "Tap once to repeat the list, twice for one song, again to turn off."
        case .lyrics:
            return compact
                ? "Song / Lyrics panes. Swipe up on art opens Lyrics."
                : "Switch panes for the player or synced lyrics. Swipe up on art also opens Lyrics."
        case .addToPlaylist:
            return compact
                ? "Save this song into one of your playlists."
                : "Add the playing song to a playlist without leaving Now Playing."
        case .queue:
            return compact
                ? "Opens upcoming tracks to reorder or clear."
                : "Opens the upcoming tracks so you can reorder or clear what’s next."
        case .sleep:
            return compact
                ? "Fade out after a set number of minutes."
                : "Set a sleep timer so playback fades out after the minutes you pick."
        case .output:
            return compact
                ? "AirPlay, Connect speakers, and phone output."
                : "Pick AirPlay, a Connect speaker, or this iPhone — same sheet as the speaker button."
        case .equalizer:
            return compact
                ? "Tune bass, mids, and treble while you listen."
                : "Open the equalizer to shape bass, mids, and treble without leaving the player."
        case .share:
            return compact
                ? "Share this track with the system share sheet."
                : "Share the playing track via Messages, Mail, or anything else on your share sheet."
        case .more:
            return compact
                ? "Instant Mix, Keep Playing, and station steering."
                : "··· opens Instant Mix, Keep Playing (autoplay), and station steering for what’s next."
        }
    }

    var accessibilityLabel: String {
        "Now Playing, step \(rawValue + 1) of \(Self.allCases.count). \(title). \(caption(compact: true))"
    }

    var symbolName: String {
        switch self {
        case .artSwipe: return "hand.draw"
        case .scrubber: return "slider.horizontal.3"
        case .shuffle: return "shuffle"
        case .repeat: return "repeat"
        case .lyrics: return "text.alignleft"
        case .addToPlaylist: return "text.badge.plus"
        case .queue: return "list.bullet"
        case .sleep: return "moon.zzz"
        case .output: return "hifispeaker.2.fill"
        case .equalizer: return "slider.vertical.3"
        case .share: return "square.and.arrow.up"
        case .more: return "ellipsis"
        }
    }
}

/// Now Playing player chrome inside the shared phone-frame mock.
/// Highlight moves per tip; layout stays fixed so height doesn’t jump.
struct OnboardingNowPlayingControlsMock: View {
    let step: OnboardingNowPlayingStep
    var reduceMotion: Bool
    /// Tour coordinate space name — cover frame is reported here so page swipes
    /// starting on the art tip don’t steal the drag.
    var tourCoordinateSpace: String = "onboardingTour"

    @State private var artDragX: CGFloat = 0
    @State private var artIndex: Int = 0
    @State private var swipeHintOffset: CGFloat = 0
    @State private var isAnimatingCover = false

    private let artPalettes: [[Color]] = [
        [Color(hex: "#264653"), Color(hex: "#2A9D8F")],
        [Color(hex: "#E76F51"), Color(hex: "#264653")],
        [Color(hex: "#1D3557"), Color(hex: "#457B9D")],
    ]

    private let coverSize: CGFloat = 102

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 34, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .opacity(0.5)

            songLyricsPicker
                .padding(.horizontal, 36)
                .padding(.bottom, 8)

            albumArt
                .padding(.bottom, 8)

            trackMeta
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            ratingRow
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            scrubber
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            transportRow
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            bottomBar
                .padding(.horizontal, 22)
                .padding(.bottom, 6)

            // Reserved chip slot — constant height across all tips (fits 3 rows).
            stateChipSlot
                .frame(height: 72)
                .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
        .background(DromeTheme.background)
        .onAppear { restartSwipeHint() }
        .onChange(of: step) { _, _ in
            stopCoverMotion()
            restartSwipeHint()
        }
        .onChange(of: reduceMotion) { _, _ in restartSwipeHint() }
    }

    /// Clears drag + hint immediately (cancels any in-flight repeatForever hint).
    private func stopCoverMotion() {
        isAnimatingCover = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            artDragX = 0
            swipeHintOffset = 0
        }
    }

    private var songLyricsPicker: some View {
        let active = step == .lyrics
        return OnboardingSpotlightRing(
            isActive: active,
            reduceMotion: reduceMotion,
            cornerRadius: 9
        ) {
            HStack(spacing: 0) {
                pickerChip("Song", selected: step != .lyrics)
                pickerChip("Lyrics", selected: active)
            }
            .padding(3)
            .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .opacity(active ? 1 : 0.55)
    }

    private func pickerChip(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? .white : DromeTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DromeTheme.elevated)
                }
            }
    }

    /// One square cover. Neighbour tiles only exist on the swipe tip (avoids bleed on other tips).
    private var albumArt: some View {
        let active = step == .artSwipe
        let hint = (active && !reduceMotion && !isAnimatingCover) ? swipeHintOffset : 0
        return ZStack {
            if active {
                // Underlay fills the ring during left-hint / drag so no dark gap shows.
                artTile(index: (artIndex + 1) % artPalettes.count)
                    .frame(width: coverSize, height: coverSize)

                artTile(index: artIndex)
                    .frame(width: coverSize, height: coverSize)
                    .offset(x: artDragX + hint)

                if artDragX > 0 {
                    artTile(index: (artIndex + artPalettes.count - 1) % artPalettes.count)
                        .frame(width: coverSize, height: coverSize)
                        .offset(x: artDragX - coverSize)
                }

                if reduceMotion {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("swipe")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .allowsHitTesting(false)
                } else if !isAnimatingCover {
                    Image(systemName: "hand.draw.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.45), in: Circle())
                        .offset(x: hint * 0.4)
                        .allowsHitTesting(false)
                }
            } else {
                artTile(index: artIndex)
                    .frame(width: coverSize, height: coverSize)
            }
        }
        .frame(width: coverSize, height: coverSize)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTourChrome.coverCorner, style: .continuous))
        .padding(active ? 4 : 0)
        .background {
            if active {
                RoundedRectangle(cornerRadius: OnboardingTourChrome.coverCorner + 4, style: .continuous)
                    .fill(DromeTheme.accent.opacity(OnboardingTourChrome.highlightFillOpacity))
            }
        }
        .overlay {
            if active {
                RoundedRectangle(cornerRadius: OnboardingTourChrome.coverCorner + 4, style: .continuous)
                    .stroke(DromeTheme.accent, lineWidth: OnboardingTourChrome.highlightStroke)
            }
        }
        .opacity(active || step == .lyrics ? 1 : (step == .scrubber ? 0.55 : 0.72))
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: OnboardingArtCoverFrameKey.self,
                    value: active
                        ? geo.frame(in: .named(tourCoordinateSpace))
                        : .null)
            }
        }
        // highPriority so this wins over the parent’s (non-priority) tour drag.
        .highPriorityGesture(artSwipeGesture)
        .accessibilityLabel("Album artwork. Swipe left or right to preview next or previous.")
    }

    private func artTile(index: Int) -> some View {
        MockArtTile(
            colors: artPalettes[index % artPalettes.count],
            corner: OnboardingTourChrome.coverCorner,
            symbol: "music.note")
    }

    /// Fake song-change only — never advances tour steps.
    private var artSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard step == .artSwipe, !isAnimatingCover else { return }
                guard abs(value.translation.width) > abs(value.translation.height) * 0.55 else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { artDragX = value.translation.width }
            }
            .onEnded { value in
                guard step == .artSwipe, !isAnimatingCover else {
                    withAnimation(.easeOut(duration: 0.2)) { artDragX = 0 }
                    return
                }
                let dx = value.translation.width
                let threshold = coverSize * 0.22
                if dx < -threshold {
                    completeCoverSwipe(goingNext: true)
                } else if dx > threshold {
                    completeCoverSwipe(goingNext: false)
                } else {
                    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                        artDragX = 0
                    }
                }
            }
    }

    private func completeCoverSwipe(goingNext: Bool) {
        isAnimatingCover = true
        let target = goingNext ? -coverSize : coverSize
        withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.28)) {
            artDragX = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.16 : 0.28)) {
            if goingNext {
                artIndex = (artIndex + 1) % artPalettes.count
            } else {
                artIndex = (artIndex + artPalettes.count - 1) % artPalettes.count
            }
            artDragX = 0
            isAnimatingCover = false
        }
    }

    private func restartSwipeHint() {
        stopCoverMotion()
        guard step == .artSwipe, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
            swipeHintOffset = -14
        }
    }

    private var trackMeta: some View {
        let moreActive = step == .more
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(artIndex == 0 ? "Midnight Drive" : (artIndex == 1 ? "Neon Harbor" : "Glass Roads"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(artIndex == 0 ? "Neon Harbor" : (artIndex == 1 ? "Glass Roads" : "Midnight Drive"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(1)
                Text("FLAC · 24-bit")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DromeTheme.accent.opacity(0.95))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            controlIcon(
                "ellipsis",
                tint: moreActive ? .white : Color.white.opacity(0.55),
                active: moreActive)
        }
        .opacity(moreActive || step == .scrubber || step == .lyrics ? 0.95 : 0.7)
    }

    private var ratingRow: some View {
        HStack(spacing: 5) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= 4 ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(star <= 4 ? RatingStyle.color(for: 4) : DromeTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .opacity(0.55)
        .accessibilityHidden(true)
    }

    private var scrubber: some View {
        OnboardingScrubberMock(
            fraction: 0.42,
            dimmed: step != .scrubber,
            highlighted: step == .scrubber,
            reduceMotion: reduceMotion)
    }

    private var transportRow: some View {
        HStack {
            controlIcon(
                "shuffle",
                tint: step == .shuffle ? DromeTheme.accent : Color.white.opacity(0.45),
                active: step == .shuffle,
                badge: step == .shuffle)
            Spacer(minLength: 4)
            Image(systemName: "backward.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            ZStack {
                Circle().fill(Color.white).frame(width: 48, height: 48)
                Image(systemName: "pause.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
            }
            Image(systemName: "forward.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            Spacer(minLength: 4)
            controlIcon(
                "repeat",
                tint: step == .repeat ? DromeTheme.accent : Color.white.opacity(0.45),
                active: step == .repeat)
        }
    }

    private var bottomBar: some View {
        // Match real Now Playing bottom bar: add · queue · sleep · output · EQ · share.
        HStack(spacing: 0) {
            bottomBarIcon("text.badge.plus", active: step == .addToPlaylist)
            Spacer(minLength: 0)
            bottomBarIcon("list.bullet", active: step == .queue)
            Spacer(minLength: 0)
            bottomBarIcon("moon.zzz", active: step == .sleep)
            Spacer(minLength: 0)
            bottomBarIcon("hifispeaker.2.fill", active: step == .output)
            Spacer(minLength: 0)
            bottomBarIcon("slider.vertical.3", active: step == .equalizer)
            Spacer(minLength: 0)
            bottomBarIcon("square.and.arrow.up", active: step == .share, shareOffset: true)
        }
        .frame(height: 36)
    }

    private func bottomBarIcon(
        _ systemName: String,
        active: Bool,
        shareOffset: Bool = false
    ) -> some View {
        controlIcon(
            systemName,
            tint: active ? .white : Color.white.opacity(0.4),
            active: active,
            yOffset: shareOffset ? -1.5 : 0)
    }

    private func controlIcon(
        _ systemName: String,
        tint: Color,
        active: Bool,
        badge: Bool = false,
        yOffset: CGFloat = 0
    ) -> some View {
        OnboardingSpotlightRing(
            isActive: active,
            reduceMotion: reduceMotion,
            cornerRadius: 8
        ) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .offset(y: yOffset)
                .frame(width: 32, height: 32)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(DromeTheme.accent)
                            .offset(x: -1, y: 6)
                    }
                }
        }
    }

    /// Always reserved; empty tips keep the same mock height.
    @ViewBuilder
    private var stateChipSlot: some View {
        switch step {
        case .shuffle:
            chipStack([
                ("Off", "Order", false),
                ("Smart", "★ rated", true),
                ("Random", "Any", true),
            ])
        case .repeat:
            chipStack([
                ("Off", "None", false),
                ("List", "Once", true),
                ("One", "Twice", true),
            ])
        case .more:
            chipStack([
                ("Instant Mix", "Radio", true),
                ("Keep Playing", "Autoplay", true),
                ("Steering", "Next up", true),
            ])
        case .sleep:
            chipStack([
                ("15m", "Short", false),
                ("30m", "Default", true),
                ("45m", "Long", false),
            ])
        case .equalizer:
            chipStack([
                ("Bass", "Low", true),
                ("Mids", "Mid", true),
                ("Treble", "High", true),
            ])
        default:
            Color.clear
        }
    }

    private func chipStack(_ items: [(String, String, Bool)]) -> some View {
        // Vertical so AX5 never mid-word truncates; same layout at default size.
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Text(item.0)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.1)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DromeTheme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(item.2 ? "On" : "Off")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.2 ? DromeTheme.accent : DromeTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
