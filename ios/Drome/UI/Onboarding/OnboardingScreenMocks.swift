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
    /// Welcome page uses dead space above the dots for a larger hero.
    static let mockMaxHeightHero: CGFloat = 420
    /// Accent page keeps the orb compact so swatches clear the Continue bar.
    static let mockMaxHeightAccent: CGFloat = 220
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

/// Deterministic, copyright-free cover art — vivid gradients + simple shapes.
struct MockArtTile: View {
    var index: Int = 0
    var corner: CGFloat = 8
    /// Legacy two-stop override (search placeholders, etc.).
    var colors: [Color]? = nil
    var symbol: String? = nil

    private var palette: [Color] {
        if let colors, !colors.isEmpty { return colors }
        return Self.palette(for: index)
    }

    var body: some View {
        let hues = palette
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: hues,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let seed = index & 7
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: w * 0.55, height: w * 0.55)
                            .offset(
                                x: seed % 2 == 0 ? w * 0.22 : -w * 0.18,
                                y: seed < 4 ? -h * 0.2 : h * 0.16)
                        RoundedRectangle(cornerRadius: corner * 0.6, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .frame(width: w * 0.42, height: h * 0.28)
                            .rotationEffect(.degrees(Double(seed) * 12 - 18))
                            .offset(x: -w * 0.16, y: h * 0.22)
                        if let symbol {
                            Image(systemName: symbol)
                                .font(.system(size: max(10, w * 0.22), weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))
                        } else {
                            // Soft glyph — not a flat ♪ on teal.
                            Capsule()
                                .fill(Color.white.opacity(0.28))
                                .frame(width: w * 0.12, height: h * 0.42)
                                .offset(y: h * 0.04)
                            Circle()
                                .fill(Color.white.opacity(0.35))
                                .frame(width: w * 0.2, height: w * 0.2)
                                .offset(x: -w * 0.06, y: h * 0.18)
                        }
                    }
                    .frame(width: w, height: h)
                }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            }
    }

    static func palette(for index: Int) -> [Color] {
        let palettes: [[Color]] = [
            [Color(hex: "#FF6B35"), Color(hex: "#F7C59F"), Color(hex: "#2EC4B6")],
            [Color(hex: "#7B2CBF"), Color(hex: "#E0AAFF"), Color(hex: "#3C096C")],
            [Color(hex: "#0077B6"), Color(hex: "#00B4D8"), Color(hex: "#90E0EF")],
            [Color(hex: "#E63946"), Color(hex: "#F4A261"), Color(hex: "#1D3557")],
            [Color(hex: "#2A9D8F"), Color(hex: "#E9C46A"), Color(hex: "#264653")],
            [Color(hex: "#FF8FAB"), Color(hex: "#FB6F92"), Color(hex: "#FFC2D1")],
            [Color(hex: "#80ED99"), Color(hex: "#57CC99"), Color(hex: "#22577A")],
            [Color(hex: "#F72585"), Color(hex: "#7209B7"), Color(hex: "#3A0CA3")],
            [Color(hex: "#FFB703"), Color(hex: "#FB8500"), Color(hex: "#023047")],
            [Color(hex: "#4CC9F0"), Color(hex: "#4361EE"), Color(hex: "#3A0CA3")],
        ]
        return palettes[abs(index) % palettes.count]
    }
}

// MARK: - Page mocks

