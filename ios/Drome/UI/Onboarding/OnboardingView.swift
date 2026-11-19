import SwiftUI

/// First-run walkthrough after sign-in. One idea per page — skip anytime.
struct OnboardingView: View {
    let userKey: String
    var onFinished: () -> Void

    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            systemImage: "waveform",
            title: "Welcome to Drome",
            body: "Your private library, tuned to how you listen — ratings, playlists, mixes, and playback that stays yours even when the catalog grows."),
        OnboardingPage(
            systemImage: "rectangle.stack.fill",
            title: "Browse your library",
            body: "Home surfaces Daily Mixes and vibes. Search finds tracks fast. Your Library holds playlists, artists, albums, downloads, and Top Rated."),
        OnboardingPage(
            systemImage: "star.fill",
            title: "Rate what you love",
            body: "Stars teach Drome your taste. Tracks you rate 1–2★ land in Out of Rotation so shuffle and autoplay stop suggesting them — even if someone else added them to the server."),
        OnboardingPage(
            systemImage: "music.note.list",
            title: "Build & share playlists",
            body: "Create playlists from Library or any track menu. Share a link with friends on your server, or make a playlist public so household accounts can play and edit it."),
        OnboardingPage(
            systemImage: "infinity",
            title: "Keep the music going",
            body: "Daily Mixes and the Vibe tuner pick from your signals. Turn on Keep Playing in Settings and Infinite Shuffle fills the queue from similar artists — biased to your ratings, not the whole house’s play counts."),
    ]

    var body: some View {
        ZStack {
            DromeTheme.background.ignoresSafeArea()
            ambientGlow
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { finish() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DromeTheme.muted)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        pageContent(item)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.28), value: page)

                pageDots
                    .padding(.bottom, 20)

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
                .padding(.bottom, 28)
                .accessibilityIdentifier("onboarding-continue")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func pageContent(_ item: OnboardingPage) -> some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)
            ZStack {
                Circle()
                    .fill(DromeTheme.accent.opacity(0.16))
                    .frame(width: 148, height: 148)
                Circle()
                    .stroke(DromeTheme.accent.opacity(0.35), lineWidth: 1)
                    .frame(width: 148, height: 148)
                Image(systemName: item.systemImage)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(DromeTheme.accent)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(spacing: 14) {
                Text(item.title)
                    .font(DromeTheme.headlineFont)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Text(item.body)
                    .font(.body)
                    .foregroundStyle(DromeTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 24)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pages.count, id: \.self) { index in
                Capsule()
                    .fill(index == page ? DromeTheme.accent : Color.white.opacity(0.22))
                    .frame(width: index == page ? 18 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.22), value: page)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1) of \(pages.count)")
    }

    private var ambientGlow: some View {
        RadialGradient(
            colors: [DromeTheme.accent.opacity(0.22), .clear],
            center: .top,
            startRadius: 40,
            endRadius: 420)
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
