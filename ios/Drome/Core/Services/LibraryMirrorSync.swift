import Foundation

/// Background refresh of the local library mirror so browse/search stay offline-first
/// (SubSonify / Arpeggi light-sync pattern). Does not block Home launch.
@MainActor
enum LibraryMirrorSync {
    private static var inflight: Task<Void, Never>?

    static func refreshIfNeeded(session: AppSession) {
        guard inflight == nil else { return }
        inflight = Task {
            defer { inflight = nil }
            await run(session: session)
        }
    }

    private static func run(session: AppSession) async {
        let key = session.account.serverKey
        let index = session.library
        let client = session.client

        // Prefer append/upsert of newest albums + a page of songs without wiping.
        do {
            let newest = try await client.albumList(type: .newest, size: 40)
            try? index.appendAlbums(newest, serverKey: key, isComplete: false)
        } catch {
            DromeDiagnostics.logNetwork("libraryMirror albums failed: \(error.localizedDescription)")
        }

        do {
            // Light song page via native API when available.
            let page = try await client.nativeSongs(start: 0, end: 200)
            if !page.isEmpty {
                try? index.appendSongs(page, serverKey: key, isComplete: false)
            }
        } catch {
            // Non-native servers: skip quietly.
            DromeDiagnostics.logNetwork("libraryMirror songs skipped: \(error.localizedDescription)")
        }
    }
}
