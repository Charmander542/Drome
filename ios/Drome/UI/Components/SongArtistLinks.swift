import SwiftUI

/// Renders each credited artist as its own tappable name so multi-artist
/// tracks can open any listed artist's page (not only the primary `artistId`).
struct SongArtistLinks: View {
    let song: Song
    var font: Font = .subheadline
    var color: Color = DromeTheme.muted
    var lineLimit: Int? = 1

    @EnvironmentObject private var songNavigator: SongNavigator
    @Environment(\.session) private var session

    @State private var resolvingName: String?

    private var credits: [ArtistCredit] {
        ArtistCredits.credits(for: song)
    }

    var body: some View {
        Group {
            if credits.isEmpty {
                Text("Unknown Artist")
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(lineLimit)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                        if index > 0 {
                            Text(", ")
                                .font(font)
                                .foregroundStyle(color)
                        }
                        Button {
                            open(credit)
                        } label: {
                            HStack(spacing: 4) {
                                if resolvingName == credit.name {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                                Text(credit.name)
                                    .font(font)
                                    .foregroundStyle(color)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(resolvingName != nil)
                        .accessibilityLabel("View \(credit.name)")
                    }
                }
                .lineLimit(lineLimit)
            }
        }
    }

    private func open(_ credit: ArtistCredit) {
        if let id = credit.artistId, !id.isEmpty {
            songNavigator.viewArtist(id: id, name: credit.name)
            return
        }
        guard let session else { return }
        resolvingName = credit.name
        Task {
            defer { resolvingName = nil }
            let id = await Self.resolveArtistID(name: credit.name, client: session.client)
            if let id {
                songNavigator.viewArtist(id: id, name: credit.name)
            }
        }
    }

    /// Best-effort lookup when OpenSubsonic didn't attach an artist id.
    static func resolveArtistID(name: String, client: SubsonicClient) async -> String? {
        let key = LibraryMatcher.normalize(name)
        guard !key.isEmpty else { return nil }
        do {
            let result = try await client.search(name, artistCount: 8, albumCount: 0, songCount: 0)
            let artists = result.artist ?? []
            if let exact = artists.first(where: { LibraryMatcher.normalize($0.name) == key }) {
                return exact.id
            }
            return artists.first?.id
        } catch {
            return nil
        }
    }
}
