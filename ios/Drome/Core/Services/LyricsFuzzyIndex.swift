import Foundation

/// In-memory lyrics corpus with precomputed normalized tokens.
/// Built off the main actor from the on-device lyrics cache; searches stay
/// non-blocking for the UI.
actor LyricsFuzzyIndex {
    static let shared = LyricsFuzzyIndex()

    private var documents: [LyricsFuzzySearch.Document] = []
    private var buckets: [String: [Int]] = [:]
    private var serverKey: String?
    private var builtCount: Int = 0
    private var isBuilding = false

    var documentCount: Int { documents.count }

    /// Rebuild when the cached lyrics count changes (or server switches).
    func ensureReady(serverKey: String, database: AppDatabase) async {
        let count = (try? database.lyricsCount(serverKey: serverKey)) ?? 0
        if self.serverKey == serverKey, builtCount == count, !documents.isEmpty {
            return
        }
        if isBuilding { return }
        isBuilding = true
        defer { isBuilding = false }
        let rows = (try? database.lyricsCorpus(serverKey: serverKey)) ?? []
        var docs: [LyricsFuzzySearch.Document] = []
        docs.reserveCapacity(rows.count)
        for row in rows {
            guard row.source != "none", !row.content.isEmpty else { continue }
            let plain = LRCParser.plainText(from: row.content)
            guard !plain.isEmpty else { continue }
            docs.append(LyricsFuzzySearch.document(
                songId: row.songId,
                title: row.title,
                artist: row.artist,
                album: row.album,
                plainContent: plain
            ))
        }
        var newBuckets: [String: [Int]] = [:]
        for (di, doc) in docs.enumerated() {
            var seen = Set<String>()
            for lineToks in doc.lineTokens {
                for tok in lineToks {
                    let key = LyricsFuzzySearch.bucketKey(tok)
                    if seen.insert(key).inserted {
                        newBuckets[key, default: []].append(di)
                    }
                }
            }
        }
        documents = docs
        buckets = newBuckets
        self.serverKey = serverKey
        builtCount = count
    }

    /// Invalidate so the next search reloads (e.g. after a reindex).
    func invalidate() {
        documents = []
        buckets = [:]
        builtCount = 0
        serverKey = nil
    }

    func search(query: String, limit: Int = 40, candidateCap: Int = 600) -> [LyricsFuzzySearch.Hit] {
        // Reuse the pure search helper with the warm corpus + buckets by
        // temporarily rebuilding the public search path over `documents`.
        // Keeping one implementation avoids drift with LyricsSearchKit tests.
        guard !documents.isEmpty else { return [] }
        return LyricsFuzzySearch.search(
            documents: documents,
            query: query,
            limit: limit,
            candidateCap: candidateCap,
            prebuiltBuckets: buckets
        )
    }
}
