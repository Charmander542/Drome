import Foundation

/// Keeps starred tracks downloaded when the preference is on (SubSonify-style).
@MainActor
enum AutoDownloadRules {
    static func syncStarredIfNeeded(
        client: SubsonicClient,
        downloads: DownloadManager
    ) async {
        guard AudioFXPreferences.autoDownloadStarred else { return }
        let starred = ((try? await client.starred())?.songs) ?? []
        let missing = starred.filter { !downloads.isDownloaded($0.id) }
        guard !missing.isEmpty else { return }
        downloads.download(Array(missing.prefix(25)))
    }
}
