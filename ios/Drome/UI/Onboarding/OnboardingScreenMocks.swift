import SwiftUI

// MARK: - Spotlight chrome

/// Pulsing accent ring + short callout for a control inside a screen mock.
struct OnboardingSpotlight<Content: View>: View {
    let label: String
    let isActive: Bool
    let reduceMotion: Bool
    @ViewBuilder var content: () -> Content

    @State private var pulse = false

    var body: some View {
        // Label takes layout space (not a negative offset) so phone-frame
        // clipShape won't crop the callout.
        VStack(spacing: 4) {
            if isActive {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DromeTheme.accent, in: Capsule())
                    .allowsHitTesting(false)
            }

            content()
                .padding(3)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(DromeTheme.accent.opacity(0.12))
                    }
                }
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(DromeTheme.accent, lineWidth: 2)
                            .scaleEffect(pulse && !reduceMotion ? 1.045 : 1)
                            .opacity(pulse && !reduceMotion ? 0.55 : 1)
                    }
                }
        }
        .zIndex(isActive ? 2 : 0)
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

struct OnboardingPhoneFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(DromeTheme.background)
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            }
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
                VStack(spacing: 3) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: .semibold))
                    Text(tab.title)
                        .font(.system(size: 7, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(index == selected ? DromeTheme.accent : DromeTheme.muted)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 5)
        .background(DromeTheme.elevated)
        .overlay(alignment: .top) {
            Rectangle().fill(DromeTheme.divider).frame(height: 0.5)
        }
        .opacity(dimmed && !highlightAll ? 0.4 : 1)

        if highlightAll {
            OnboardingSpotlight(label: "Tabs", isActive: true, reduceMotion: reduceMotion) {
                bar
            }
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
                    .font(.caption.weight(.semibold))
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
            HStack {
                Text("Home")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(DromeTheme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .opacity(0.55)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    OnboardingSpotlight(label: "Vibe Tuner", isActive: highlightVibe, reduceMotion: reduceMotion) {
                        vibeCard
                    }
                    .padding(.horizontal, 10)

                    dailyMixes
                        .opacity(highlightVibe ? 0.42 : 1)
                        .padding(.horizontal, 10)
                }
                .padding(.bottom, 8)
            }
            .scrollDisabled(true)

            OnboardingMockTabBar(selected: 0, dimmed: highlightVibe)
        }
        .background(DromeTheme.background)
    }

    private var vibeCard: some View {
        let vibe = MoodVibe.feelGood
        return VStack(alignment: .leading, spacing: 8) {
            Text("VIBE TUNER")
                .font(.system(size: 8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(vibe.ink.opacity(0.75))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vibe.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(vibe.blurb)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                Text("Play")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(vibe.ink, in: Capsule())
            }
            HStack(spacing: 4) {
                ForEach(MoodVibe.spectrum.prefix(7), id: \.id) { item in
                    Circle()
                        .fill(item == vibe ? vibe.ink : Color.white.opacity(0.22))
                        .frame(width: item == vibe ? 10 : 6, height: item == vibe ? 10 : 6)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(vibe.wash.opacity(0.92))
        }
    }

    private var dailyMixes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily Mixes")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        MockArtTile(
                            colors: index == 0
                                ? [Color(hex: "#2A9D8F"), Color(hex: "#1D3557")]
                                : index == 1
                                    ? [Color(hex: "#E76F51"), Color(hex: "#264653")]
                                    : [Color(hex: "#9B5DE5"), Color(hex: "#1D3557")],
                            corner: 6)
                            .frame(width: 64, height: 64)
                        Text("Daily Mix \(index + 1)")
                            .font(.system(size: 9, weight: .semibold))
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Your Library")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DromeTheme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .opacity(0.45)

            HStack(spacing: 10) {
                ForEach(["Playlists", "Artists", "Albums"], id: \.self) { title in
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(title == "Playlists" ? .white : DromeTheme.muted)
                        .padding(.bottom, 4)
                        .overlay(alignment: .bottom) {
                            if title == "Playlists" {
                                Capsule().fill(DromeTheme.accent).frame(height: 2)
                            }
                        }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .opacity(0.45)

            VStack(spacing: 0) {
                libraryRow("Create playlist", "plus.circle.fill", accent: true)
                libraryRow("Downloaded", "arrow.down.circle.fill")
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
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(accent ? DromeTheme.accent : DromeTheme.muted)
                .frame(width: 18)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent ? DromeTheme.accent : .white)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(DromeTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.bottom, 4)
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
    /// When Reduce Motion is on, show every mode callout at once.
    var showAllCallouts: Bool = false

    private var selectedSource: OnboardingSearchFocus {
        switch focus {
        case .lyrics: return .library
        default: return focus
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Search")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .opacity(0.55)

            Group {
                if showAllCallouts {
                    OnboardingSpotlight(
                        label: "Library · Spotify · Podcasts · Lyrics",
                        isActive: true,
                        reduceMotion: true
                    ) {
                        HStack(spacing: 8) {
                            sourceSegments(spotlight: false)
                            lyricsChip(spotlight: false)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        sourceSegments(spotlight: true)
                        if selectedSource == .library {
                            lyricsChip(spotlight: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            resultsPlaceholder
                .opacity(0.42)
                .padding(.horizontal, 12)

            Spacer(minLength: 0)

            OnboardingMockTabBar(selected: 1, dimmed: true)
        }
        .background(DromeTheme.background)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
            Text(prompt)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var prompt: String {
        switch selectedSource {
        case .library, .lyrics: return "Artists, songs, albums…"
        case .spotify: return "Search Spotify tracks, albums…"
        case .podcasts: return "Search podcasts or paste feed URL…"
        }
    }

    private func sourceSegments(spotlight: Bool) -> some View {
        HStack(spacing: 0) {
            segment(.library, title: "Library", spotlight: spotlight)
            segment(.spotify, title: "Spotify", spotlight: spotlight)
            segment(.podcasts, title: "Podcasts", spotlight: spotlight)
        }
        .padding(2)
        .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func segment(_ mode: OnboardingSearchFocus, title: String, spotlight: Bool) -> some View {
        let selected = selectedSource == mode
        let chip = Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(selected ? .white : DromeTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DromeTheme.elevated)
                }
            }

        if spotlight {
            OnboardingSpotlight(
                label: title,
                isActive: focus == mode,
                reduceMotion: reduceMotion
            ) { chip }
        } else {
            chip
        }
    }

    @ViewBuilder
    private func lyricsChip(spotlight: Bool) -> some View {
        let chip = Image(systemName: "text.quote")
            .symbolVariant(focus == .lyrics || showAllCallouts ? .fill : .none)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(focus == .lyrics || showAllCallouts ? DromeTheme.accent : Color.white.opacity(0.7))
            .frame(width: 28, height: 28)
            .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

        if spotlight {
            OnboardingSpotlight(
                label: "Lyrics",
                isActive: focus == .lyrics,
                reduceMotion: reduceMotion
            ) { chip }
        } else {
            chip
        }
    }

    private var resultsPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 8) {
                    MockArtTile(
                        colors: [DromeTheme.elevated2, DromeTheme.elevated],
                        corner: index == 0 ? 16 : 6,
                        symbol: index == 0 ? "person.crop.circle" : "music.note")
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 90 - CGFloat(index * 12), height: 7)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 60, height: 6)
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
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .opacity(0.5)

            MockArtTile(
                colors: [Color(hex: "#264653"), Color(hex: "#2A9D8F")],
                corner: 12,
                symbol: "music.note")
                .frame(width: 140, height: 140)
                .padding(.bottom, 14)
                .opacity(0.45)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Midnight Drive")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Neon Harbor")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .opacity(0.45)

            OnboardingSpotlight(label: "Stars", isActive: true, reduceMotion: reduceMotion) {
                HStack(spacing: 5) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= 2 ? "star.fill" : "star")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(star <= 2 ? RatingStyle.color(for: 2) : DromeTheme.muted)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            Text("1–2★ → Out of Rotation")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DromeTheme.accent)
                .padding(.bottom, 10)

            // Scrubber + transport (decorative).
            VStack(spacing: 10) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.white)
                            .frame(width: 54, height: 3)
                    }
                    .padding(.horizontal, 18)
                HStack(spacing: 28) {
                    Image(systemName: "shuffle")
                    Image(systemName: "backward.fill")
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 28))
                    Image(systemName: "forward.fill")
                    Image(systemName: "repeat")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            }
            .opacity(0.4)

            Spacer(minLength: 8)
        }
        .background(DromeTheme.background)
    }
}

