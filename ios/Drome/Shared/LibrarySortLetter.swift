import Foundation

/// Shared A–Z / `#` bucketing for library section indexes.
enum LibrarySortLetter {
    private static let articles: Set<String> = ["a", "an", "the"]

    /// Sortable display key with leading articles stripped (`"The Wall"` → `"Wall"`).
    static func sortableName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return trimmed }
        if articles.contains(String(first).lowercased()), parts.count > 1 {
            return parts.dropFirst().joined(separator: " ")
        }
        return trimmed
    }

    /// Section letter: A–Z for Latin letters, `#` for digits/symbols/empty.
    /// Non-Latin letters use their uppercase form when it is a single Character
    /// in the letter category; otherwise `#`.
    /// When `preferWholeIfSingle`, a one-character Navidrome index name is kept.
    static func sectionLetter(for name: String, preferWholeIfSingle: Bool = false) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "#" }

        if preferWholeIfSingle, trimmed.count == 1 {
            if let ch = trimmed.first, ch.isLetter {
                let upper = String(ch).uppercased()
                if upper.count == 1, let u = upper.first, ("A"..."Z").contains(u) {
                    return upper
                }
                return "#"
            }
            return "#"
        }

        let key = sortableName(trimmed)
        guard let first = key.first else { return "#" }

        if first.isNumber || first.isPunctuation || first.isSymbol || first.isWhitespace {
            return "#"
        }

        let upper = String(first).uppercased()
        if upper.count == 1, let u = upper.first, ("A"..."Z").contains(u) {
            return upper
        }
        // Non-Latin letter (or multi-char uppercase): keep a stable single-bucket `#`
        // so the scrubber stays A–Z/# only.
        return "#"
    }

    static func sectionLetterSort(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "#" { return false }
        if rhs == "#" { return true }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
