import SwiftUI

/// Spotify-style “what can I say?” discovery for Drome’s App Shortcuts.
struct SettingsSiriShortcutsView: View {
    private struct ShortcutExample: Identifiable {
        let id = UUID()
        let title: String
        let phrase: String
        let systemImage: String
        let tint: Color
    }

    private var examples: [ShortcutExample] {
        [
            ShortcutExample(
                title: "Play anything",
                phrase: "“Hey Siri, play Bohemian Rhapsody on Drome”",
                systemImage: "play.fill",
                tint: Color(red: 0.95, green: 0.65, blue: 0.22)),
            ShortcutExample(
                title: "Vibes",
                phrase: "“Hey Siri, play Chill on Drome”",
                systemImage: "leaf.fill",
                tint: Color(red: 0.55, green: 0.78, blue: 0.52)),
            ShortcutExample(
                title: "Playlists",
                phrase: "“Hey Siri, play Road Trip on Drome”",
                systemImage: "music.note.list",
                tint: Color(red: 0.45, green: 0.62, blue: 0.98)),
            ShortcutExample(
                title: "Liked songs",
                phrase: "“Hey Siri, play my liked songs on Drome”",
                systemImage: "heart.fill",
                tint: Color(red: 0.92, green: 0.42, blue: 0.48)),
            ShortcutExample(
                title: "Shuffle",
                phrase: "“Hey Siri, shuffle on Drome”",
                systemImage: "shuffle",
                tint: Color(red: 0.62, green: 0.88, blue: 0.95)),
            ShortcutExample(
                title: "Continue",
                phrase: "“Hey Siri, continue on Drome”",
                systemImage: "clock.arrow.circlepath",
                tint: Color(red: 0.78, green: 0.74, blue: 0.62)),
            ShortcutExample(
                title: "Lucky",
                phrase: "“Hey Siri, play Lucky on Drome”",
                systemImage: "dice.fill",
                tint: Color(red: 1.0, green: 0.42, blue: 0.22)),
        ]
    }

    private let vibeTiles: [(MoodVibe, String)] = MoodVibe.allCases.map {
        ($0, "Play \($0.title) on Drome")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                trySayingGrid
                vibeSection
                tips
                openShortcutsButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Siri & Shortcuts")
        .navigationBarTitleDisplayMode(.large)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Talk to Drome like Spotify")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Shortcuts are ready the moment the app is installed. Use “on Drome” or “in Drome” — Siri matches either.")
                .font(.subheadline)
                .foregroundStyle(DromeTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trySayingGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try saying")
                .font(.headline)
                .foregroundStyle(.white)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(examples) { example in
                    shortcutTile(example)
                }
            }
        }
    }

    private func shortcutTile(_ example: ShortcutExample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: example.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(example.title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            Text(example.phrase)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(example.tint.opacity(0.92))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(example.title). \(example.phrase)")
    }

    private var vibeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vibes")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Any station from the Home tuner works with Siri.")
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(vibeTiles, id: \.0.id) { vibe, phrase in
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: vibe.symbol)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(vibe.ink)
                            Text(vibe.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            Text(phrase)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                        }
                        .padding(14)
                        .frame(width: 148, height: 120, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(vibe.wash)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(vibe.ink.opacity(0.35), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tips")
                .font(.headline)
                .foregroundStyle(.white)
            tipRow("Missing tracks go to your Wishlist automatically.")
            tipRow("Name a playlist after you open Library once so Siri can suggest it.")
            tipRow("Pin shortcuts to Control Center or the Lock Screen from the Shortcuts app.")
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DromeTheme.accent)
                .padding(.top, 1)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(DromeTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var openShortcutsButton: some View {
        Button {
            guard let url = URL(string: "shortcuts://") else { return }
            UIApplication.shared.open(url)
        } label: {
            Text("Open Shortcuts app")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.black)
                .background(DromeTheme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityHint("Opens Apple’s Shortcuts app to pin or customize Drome actions.")
    }
}
