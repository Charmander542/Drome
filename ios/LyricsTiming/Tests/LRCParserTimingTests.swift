import XCTest
@testable import LRCParser

final class LRCParserTimingTests: XCTestCase {

    func testParsesCentisecondsAndMilliseconds() {
        let lines = LRCParser.parse("""
            [00:01.50]centiseconds
            [00:02.500]milliseconds
            [00:03.5]single-digit
            """)
        XCTAssertEqual(lines.map(\.startMs), [1500, 2500, 3500])
    }

    func testAppliesEmbeddedOffsetOnce() {
        let result = LRCParser.parseDetailed("""
            [offset:1000]
            [00:10.00]hello
            [00:20.00]world
            """)
        XCTAssertEqual(result.embeddedOffsetMs, 1000)
        XCTAssertEqual(result.lines.map(\.startMs), [11_000, 21_000])
    }

    func testNegativeOffsetClampsAtZero() {
        let lines = LRCParser.parse("""
            [offset:-5000]
            [00:03.00]early
            """)
        XCTAssertEqual(lines.first?.startMs, 0)
    }

    func testScaleStretchesWithinTightBand() {
        let lines = LRCParser.parse("""
            [00:00.00]a
            [01:00.00]b
            """)
        // 2% — inside the ±2.5% near-cut window.
        let scaled = LRCParser.scale(lines, fromDurationMs: 60_000, toDurationMs: 61_200)
        XCTAssertEqual(scaled[1].startMs, 61_200)
    }

    func testScaleRejectsProgressiveDriftBand() {
        let lines = LRCParser.parse("""
            [00:00.00]a
            [01:00.00]b
            """)
        // 10% used to be allowed and caused mid-song drift.
        let scaled = LRCParser.scale(lines, fromDurationMs: 60_000, toDurationMs: 66_000)
        XCTAssertEqual(scaled[1].startMs, 60_000)
        let wild = LRCParser.scale(lines, fromDurationMs: 60_000, toDurationMs: 120_000)
        XCTAssertEqual(wild[1].startMs, 60_000)
    }

    func testActiveLineFollowsStampsOnly() {
        let lines = LRCParser.parse("""
            [00:00.00]one
            [00:05.00]two
            [00:10.00]three
            """)
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 0), 0)
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 4_999), 0)
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 5_000), 1)
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 9_999), 1)
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 10_000), 2)
    }

    /// Long instrumental after a short line: highlight must stay on the current
    /// stamp until the next line starts (Aura mid-break used to jump early).
    func testActiveLineDoesNotJumpDuringInstrumental() {
        let lines = LRCParser.parse("""
            [00:00.00]short
            [00:20.00]after break
            """)
        // Halfway through a 20s gap — still on line 0.
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 10_000), 0)
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 19_999), 0)
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 20_000), 1)
    }

    func testFocusIndexDoesNotActivateNextLineBeforeStamp() {
        let lines = LRCParser.parse("""
            [00:00.00]short line
            [00:20.00]after break
            """)
        let last = LRCParser.activeLineIndex(lines: lines, atMs: 10_000)
        let focus = LRCParser.focusIndex(lines: lines, after: last, atMs: 10_000)
        XCTAssertEqual(focus, 0)
        XCTAssertEqual(
            LRCParser.focusIndex(lines: lines, after: last, atMs: 20_000),
            1)
    }

    func testLineFinishUsesWordEndNotStartPlusBeat() {
        let lines = LRCParser.parse("""
            [00:00.00]hello world today
            [00:10.00]next
            """)
        let finish = LRCParser.lineFinishMs(lines: lines, index: 0)
        XCTAssertNotNil(finish)
        // Pace-synthesized window should end near/before next stamp — not at
        // first-word-start + 600ms (~600) which was the old Enhanced false positive.
        XCTAssertGreaterThan(finish!, 1_500)
        XCTAssertLessThanOrEqual(finish!, 10_000)
    }

    /// Aura: ordinary gaps (near song pace) run word windows to the next stamp.
    func testOrdinaryLineWordWindowRunsToNextStamp() {
        // Eight ~40-char lines every 3s → pace ≈ 75ms/char; sung ≈ 3.6s ≥ gap.
        let lines = makeSong(timesMs: [0, 3_000, 6_000, 9_000, 12_000, 15_000, 18_000, 21_000])
        XCTAssertEqual(LRCParser.lineEndMs(lines: lines, index: 1), 6_000)
        XCTAssertEqual(lines[1].words.last?.endMs, 6_000)
    }

    /// Aura: a long instrumental ends the sung window early so words don't crawl.
    func testBreakEndsWordWindowBeforeNextStamp() {
        let lines = makeSong(timesMs: [0, 3_000, 6_000, 9_000, 22_000, 25_000, 28_000, 31_000])
        let end = LRCParser.lineEndMs(lines: lines, index: 3)!
        XCTAssertGreaterThan(end, 9_000)
        XCTAssertLessThan(end, 20_000)
    }

    func testDistributedWordStartsAreMonotonicAcrossLine() {
        let lines = makeSong(timesMs: [0, 3_000, 6_000, 9_000, 12_000, 15_000, 18_000, 21_000])
        let words = lines[1].words
        XCTAssertGreaterThanOrEqual(words.count, 2)
        for i in 1..<words.count {
            XCTAssertGreaterThan(words[i].startMs, words[i - 1].startMs)
        }
        XCTAssertEqual(words.first?.startMs, 3_000)
        XCTAssertEqual(words.last?.endMs, 6_000)
    }

    /// ~40-character lines at the given starts (Aura LyricWordTimingTests helper).
    private func makeSong(timesMs: [Int]) -> [LRCParser.Line] {
        let chunk = String(repeating: "lala ", count: 10).trimmingCharacters(in: .whitespaces)
        let body = timesMs.enumerated().map { idx, ms in
            let m = ms / 60_000
            let s = (ms % 60_000) / 1000
            let cs = (ms % 1000) / 10
            return String(format: "[%02d:%02d.%02d]%@", m, s, cs, chunk)
        }.joined(separator: "\n")
        return LRCParser.parse(body)
    }

    func testEnhancedLRCPreservesWordStarts() {
        let lines = LRCParser.parse("""
            [00:01.00] <00:01.00>Hello <00:01.40>world
            """)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].words.map(\.startMs), [1000, 1400])
        XCTAssertEqual(lines[0].words[0].endMs, 1400)
    }

    func testSerializeOffsetRoundTrip() {
        let raw = LRCParser.serialize(
            lines: [(startMs: 12_340, text: "hi"), (startMs: 20_000, text: "there")],
            offsetMs: -250)
        let parsed = LRCParser.parseDetailed(raw)
        XCTAssertEqual(parsed.embeddedOffsetMs, -250)
        XCTAssertEqual(parsed.lines[0].startMs, 12_090)
        XCTAssertEqual(parsed.lines[1].startMs, 19_750)
    }
}