struct OnboardingHomeMock: View {
    var reduceMotion: Bool
    var highlightVibe: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Match real Home: DROME wordmark + gear Settings (not an avatar).
            HStack(alignment: .center, spacing: 8) {
                Text("DROME")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(DromeTheme.accent)
                    .tracking(1.2)
                Spacer(minLength: 4)
                Image(systemName: "gearshape.circle.fill")
                    .font(.system(size: 18, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DromeTheme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

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
                        MockArtTile(index: index + 1, corner: 6)
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
            // Match real Library: star · Your Library · ≡/+ capsule.
            HStack(spacing: 8) {
                Image(systemName: "star")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(DromeTheme.muted)
                    .frame(width: 22)
                Spacer()
                Text("Your Library")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(DromeTheme.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(DromeTheme.elevated2, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .opacity(0.85)

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
                libraryRow("Downloaded", "arrow.down.circle.fill")
                libraryRow("Top Rated", "star.fill")
                libraryRow("Out of Rotation", "lock.fill")
                libraryRow("Hidden Playlists", "eye.slash")
            }
            .padding(.horizontal, 8)
            .opacity(0.55)

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
        let rows: [(title: String, subtitle: String, art: Int, round: Bool)] = [
            ("Neon Harbor", "Artist", 2, true),
            ("Midnight Drive", "Song · Glass Roads", 0, false),
            ("Coastline Mix", "Playlist · 42 songs", 5, false),
        ]
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    MockArtTile(
                        index: row.art,
                        corner: row.round ? 14 : 5)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(row.subtitle)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(DromeTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
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

            MockArtTile(index: 0, corner: OnboardingTourChrome.coverCorner)
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                .padding(.bottom, 10)
                .opacity(0.9)

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
/// Grouped into a short walk: navigate → playback → lyrics → tools → more.
enum OnboardingNowPlayingStep: Int, CaseIterable {
    case navigate
    case playback
    case lyrics
    case tools
    case more

    var title: String {
        switch self {
        case .navigate: return "Skip ahead with a swipe"
        case .playback: return "Scrub, shuffle, repeat"
        case .lyrics: return "Follow every word"
        case .tools: return "Queue, sleep, share & EQ"
        case .more: return "Keep the mix alive"
        }
    }

    /// Captions lead with the benefit — they do not repeat the title.
    func caption(compact: Bool) -> String {
        switch self {
        case .navigate:
            return compact
                ? "Swipe art left for next, right for previous."
                : "Flick album art left for the next track, right for the previous — no buttons required."
        case .playback:
            return compact
                ? "Drag to seek. Shuffle Off / Smart / Random. Repeat list or one song."
                : "Drag the scrubber to seek. Shuffle: Off, Smart (★ rated), or Random. Tap repeat for the list, twice for one song."
        case .lyrics:
            return compact
                ? "Song / Lyrics panes. Swipe up on art opens Lyrics."
                : "Flip between the player and synced lyrics — or swipe up on the artwork to open Lyrics."
        case .tools:
            return compact
                ? "Add, queue, sleep, speakers, EQ, and share from the bar."
                : "Save to a playlist, open the queue, set a sleep timer, pick speakers, tune EQ, or share — all from the bottom bar."
        case .more:
            return compact
                ? "··· opens Instant Mix, Keep Playing, and steering."
                : "The ··· menu opens Instant Mix, Keep Playing (autoplay), and station steering for what’s next."
        }
    }

    var accessibilityLabel: String {
        "Now Playing, step \(rawValue + 1) of \(Self.allCases.count). \(title). \(caption(compact: true))"
    }

    var symbolName: String {
        switch self {
        case .navigate: return "hand.draw"
        case .playback: return "slider.horizontal.3"
        case .lyrics: return "text.alignleft"
        case .tools: return "slider.vertical.3"
        case .more: return "ellipsis"
        }
    }

    /// Focus point inside the mock (0…1) used to zoom toward the highlighted region.
    var focusAnchor: UnitPoint {
        switch self {
        case .navigate: return UnitPoint(x: 0.5, y: 0.28)
        case .playback: return UnitPoint(x: 0.5, y: 0.62)
        case .lyrics: return UnitPoint(x: 0.5, y: 0.12)
        case .tools: return UnitPoint(x: 0.5, y: 0.78)
        case .more: return UnitPoint(x: 0.88, y: 0.42)
        }
    }

    var focusScale: CGFloat {
        switch self {
        case .navigate: return 1.12
        case .playback: return 1.18
        case .lyrics: return 1.2
        case .tools: return 1.22
        case .more: return 1.16
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

    private let coverSize: CGFloat = 102
    private let artCount = 3

    var body: some View {
        GeometryReader { geo in
            playerChrome
                .frame(width: OnboardingMockDesign.width, height: OnboardingMockDesign.height)
                // Zoom toward the highlighted region so in-mock text stays readable.
                .scaleEffect(reduceMotion ? 1 : step.focusScale, anchor: step.focusAnchor)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.28),
                    value: step)
        }
        .background(DromeTheme.background)
        .onAppear { restartSwipeHint() }
        .onChange(of: step) { _, _ in
            stopCoverMotion()
            restartSwipeHint()
        }
        .onChange(of: reduceMotion) { _, _ in restartSwipeHint() }
    }

    private var playerChrome: some View {
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
                .frame(height: 78)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Spacer(minLength: 0)
        }
        .background(DromeTheme.background)
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
                pickerChip("Song", selected: !active)
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
        let active = step == .navigate
        let hint = (active && !reduceMotion && !isAnimatingCover) ? swipeHintOffset : 0
        return ZStack {
            if active {
                // Underlay fills the ring during left-hint / drag so no dark gap shows.
                artTile(index: (artIndex + 1) % artCount)
                    .frame(width: coverSize, height: coverSize)

                artTile(index: artIndex)
                    .frame(width: coverSize, height: coverSize)
                    .offset(x: artDragX + hint)

                if artDragX > 0 {
                    artTile(index: (artIndex + artCount - 1) % artCount)
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
        .opacity(active || step == .lyrics ? 1 : (step == .playback ? 0.55 : 0.72))
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
        MockArtTile(index: index, corner: OnboardingTourChrome.coverCorner)
    }

    /// Fake song-change only — never advances tour steps.
    private var artSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard step == .navigate, !isAnimatingCover else { return }
                guard abs(value.translation.width) > abs(value.translation.height) * 0.55 else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { artDragX = value.translation.width }
            }
            .onEnded { value in
                guard step == .navigate, !isAnimatingCover else {
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
                artIndex = (artIndex + 1) % artCount
            } else {
                artIndex = (artIndex + artCount - 1) % artCount
            }
            artDragX = 0
            isAnimatingCover = false
        }
    }

    private func restartSwipeHint() {
        stopCoverMotion()
        guard step == .navigate, !reduceMotion else { return }
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
        .opacity(moreActive || step == .playback || step == .lyrics ? 0.95 : 0.7)
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
            dimmed: step != .playback,
            highlighted: step == .playback,
            reduceMotion: reduceMotion)
    }

    private var transportRow: some View {
        let active = step == .playback
        return HStack {
            controlIcon(
                "shuffle",
                tint: active ? DromeTheme.accent : Color.white.opacity(0.45),
                active: active,
                badge: active)
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
                tint: active ? DromeTheme.accent : Color.white.opacity(0.45),
                active: active)
        }
    }

    private var bottomBar: some View {
        // Match real Now Playing bottom bar: add · queue · sleep · output · EQ · share.
        let active = step == .tools
        return OnboardingSpotlightRing(
            isActive: active,
            reduceMotion: reduceMotion,
            cornerRadius: 10
        ) {
            HStack(spacing: 0) {
                bottomBarGlyph("text.badge.plus", lit: active)
                Spacer(minLength: 0)
                bottomBarGlyph("list.bullet", lit: active)
                Spacer(minLength: 0)
                bottomBarGlyph("moon.zzz", lit: active)
                Spacer(minLength: 0)
                bottomBarGlyph("hifispeaker.2.fill", lit: active)
                Spacer(minLength: 0)
                bottomBarGlyph("slider.vertical.3", lit: active)
                Spacer(minLength: 0)
                bottomBarGlyph("square.and.arrow.up", lit: active, yOffset: -1.5)
            }
            .frame(height: 36)
            .padding(.horizontal, active ? 4 : 0)
        }
    }

    /// Glyph only — the tools tip rings the whole bar, not each icon.
    private func bottomBarGlyph(
        _ systemName: String,
        lit: Bool,
        yOffset: CGFloat = 0
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(lit ? Color.white : Color.white.opacity(0.4))
            .offset(y: yOffset)
            .frame(width: 32, height: 32)
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
        case .playback:
            // Choose-one modes — mode name + single checkmark on the selected option.
            modeChipStack([
                ("Off", "List order", false),
                ("Smart", "★ rated first", true),
                ("Random", "Any order", false),
            ])
        case .tools:
            modeChipStack([
                ("Flat", "As recorded", false),
                ("Bass Boost", "More low end", true),
                ("Vocal", "Clear mids", false),
            ])
        case .more:
            actionChipStack([
                ("Instant Mix", "Radio from this track"),
                ("Keep Playing", "Autoplay when the queue ends"),
                ("Steering", "Nudge what’s next"),
            ])
        default:
            Color.clear
        }
    }

    /// Mutually exclusive modes — one checkmark, never On/On/On.
    private func modeChipStack(_ items: [(String, String, Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
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
                    if item.2 {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DromeTheme.accent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.bottom, 4)
    }

    private func actionChipStack(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
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
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.bottom, 4)
    }
}

struct OnboardingPlaylistsMock: View {
    var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Match real Library: star · title · ≡/+ capsule with New spotlight.
            HStack(spacing: 8) {
                Image(systemName: "star")
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
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(DromeTheme.elevated2, in: Capsule())
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
            // Settings opens from Home’s gear — not an avatar.
            HStack {
                Text("DROME")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(DromeTheme.accent)
                    .tracking(1.0)
                Spacer()
                OnboardingSpotlight(
                    label: "Settings",
                    isActive: true,
                    reduceMotion: reduceMotion,
                    overlayCallout: true
                ) {
                    Image(systemName: "gearshape.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DromeTheme.accent)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)

            Text("Home → Settings")
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
