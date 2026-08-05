import SwiftUI

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Group {
            if let session = env.session {
                MainTabView()
                    .dromeSession(session)
                    .id(session.id)
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: env.session?.id)
        .dromeScreen()
        .onOpenURL { url in
            handleOpenURL(url)
        }
    }

    /// Handles `drome://track/{songId}` deep links from share sheets.
    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "drome",
              url.host == "track",
              let session = env.session else { return }
        let songId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !songId.isEmpty else { return }
        Task {
            do {
                let song = try await session.client.song(id: songId)
                session.player.play(
                    [song], startAt: 0,
                    context: PlaybackContext(label: song.title, kind: .search))
            } catch {
                // Deep-link failures are silent — the user can retry from the library.
            }
        }
    }
}

