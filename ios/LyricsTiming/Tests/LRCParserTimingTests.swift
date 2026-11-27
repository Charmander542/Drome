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

    /// Heard stamp stays put; focus may preview the next line mid-break.
    func testActiveLineStampStaysUntilNextStarts() {
        let lines = LRCParser.parse("""
            [00:00.00]short
            [00:20.00]after break
            """)
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 10_000), 0)
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 19_999), 0)
        XCTAssertEqual(LRCParser.activeLineIndex(lines: lines, atMs: 20_000), 1)
    }

    /// Aura: across a break, focus moves halfway between finish and next stamp.
    func testFocusMovesHalfwayAcrossBreak() {
        let lines = makeSong(timesMs: [0, 3_000, 6_000, 9_000, 22_000, 25_000, 28_000, 31_000])
        let finished = LRCParser.lineFinishMs(lines: lines, index: 3)!
        let halfway = finished + (22_000 - finished) / 2
        XCTAssertEqual(LRCParser.focusIndex(lines: lines, after: 3, atMs: halfway - 100), 3)
        XCTAssertEqual(LRCParser.focusIndex(lines: lines, after: 3, atMs: halfway + 100), 4)
    }

    /// Aura: focus never leaves a line before its last interpolated word has lit.
    func testFocusNeverLeavesBeforeLastWord() {
        let lines = makeSong(timesMs: [0, 3_000, 6_000, 9_000, 22_000, 25_000, 28_000, 31_000])
        let lastWord = lines[3].words.last!.startMs
        for step in 0..<260 {
            let time = 9_000 + step * 50
            if LRCParser.focusIndex(lines: lines, after: 3, atMs: time) == 4 {
                XCTAssertGreaterThanOrEqual(time, lastWord)
            }
        }
    }

    /// Aura: ordinary line keeps focus until the next stamp.
    func testOrdinaryLineKeepsFocus() {
        let lines = makeSong(timesMs: [0, 3_000, 6_000, 9_000, 12_000, 15_000, 18_000, 21_000])
        for step in 0..<60 {
            let time = 3_000 + step * 50
            XCTAssertEqual(LRCParser.focusIndex(lines: lines, after: 1, atMs: time), 1)
        }
    }

    func testInterpolatedLineFinishUsesLineEndNotStartPlusBeat() {
        let lines = LRCParser.parse("""
            [00:00.00]hello world today
            [00:10.00]next
            """)
        let finish = LRCParser.lineFinishMs(lines: lines, index: 0)
        XCTAssertNotNil(finish)
        XCTAssertGreaterThan(finish!, 1_500)
        XCTAssertLessThanOrEqual(finish!, 10_000)
        XCTAssertFalse(lines[0].words.contains(where: \.measured))
    }

    func testMeasuredLineFinishIsLastCuePlusBeat() {
        let lines = LRCParser.parse("""
            [00:09.00] <00:09.00>hold <00:10.00>on
            [00:22.00]next
            """)
        XCTAssertTrue(lines[0].words.allSatisfy(\.measured))
        XCTAssertEqual(LRCParser.lineFinishMs(lines: lines, index: 0), 10_600)
    }

    func testRepeatMarkerCyclesWordHighlight() {
        let lines = LRCParser.parse("""
            [00:00.00]hey ya friend x4
            [00:08.00]next
            """)
        let words = lines[0].words
        XCTAssertTrue(words.dropLast().allSatisfy { $0.cycle != nil })
        XCTAssertEqual(words.last?.marker, true)
        let second = words[1]
        let period = second.cycle!.periodMs
        XCTAssertTrue(second.isLit(atMs: second.startMs))
        // Next pass: not yet at this word’s offset into the pass, then lit again.
        XCTAssertFalse(second.isLit(atMs: second.startMs + period - 40))
        XCTAssertTrue(second.isLit(atMs: second.startMs + period))
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

    func testSyncClockUsesPresentationTimeWithoutLatency() {
        XCTAssertEqual(
            LyricsClock.syncMilliseconds(presentationSeconds: 12.345, userOffsetMs: 0),
            12_345)
        XCTAssertEqual(
            LyricsClock.syncMilliseconds(presentationSeconds: 12.345, userOffsetMs: 200),
            12_545)
        XCTAssertEqual(
            LyricsClock.syncMilliseconds(presentationSeconds: 0.01, userOffsetMs: -500),
            0)
        XCTAssertEqual(
            LyricsClock.syncMilliseconds(presentationSeconds: .nan, userOffsetMs: 10),
            10)
    }

    /// Lead 45 ms, arrival 70 ms: unsung at −lead, mid-ramp on the stamp, full at +45 ms.
    func testWordArrivalLightsOnTheStamp() {
        let lead = LyricsClock.wordLeadMs
        let mid = LyricsClock.unsungOpacity
            + (LyricsClock.sungOpacity - LyricsClock.unsungOpacity)
            * Double(lead) / Double(LyricsClock.wordArrivalMs)
        XCTAssertEqual(LyricsClock.wordOpacity(elapsedMs: -lead), LyricsClock.unsungOpacity)
        XCTAssertEqual(LyricsClock.wordOpacity(elapsedMs: 0), mid, accuracy: 0.001)
        XCTAssertEqual(LyricsClock.wordOpacity(elapsedMs: 45), LyricsClock.sungOpacity, accuracy: 0.001)
        XCTAssertEqual(LyricsClock.wordOpacity(elapsedMs: 400), LyricsClock.sungOpacity)
    }

    func testKaraokeResumeTrustsAccurateExceptDuringSeek() {
        XCTAssertEqual(KaraokeResume.chooseElapsed(accurate: 12.5, published: 10, seekInFlight: false), 12.5)
        XCTAssertEqual(KaraokeResume.chooseElapsed(accurate: 0.2, published: 45, seekInFlight: false), 0.2)
        XCTAssertEqual(KaraokeResume.chooseElapsed(accurate: -1, published: 30, seekInFlight: false), 30)
        XCTAssertEqual(KaraokeResume.chooseElapsed(accurate: 0.05, published: 28, seekInFlight: true), 28)
    }

    /// Foreground return: published UI playhead can sit ~1 s behind while
    /// `AVPlayer.currentTime` is already correct — karaoke must use accurate.
    func testKaraokeResumeForegroundSnapIgnoresStalePublished() {
        let songTime = 97.4
        let stalePublished = songTime - 1.05
        let chosen = KaraokeResume.chooseElapsed(
            accurate: songTime,
            published: stalePublished,
            seekInFlight: false)
        XCTAssertEqual(chosen, songTime)
        let ms = LyricsClock.syncMilliseconds(presentationSeconds: chosen, userOffsetMs: 0)
        XCTAssertEqual(ms, 97_400)
        // Stale published would light the previous line / word.
        XCTAssertNotEqual(
            LyricsClock.syncMilliseconds(presentationSeconds: stalePublished, userOffsetMs: 0),
            ms)
    }

    /// Walk a word-synced line at display rate; ~80% lit should land within ~50 ms of the stamp.
    func testMeasuredWordsLockToStampsAtFrameRate() {
        let lines = LRCParser.parse("""
            [00:01.00] <00:01.00>Hello <00:01.40>there <00:01.90>world
            [00:03.00]next
            """)
        let words = lines[0].words
        XCTAssertEqual(words.map(\.startMs), [1_000, 1_400, 1_900])
        let rampFraction = 0.8
        let clearlyLit = LyricsClock.unsungOpacity
            + (LyricsClock.sungOpacity - LyricsClock.unsungOpacity) * rampFraction
        let expectedLitAt = Int((Double(LyricsClock.wordArrivalMs) * rampFraction).rounded())
            - LyricsClock.wordLeadMs
        for word in words {
            var crossed: Int?
            var step = word.startMs - 80
            while step <= word.startMs + 80 {
                let playhead = LyricsClock.syncMilliseconds(
                    presentationSeconds: Double(step) / 1000,
                    userOffsetMs: 0)
                let opacity = LyricsClock.wordOpacity(elapsedMs: word.elapsed(atMs: playhead))
                if opacity >= clearlyLit {
                    crossed = playhead
                    break
                }
                step += 16
            }
            guard let litAt = crossed else {
                XCTFail("\(word.text) never reached a clear highlight")
                continue
            }
            XCTAssertLessThanOrEqual(abs(litAt - (word.startMs + expectedLitAt)), 16)
            XCTAssertLessThan(abs(litAt - word.startMs), 50)
        }
        let atHello = LyricsClock.syncMilliseconds(presentationSeconds: 1.0, userOffsetMs: 0)
        XCTAssertTrue(words[0].isLit(atMs: atHello))
        XCTAssertFalse(words[1].isLit(atMs: atHello))
        XCTAssertEqual(LRCParser.currentLineIndex(lines: lines, atMs: atHello), 0)
        XCTAssertEqual(LRCParser.currentLineIndex(lines: lines, atMs: 2_999), 0)
        XCTAssertEqual(LRCParser.currentLineIndex(lines: lines, atMs: 3_000), 1)
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
