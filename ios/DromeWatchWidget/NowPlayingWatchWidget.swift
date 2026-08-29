import WidgetKit
import SwiftUI
import AppIntents

@main
struct DromeWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWatchWidget()
    }
}

struct NowPlayingWatchWidget: Widget {
    let kind = "NowPlayingWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingWatchProvider()) { entry in
            NowPlayingWatchWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("See what's playing and control playback.")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}

struct NowPlayingWatchEntry: TimelineEntry {
    let date: Date
    let payload: WatchPlaybackPayload
}

struct NowPlayingWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingWatchEntry {
        NowPlayingWatchEntry(date: Date(), payload: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingWatchEntry) -> Void) {
        completion(NowPlayingWatchEntry(date: Date(), payload: WatchWidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingWatchEntry>) -> Void) {
        let payload = WatchWidgetStore.load()
        let now = Date()
        var entries = [NowPlayingWatchEntry(date: now, payload: payload)]

        if payload.showsNowPlaying(at: now), let np = payload.nowPlaying {
            if np.isPlaying, np.duration > 0 {
                for step in 1..<24 {
                    entries.append(
                        NowPlayingWatchEntry(
                            date: now.addingTimeInterval(Double(step * 15)),
                            payload: payload))
                }
            }
            let stale = Date(timeIntervalSince1970: payload.updatedAt + WatchPlaybackPayload.staleSyncInterval)
            if stale > now {
                entries.append(NowPlayingWatchEntry(date: stale, payload: payload))
            }
        }

        entries.sort { $0.date < $1.date }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct NowPlayingWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingWatchEntry

    private var payload: WatchPlaybackPayload { entry.payload }
    private var np: WatchNowPlaying? { payload.nowPlaying }
    private var isLive: Bool { payload.showsNowPlaying(at: entry.date) }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                rectangularView
            case .accessoryCircular:
                circularView
            case .accessoryInline:
                inlineView
            case .accessoryCorner:
                cornerView
            default:
                rectangularView
            }
        }
        .containerBackground(for: .widget) {
            if isLive, let np {
                washBackground(for: np)
            } else {
                WatchWidgetColors.idleBackground
            }
        }
    }

    @ViewBuilder
    private var rectangularView: some View {
        if isLive, let np {
            HStack(spacing: 6) {
                WatchWidgetArtwork(songId: payload.artworkSongId ?? np.songId)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(np.title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Text(np.artist)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    WatchWidgetProgressBar(nowPlaying: np)
                        .padding(.top, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 6) {
                WatchDromeBarMark(size: 12, color: .white)
                Text("Open Drome")
                    .font(.caption2.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    private var circularView: some View {
        if isLive, let np {
            ZStack {
                WatchWidgetArtwork(songId: np.songId)
                    .clipShape(Circle())
                if np.isPlaying {
                    Circle()
                        .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                }
                Button(intent: WatchWidgetTogglePlayIntent()) {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
            }
        } else {
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    @ViewBuilder
    private var inlineView: some View {
        if isLive, let np {
            Text("\(np.title) — \(np.artist)")
                .lineLimit(1)
        } else {
            Text("Drome")
        }
    }

    @ViewBuilder
    private var cornerView: some View {
        if isLive, let np {
            Text(np.isPlaying ? "▶" : "⏸")
                .font(.caption2.weight(.bold))
        } else {
            Image(systemName: "music.note")
                .font(.caption2)
        }
    }

    private func washBackground(for np: WatchNowPlaying) -> some View {
        let wash = np.washColor
        return LinearGradient(
            colors: [
                Color(red: wash.r, green: wash.g, blue: wash.b),
                Color(red: wash.r * 0.88, green: wash.g * 0.88, blue: wash.b * 0.88),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }
}

// MARK: - Components

private struct WatchWidgetProgressBar: View {
    let nowPlaying: WatchNowPlaying

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !nowPlaying.isPlaying)) { timeline in
            let elapsed = nowPlaying.elapsed(at: timeline.date)
            let total = max(nowPlaying.duration, 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: max(geo.size.width * CGFloat(elapsed / total), 2))
                }
            }
            .frame(height: 3)
        }
    }
}

private struct WatchWidgetArtwork: View {
    let songId: String

    var body: some View {
        Group {
            if let url = WatchWidgetStore.artworkURL(for: songId),
               let data = try? Data(contentsOf: url),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    WatchWidgetColors.elevated
                    Image(systemName: "music.note")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }
}

private enum WatchWidgetColors {
    static let idleBackground = Color(red: 0.18, green: 0.16, blue: 0.15)
    static let elevated = Color(red: 0.22, green: 0.20, blue: 0.19)
}

#if DEBUG
extension WatchPlaybackPayload {
    static var placeholder: WatchPlaybackPayload {
        WatchPlaybackPayload(
            updatedAt: Date().timeIntervalSince1970,
            nowPlaying: WatchNowPlaying(
                songId: "demo",
                title: "Somewhere",
                artist: "Surf Mesa",
                isPlaying: true,
                elapsed: 42,
                duration: 180,
                capturedAt: Date().timeIntervalSince1970,
                rating: 4,
                isOutOfRotation: false,
                washR: 0.55, washG: 0.78, washB: 0.92),
            recents: [],
            playlists: [],
            artworkSongId: nil)
    }
}
#endif
