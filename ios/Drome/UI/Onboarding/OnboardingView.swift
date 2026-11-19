import SwiftUI

/// First-run walkthrough after sign-in. One idea per page — skip anytime.
struct OnboardingView: View {
    let userKey: String
    var onFinished: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page = 0

    @ScaledMetric(relativeTo: .largeTitle) private var heroDiameter: CGFloat = 132
    @ScaledMetric(relativeTo: .largeTitle) private var heroSymbolPointSize: CGFloat = 46

    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            systemImage: "waveform",
            title: "Welcome to Drome",
            body: "Your private library, tuned to your taste — ratings, playlists, and mixes that stay yours."),
        OnboardingPage(
            systemImage: "rectangle.stack.fill",
            title: "Browse your library",
            body: "Home surfaces Daily Mixes and vibes. Search finds tracks fast. Library holds playlists, artists, albums, and more."),
        OnboardingPage(
            systemImage: "star.fill",
            title: "Rate what you love",
            body: "Rate a track 1–2★ and it lands in Out of Rotation — shuffle and autoplay stop suggesting it."),
        OnboardingPage(
            systemImage: "music.note.list",
            title: "Build & share playlists",
            body: "Create a playlist, share a link on your server, or make it public for your household."),
        OnboardingPage(
            systemImage: "infinity",
            title: "Keep the music going",
            body: "Daily Mixes, the Vibe tuner, and Keep Playing with Infinite Shuffle keep discovering from your taste."),
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
                        .foregroundStyle(Color.white.opacity(0.78))
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        pageContent(item)
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
    }

    @ViewBuilder
    private func pageContent(_ item: OnboardingPage) -> some View {
        let stack = VStack(spacing: 0) {
            if !accessibilityLayout {
                Spacer(minLength: 12)
            }

            if showHero {
                hero(for: item)
                    .padding(.bottom, accessibilityLayout ? 16 : 26)
                    .accessibilityHidden(true)
            }

            Text(item.title)
                .font(DromeTheme.titleFont)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.bottom, accessibilityLayout ? 8 : 12)

            Text(item.body)
                .font(.body)
                .foregroundStyle(DromeTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            if !accessibilityLayout {
                Spacer(minLength: 12)
            } else {
                Spacer(minLength: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        if accessibilityLayout {
            ScrollView {
                stack
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        } else {
            stack
        }
    }

    private var showHero: Bool {
        // Collapse fully at larger AX sizes; keep a compact hero at AX1.
        switch dynamicTypeSize {
        case .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            return false
        default:
            return true
        }
    }

    private var compactHero: Bool { accessibilityLayout }

    private func hero(for item: OnboardingPage) -> some View {
        let diameter = compactHero
            ? min(heroDiameter * 0.62, 88)
            : min(max(heroDiameter, 112), 160)
        let symbolSize = compactHero
            ? min(heroSymbolPointSize * 0.62, 30)
            : min(max(heroSymbolPointSize, 40), 56)

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            DromeTheme.accent.opacity(0.28),
                            DromeTheme.accent.opacity(0.08),
                            .clear,
                        ],
                        center: .center,
                        startRadius: diameter * 0.12,
                        endRadius: diameter * 0.72))
                .frame(width: diameter * 1.35, height: diameter * 1.35)

            Circle()
                .fill(DromeTheme.accent.opacity(0.14))
                .frame(width: diameter, height: diameter)

            Circle()
                .stroke(DromeTheme.accent.opacity(0.28), lineWidth: 1)
                .frame(width: diameter, height: diameter)

            Image(systemName: item.systemImage)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(DromeTheme.accent)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(height: diameter * 1.2)
    }

    private var bottomChrome: some View {
        VStack(spacing: 14) {
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
        .padding(.top, 8)
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
                .accessibilityLabel("Page \(index + 1)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1) of \(pages.count)")
    }

    private var ambientGlow: some View {
        RadialGradient(
            colors: [DromeTheme.accent.opacity(0.14), DromeTheme.accent.opacity(0.04), .clear],
            center: UnitPoint(x: 0.5, y: 0.18),
            startRadius: 20,
            endRadius: 380)
        .ignoresSafeArea()
    }

    private func finish() {
        OnboardingPreference.markCompleted(userKey: userKey)
        onFinished()
    }
}

private struct OnboardingPage {
    let systemImage: String
    let title: String
    let body: String
}
