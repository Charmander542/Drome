import Foundation

/// Parses LRC-format lyrics ("[mm:ss.xx] line") into timed lines.
enum LRCParser {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var startMs: Int?
        var text: String

        static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.id == rhs.id
        }
    }

    private static let timeTag = /\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]/

    static func isSynced(_ raw: String) -> Bool {
        raw.contains(timeTag)
    }

    /// Parses LRC text. Lines may carry multiple time tags. Plain (untimed)
    /// input comes back as untimed lines.
    static func parse(_ raw: String) -> [Line] {
        var timed: [Line] = []
        var untimed: [Line] = []

        for rawLine in raw.components(separatedBy: .newlines) {
            let matches = rawLine.matches(of: timeTag)
            if matches.isEmpty {
                let text = rawLine.trimmingCharacters(in: .whitespaces)
                // Skip LRC metadata tags like [ar:...], [ti:...]
                if text.hasPrefix("["), text.hasSuffix("]"), text.contains(":") { continue }
                untimed.append(Line(startMs: nil, text: text))
                continue
            }
            guard let lastMatch = matches.last else { continue }
            let text = String(rawLine[lastMatch.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Int(match.1) ?? 0
                let seconds = Int(match.2) ?? 0
                let fractionRaw = match.3.map(String.init) ?? "0"
                // ".5" = 500ms, ".50" = 500ms, ".500" = 500ms
                let padded = fractionRaw.padding(toLength: 3, withPad: "0", startingAt: 0)
                let ms = (minutes * 60 + seconds) * 1000 + (Int(padded) ?? 0)
                timed.append(Line(startMs: ms, text: text))
            }
        }

        if timed.isEmpty {
            return untimed.filter { !$0.text.isEmpty || untimed.count < 400 }
        }
        return timed.sorted { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
    }

    /// Strips all time/metadata tags, producing plain text for the FTS index.
    static func plainText(from raw: String) -> String {
        parse(raw)
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Renders timed lines back to LRC for cache storage.
    static func serialize(lines: [(startMs: Int?, text: String)]) -> String {
        lines.map { line in
            if let ms = line.startMs {
                let m = ms / 60000
                let s = (ms % 60000) / 1000
                let hundredths = (ms % 1000) / 10
                return String(format: "[%02d:%02d.%02d]%@", m, s, hundredths, line.text)
            }
            return line.text
        }
        .joined(separator: "\n")
    }
}