struct OnboardingPlaylistsMock: View {
    var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "heart")
                    .foregroundStyle(DromeTheme.muted)
                Spacer()
                Text("Your Library")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                OnboardingSpotlight(label: "New", isActive: true, reduceMotion: reduceMotion) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                row("Create playlist", "plus.circle.fill", accent: true)
                row("Top Rated", "star.fill")
                row("Road Trip", "music.note.list")
            }
            .padding(.horizontal, 8)
            .opacity(0.4)

            Spacer(minLength: 6)

            // Track ··· menu sheet mock with Share highlighted.
            VStack(alignment: .leading, spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 32, height: 3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                menuRow("Add to Playlist", "text.badge.plus")
                OnboardingSpotlight(label: "Share", isActive: true, reduceMotion: reduceMotion) {
                    menuRow("Share", "square.and.arrow.up")
                }
                .padding(.horizontal, 6)
                menuRow("Download", "arrow.down.circle")
            }
            .background(DromeTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(DromeTheme.background)
    }

    private func row(_ title: String, _ symbol: String, accent: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(accent ? DromeTheme.accent : DromeTheme.muted)
                .frame(width: 18)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent ? DromeTheme.accent : .white)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DromeTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.bottom, 4)
    }

    private func menuRow(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 16)
            Text(title)
                .font(.caption.weight(.medium))
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct OnboardingSettingsMock: View {
    var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                settingsRow("Haptic intro", trailing: .toggle(false))
                    .opacity(0.4)

                OnboardingSpotlight(label: "Keep Playing", isActive: true, reduceMotion: reduceMotion) {
                    settingsRow(
                        "Keep playing (∞ adds songs when the queue ends)",
                        trailing: .toggle(true))
                }

                settingsRow("Skip low-rated songs everywhere", trailing: .toggle(false))
                    .opacity(0.4)
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
        .background(DromeTheme.background)
    }

    private enum Trailing {
        case toggle(Bool)
    }

    private func settingsRow(_ title: String, trailing: Trailing) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if case .toggle(let on) = trailing {
                Capsule()
                    .fill(on ? DromeTheme.accent : DromeTheme.divider)
                    .frame(width: 34, height: 20)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 16, height: 16)
                            .padding(2)
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(DromeTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
