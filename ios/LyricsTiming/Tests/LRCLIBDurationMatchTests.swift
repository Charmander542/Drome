import XCTest
@testable import LRCParser

/// Duration-matching rules mirrored from `LRCLIBClient.pickBest` — radio edits
/// vs album cuts must not light mistimed karaoke (round 6 / BDKMV).
final class LRCLIBDurationMatchTests: XCTestCase {

    private let maxDelta: Double = 3.0

    private struct Hit {
        var id: Int
        var duration: Double?
        var hasWordSync: Bool
        var plainOnly: Bool = false
        var album: String? = nil
    }

    /// Same scoring / reject rules as `LRCLIBClient.pickBest`.
    private func pickBest(_ results: [Hit], album: String?, duration: Int?) -> Hit? {
        guard !results.isEmpty else { return nil }

        func score(_ r: Hit) -> Double {
            var s = 0.0
            if r.plainOnly {
                s += 10
            } else if r.hasWordSync {
                s += 140
            } else {
                s += 100
            }
            if let duration, let remote = r.duration, remote > 0 {
                let delta = abs(remote - Double(duration))
                if delta <= 1.0 { s += 80 }
                else if delta <= 2.0 { s += 55 }
                else if delta <= maxDelta { s += 20 }
                else { s -= 200 }
                s -= delta * 4
            }
            if let album, !album.isEmpty, r.album?.lowercased() == album.lowercased() {
                s += 12
            }
            return s
        }

        let ranked = results.sorted { score($0) > score($1) }
        guard var best = ranked.first else { return nil }

        if let duration,
           let remote = best.duration,
           abs(remote - Double(duration)) > maxDelta,
           let closer = ranked.first(where: {
               !$0.plainOnly && abs(($0.duration ?? 0) - Double(duration)) <= maxDelta
           }) {
            best = closer
        }
        if let duration,
           let remote = best.duration,
           !best.plainOnly,
           abs(remote - Double(duration)) > maxDelta {
            if let plain = ranked.first(where: { $0.plainOnly }) {
                return plain
            }
            return nil
        }
        return best
    }

    func testPrefers311sAlbumCutOver214sRadioEdit() {
        let trackSec = 311 // 310.72s FLAC rounded
        let radio = Hit(id: 214000, duration: 214, hasWordSync: true)
        let album = Hit(id: 565635, duration: 311, hasWordSync: true)
        let best = pickBest([radio, album], album: "good kid, m.A.A.d city", duration: trackSec)
        XCTAssertEqual(best?.id, 565635)
    }

    func testRejectsSyncedWhenOnlyMismatchedCutExists() {
        let radio = Hit(id: 214000, duration: 214, hasWordSync: true)
        XCTAssertNil(pickBest([radio], album: nil, duration: 311))
    }

    func testAcceptsWithinThreeSeconds() {
        let hit = Hit(id: 9, duration: 208, hasWordSync: true)
        XCTAssertEqual(pickBest([hit], album: nil, duration: 210)?.id, 9)
    }

    func testRejectsBeyondThreeSeconds() {
        let hit = Hit(id: 9, duration: 200, hasWordSync: true)
        XCTAssertNil(pickBest([hit], album: nil, duration: 210))
    }

    func testProvenanceDurationRegex() {
        let raw = """
            [drome-lrclib-id:565635]
            [drome-lrclib-duration:311.000]
            [00:01.000] <00:01.000>hello
            """
        let idRe = try! NSRegularExpression(pattern: #"\[drome-lrclib-id:(\d+)\]"#, options: .caseInsensitive)
        let durRe = try! NSRegularExpression(pattern: #"\[drome-lrclib-duration:([0-9]+(?:\.[0-9]+)?)\]"#, options: .caseInsensitive)
        let ns = raw as NSString
        let idM = idRe.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length))
        let durM = durRe.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length))
        XCTAssertEqual(ns.substring(with: idM!.range(at: 1)), "565635")
        XCTAssertEqual(Double(ns.substring(with: durM!.range(at: 1))), 311.0)
    }
}
