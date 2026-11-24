import Foundation

@main
struct SessionFlowTest {
    static func main() {
        run()
    }
}

func track(_ id: String, artist: String, genre: String, energy: Double, weight: Double) -> FlowTrack {
    FlowTrack(id: id, artist: artist, album: "lp-\(artist)", genre: genre, energy: energy, year: 2018, weight: weight)
}

func assertArtistGap(_ songs: [FlowTrack], gap: Int) {
    for i in songs.indices {
        let start = max(0, i - gap)
        if start == i { continue }
        let recent = songs[start..<i].map(\.artist)
        if recent.contains(songs[i].artist) {
            fputs("artist \(songs[i].artist) returned inside \(gap) at \(i): \(songs.map(\.id))\n", stderr)
            exit(1)
        }
    }
}

func run() {
// Always take the strongest legal neighbor. Jazz should play out before metal.
let mixed = [
    track("j1", artist: "miles", genre: "Jazz", energy: 0.28, weight: 4),
    track("j2", artist: "evans", genre: "Jazz", energy: 0.30, weight: 4),
    track("j3", artist: "coltrane", genre: "Jazz", energy: 0.32, weight: 4),
    track("j4", artist: "blakey", genre: "Jazz", energy: 0.26, weight: 3),
    track("m1", artist: "slayer", genre: "Metal", energy: 0.92, weight: 5),
    track("m2", artist: "metallica", genre: "Metal", energy: 0.90, weight: 5),
    track("m3", artist: "opeth", genre: "Metal", energy: 0.88, weight: 4),
]
let ordered = SessionFlow.arrange(mixed, strictGenre: true, random: { 0 })
assertArtistGap(ordered, gap: 3)
// No song is playing yet, so the heavier room opens — then it stays there
// instead of hopping to the other genre between every track.
let firstJazz = ordered.firstIndex { $0.genre == "Jazz" } ?? 99
let metalBefore = ordered.prefix(firstJazz).filter { $0.genre == "Metal" }.count
if metalBefore < 3 {
    fputs("left metal early: \(ordered.map { $0.id + ":" + $0.genre })\n", stderr)
    exit(1)
}

// Continuation from the song already playing.
let anchor = track("now", artist: "miles", genre: "Jazz", energy: 0.28, weight: 1)
let next = SessionFlow.arrange(mixed, anchor: anchor, strictGenre: true, random: { 0 })
if next.first?.genre != "Jazz" || next.first?.artist == "miles" {
    fputs("anchor did not continue the room: \(next.map(\.id))\n", stderr)
    exit(1)
}

// Lucky-style loose genre still separates artists.
let loose = SessionFlow.arrange(mixed, strictGenre: false, random: { 0.99 })
assertArtistGap(loose, gap: 3)
if loose.count != mixed.count {
    fputs("dropped tracks\n", stderr)
    exit(1)
}

print("SESSION_FLOW_OK \(ordered.map(\.id).joined(separator: " "))")
}
