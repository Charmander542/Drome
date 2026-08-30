import WidgetKit
import SwiftUI
import UIKit
import AppIntents

struct RecentPlaysWidget: Widget {
    let kind = "RecentPlaysWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentPlaysProvider()) { entry in
            RecentPlaysWidgetView(entry: entry)
        }
        .configurationDisplayName("Recently Played")
        .description("See what's playing and jump back into recent listens.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct RecentPlaysEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetRecentSnapshot
}

struct RecentPlaysProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentPlaysEntry {
        RecentPlaysEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentPlaysEntry) -> Void) {
        completion(RecentPlaysEntry(date: Date(), snapshot: WidgetRecentStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentPlaysEntry>) -> Void) {
        let snap = WidgetRecentStore.load()
        let now = Date()
        var entries = [RecentPlaysEntry(date: now, snapshot: snap)]

        if snap.showsLiveWidget(at: now), let np = snap.nowPlaying {
            if np.isPlaying, np.duration > 0 {
                for step in 1..<48 {
                    let date = now.addingTimeInterval(Double(step * 15))
                    entries.append(RecentPlaysEntry(date: date, snapshot: snap))
                }
            } else if let paused = np.pausedSince {
                let flip = Date(timeIntervalSince1970: paused + WidgetRecentSnapshot.pausedIdleInterval)
                if flip > now {
                    entries.append(RecentPlaysEntry(date: flip, snapshot: snap))
                }
            }
        }

        if snap.nowPlaying != nil {
            let stale = Date(timeIntervalSince1970: snap.updatedAt + WidgetRecentSnapshot.staleSyncInterval)
            if stale > now {
                entries.append(RecentPlaysEntry(date: stale, snapshot: snap))
            }
        }

        entries.sort { $0.date < $1.date }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct RecentPlaysWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentPlaysEntry

    private var showsLive: Bool {
        entry.snapshot.showsLiveWidget(at: entry.date)
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                SmallCoverView(
                    artworkFile: entry.snapshot.nowPlaying?.artworkFile
                        ?? entry.snapshot.items.first?.artworkFile,
                    deepLink: smallDeepLink(entry.snapshot),
                    title: entry.snapshot.nowPlaying?.title ?? entry.snapshot.items.first?.title,
                    subtitle: entry.snapshot.nowPlaying?.artist ?? entry.snapshot.items.first?.subtitle,
                    isPlaying: entry.snapshot.nowPlaying?.isPlaying ?? false,
                    hasLiveTransport: showsLive && entry.snapshot.nowPlaying != nil)
            case .systemMedium:
                if showsLive, let np = entry.snapshot.nowPlaying {
                    MediumPlayingView(nowPlaying: np)
                } else {
                    MediumIdleView(items: entry.snapshot.items)
                }
            case .systemLarge:
                if showsLive, let np = entry.snapshot.nowPlaying {
                    LargePlayingView(nowPlaying: np, items: Array(entry.snapshot.items.prefix(8)))
                } else {
                    LargeCompactRecentsView(items: entry.snapshot.items)
                }
            default:
                MediumIdleView(items: entry.snapshot.items)
            }
        }
        .containerBackground(for: .widget) {
            if showsLive, let np = entry.snapshot.nowPlaying {
                WashBackground(nowPlaying: np)
            } else {
                WidgetColors.idleBackground
            }
        }
    }

    private func smallDeepLink(_ snapshot: WidgetRecentSnapshot) -> String? {
        if let np = snapshot.nowPlaying {
            return "drome://track/\(np.songId)"
        }
        return snapshot.items.first?.deepLink
    }
}

// MARK: - Medium playing (Spotify-style)

private enum WidgetIdleMetrics {
    static let compactArt: CGFloat = 48
    static let columnSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 28
    static let verticalPadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 10
    static let captionHeight: CGFloat = 14

    /// One size for every idle tile — halfway between 48pt and a full grid cell, capped so hero + grid fit.
    static func artSize(width: CGFloat, height: CGFloat, columnCount: Int) -> CGFloat {
        let columns = CGFloat(max(columnCount, 1))
        let innerWidth = width - horizontalPadding
        let innerHeight = height - verticalPadding
        let gaps = columnSpacing * (columns - 1)
        let gridCell = floor((innerWidth - gaps) / columns)
        let preferred = floor((compactArt + gridCell) / 2)
        let maxByHeight = floor((innerHeight - sectionSpacing - captionHeight) / 2)
        return min(preferred, maxByHeight, gridCell)
    }
}

private struct MediumPlayingView: View {
    let nowPlaying: WidgetNowPlaying

    var body: some View {
        GeometryReader { geo in
            let artSide = min(geo.size.height - 24, geo.size.width * 0.40)
            HStack(spacing: 10) {
                WidgetArtwork(file: nowPlaying.artworkFile, cornerRadius: WidgetColors.albumCornerRadius)
                    .frame(width: artSide, height: artSide)

                VStack(alignment: .leading, spacing: 0) {
                    DromeBarMark(size: 16, color: WidgetPalette.foreground(for: nowPlaying))
                        .padding(.bottom, 6)

                    Text(nowPlaying.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(WidgetPalette.foreground(for: nowPlaying))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    Text(nowPlaying.artist)
                        .font(.subheadline)
                        .foregroundStyle(WidgetPalette.secondaryForeground(for: nowPlaying))
                        .lineLimit(1)
                        .padding(.top, 2)

                    Spacer(minLength: 6)

                    LiveProgressBar(nowPlaying: nowPlaying)
                        .padding(.bottom, 10)

                    PlaybackControls(nowPlaying: nowPlaying, iconSize: 20, spacing: 28)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
        }
    }
}

// MARK: - Small (always full-bleed art)

private struct SmallCoverView: View {
    let artworkFile: String?
    let deepLink: String?
    var title: String?
    var subtitle: String?
    var isPlaying: Bool
    var hasLiveTransport: Bool

    private var livePlaying: Bool {
        WidgetRecentStore.load().nowPlaying?.isPlaying ?? isPlaying
    }

    var body: some View {
        ZStack {
            if let deepLink, let url = URL(string: deepLink), !hasLiveTransport {
                Link(destination: url) { artworkLayer }
            } else {
                artworkLayer
            }

            VStack(spacing: 0) {
                HStack {
                    DromeBarMark(size: 15, color: .white)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    Spacer()
                }
                .padding(10)

                Spacer()

                if let title {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            if let subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.78))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if hasLiveTransport {
                            Button(intent: WidgetTogglePlayIntent()) {
                                Image(systemName: livePlaying ? "pause.fill" : "play.fill")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else if let deepLink, let url = URL(string: deepLink) {
                            Link(destination: url) {
                                Image(systemName: "play.fill")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                    .padding(12)
                    .background {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom)
                    }
                }
            }
        }
    }

    private var artworkLayer: some View {
        WidgetArtwork(file: artworkFile, cornerRadius: 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Medium idle (Spotify-style recents)

private struct MediumIdleView: View {
    let items: [WidgetRecentItem]

    private let gridColumns = 5

    var body: some View {
        GeometryReader { geo in
            let artSize = WidgetIdleMetrics.artSize(
                width: geo.size.width, height: geo.size.height, columnCount: gridColumns)
            let columns = Array(repeating: GridItem(.fixed(artSize), spacing: 8), count: gridColumns)
            VStack(alignment: .leading, spacing: 10) {
                RecentHeroHeader(item: items.first, artSize: artSize)

                if items.isEmpty {
                    EmptyWidgetView(message: "Play something in Drome")
                        .frame(maxHeight: .infinity)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(Array(items.dropFirst().prefix(gridColumns))) { item in
                            RecentSquareTile(item: item, showTitle: true, artSize: artSize)
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Large compact recents (medium-style header + grid)

private struct LargeCompactRecentsView: View {
    let items: [WidgetRecentItem]

    var body: some View {
        GeometryReader { geo in
            let artSize = WidgetIdleMetrics.artSize(
                width: geo.size.width, height: geo.size.height, columnCount: 4)
            let columns = Array(repeating: GridItem(.fixed(artSize), spacing: 8), count: 4)
            VStack(alignment: .leading, spacing: 10) {
                RecentHeroHeader(item: items.first, artSize: artSize)

                if items.isEmpty {
                    EmptyWidgetView(message: "Recently played shows up here")
                        .frame(maxHeight: .infinity)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(Array(items.dropFirst().prefix(12))) { item in
                            RecentSquareTile(item: item, showTitle: true, artSize: artSize)
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct RecentHeroHeader: View {
    let item: WidgetRecentItem?
    var artSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let item {
                Link(destination: URL(string: item.deepLink)!) {
                    HStack(alignment: .top, spacing: 10) {
                        WidgetArtwork(file: item.artworkFile, cornerRadius: WidgetColors.albumCornerRadius)
                            .frame(width: artSize, height: artSize)
                        Text(item.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            DromeBarMark(size: 18, color: .white)
        }
    }
}

private struct RecentSquareTile: View {
    let item: WidgetRecentItem
    var showTitle: Bool = false
    var artSize: CGFloat

    var body: some View {
        Link(destination: URL(string: item.deepLink)!) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetArtwork(file: item.artworkFile, cornerRadius: WidgetColors.albumCornerRadius)
                    .frame(width: artSize, height: artSize)
                if showTitle {
                    Text(item.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }
}

// MARK: - Large playing (now playing + 2×4 recents)

private struct LargePlayingView: View {
    let nowPlaying: WidgetNowPlaying
    let items: [WidgetRecentItem]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                WidgetArtwork(file: nowPlaying.artworkFile, cornerRadius: WidgetColors.albumCornerRadius)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    DromeBarMark(size: 13, color: WidgetPalette.foreground(for: nowPlaying))
                    Text(nowPlaying.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(WidgetPalette.foreground(for: nowPlaying))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(nowPlaying.artist)
                        .font(.caption)
                        .foregroundStyle(WidgetPalette.secondaryForeground(for: nowPlaying))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            LiveProgressBar(nowPlaying: nowPlaying)

            PlaybackControls(nowPlaying: nowPlaying, iconSize: 18, spacing: 32)
                .frame(maxWidth: .infinity)

            if !items.isEmpty {
                Text("Recently played")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetPalette.secondaryForeground(for: nowPlaying))

                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        LargePlayingRecentTile(item: item, nowPlaying: nowPlaying)
                    }
                }
            }
        }
        .padding(14)
    }
}

private struct LargePlayingRecentTile: View {
    let item: WidgetRecentItem
    let nowPlaying: WidgetNowPlaying

    var body: some View {
        Link(destination: URL(string: item.deepLink)!) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetArtwork(file: item.artworkFile, cornerRadius: WidgetColors.albumCornerRadius)
                    .aspectRatio(1, contentMode: .fill)
                Text(item.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WidgetPalette.foreground(for: nowPlaying))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

// MARK: - Controls + progress

private struct PlaybackControls: View {
    let nowPlaying: WidgetNowPlaying
    var iconSize: CGFloat = 18
    var spacing: CGFloat = 28

    private var livePlaying: Bool {
        WidgetRecentStore.load().nowPlaying?.isPlaying ?? nowPlaying.isPlaying
    }

    var body: some View {
        HStack(spacing: spacing) {
            Button(intent: WidgetPreviousTrackIntent()) {
                Image(systemName: "backward.fill")
                    .font(.system(size: iconSize, weight: .semibold))
            }
            .buttonStyle(.plain)

            Button(intent: WidgetTogglePlayIntent()) {
                Image(systemName: livePlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: iconSize + 6, weight: .bold))
            }
            .buttonStyle(.plain)

            Button(intent: WidgetNextTrackIntent()) {
                Image(systemName: "forward.fill")
                    .font(.system(size: iconSize, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(WidgetPalette.foreground(for: nowPlaying))
    }
}

private struct LiveProgressBar: View {
    let nowPlaying: WidgetNowPlaying

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !nowPlaying.isPlaying)) { timeline in
            let live = WidgetRecentStore.load().nowPlaying ?? nowPlaying
            let elapsed = live.elapsed(at: timeline.date)
            let total = max(live.duration, 1)
            let fg = WidgetPalette.foreground(for: live)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(fg.opacity(0.22))
                    Capsule()
                        .fill(fg.opacity(0.92))
                        .frame(width: max(geo.size.width * CGFloat(elapsed / total), 4))
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - Shared pieces

private struct RecentItemTile: View {
    let item: WidgetRecentItem
    var showSubtitle: Bool = true
    var artCornerRadius: CGFloat = 6
    var titleColor: Color = .white
    var subtitleColor: Color = WidgetColors.muted

    var body: some View {
        Link(destination: URL(string: item.deepLink)!) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetArtwork(file: item.artworkFile, cornerRadius: artCornerRadius)
                    .aspectRatio(1, contentMode: .fit)
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if showSubtitle {
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct WashBackground: View {
    let nowPlaying: WidgetNowPlaying

    private var wash: (r: Double, g: Double, b: Double) {
        if let file = nowPlaying.artworkFile, !file.isEmpty {
            return WidgetArtWash.fromArtworkFile(file)
        }
        return nowPlaying.washColor
    }

    var body: some View {
        let c = wash
        LinearGradient(
            colors: [
                Color(red: c.r, green: c.g, blue: c.b),
                Color(
                    red: max(c.r * 0.92, 0),
                    green: max(c.g * 0.92, 0),
                    blue: max(c.b * 0.92, 0)),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }
}

private enum WidgetPalette {
    static func foreground(for np: WidgetNowPlaying) -> Color {
        np.prefersDarkForeground ? .black : .white
    }

    static func secondaryForeground(for np: WidgetNowPlaying) -> Color {
        np.prefersDarkForeground ? .black.opacity(0.58) : .white.opacity(0.74)
    }
}

private struct WidgetArtwork: View {
    let file: String?
    var cornerRadius: CGFloat = 6

    var body: some View {
        Group {
            if let url = WidgetRecentStore.artworkURL(for: file),
               let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    WidgetColors.elevated
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(WidgetColors.muted)
                }
            }
        }
        .id(file ?? "placeholder")
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct EmptyWidgetView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(WidgetColors.muted)
            Text(message)
                .font(.caption)
                .foregroundStyle(WidgetColors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum WidgetColors {
    static let albumCornerRadius: CGFloat = 16
    static let idleBackground = Color(red: 0.18, green: 0.16, blue: 0.15)
    static let elevated = Color(red: 0.22, green: 0.20, blue: 0.19)
    static let muted = Color(white: 0.62)
}

#if DEBUG
extension WidgetRecentSnapshot {
    static var placeholder: WidgetRecentSnapshot {
        WidgetRecentSnapshot(
            updatedAt: Date().timeIntervalSince1970,
            items: [
                WidgetRecentItem(
                    id: "playlist:1", title: "Road Trip", subtitle: "Playlist",
                    artworkFile: nil, resumeKey: "playlist:1",
                    deepLink: "drome://play?resume=playlist:1&entry=playlist:1", rating: 0),
                WidgetRecentItem(
                    id: "album:2", title: "Somewhere", subtitle: "Surf Mesa",
                    artworkFile: nil, resumeKey: "album:2",
                    deepLink: "drome://play?resume=album:2&entry=album:2", rating: 5),
                WidgetRecentItem(
                    id: "playlist:3", title: "Chill", subtitle: "Playlist",
                    artworkFile: nil, resumeKey: "playlist:3",
                    deepLink: "drome://play?resume=playlist:3&entry=playlist:3", rating: 0),
                WidgetRecentItem(
                    id: "album:4", title: "Golden Hour", subtitle: "Kacey Musgraves",
                    artworkFile: nil, resumeKey: "album:4",
                    deepLink: "drome://play?resume=album:4&entry=album:4", rating: 5),
                WidgetRecentItem(
                    id: "playlist:5", title: "Focus", subtitle: "Mix",
                    artworkFile: nil, resumeKey: "mix:focus",
                    deepLink: "drome://play?resume=mix:focus&entry=mix:focus", rating: 0),
                WidgetRecentItem(
                    id: "album:6", title: "Blonde", subtitle: "Frank Ocean",
                    artworkFile: nil, resumeKey: "album:6",
                    deepLink: "drome://play?resume=album:6&entry=album:6", rating: 5),
                WidgetRecentItem(
                    id: "playlist:7", title: "Hype", subtitle: "Mix",
                    artworkFile: nil, resumeKey: "mix:hype",
                    deepLink: "drome://play?resume=mix:hype&entry=mix:hype", rating: 0),
                WidgetRecentItem(
                    id: "album:8", title: "Random Access", subtitle: "Daft Punk",
                    artworkFile: nil, resumeKey: "album:8",
                    deepLink: "drome://play?resume=album:8&entry=album:8", rating: 4),
            ],
            nowPlaying: WidgetNowPlaying(
                songId: "demo",
                title: "Somewhere",
                artist: "Surf Mesa ft. Gus Dapperton",
                artworkFile: nil,
                isPlaying: true,
                elapsed: 42,
                duration: 180,
                capturedAt: Date().timeIntervalSince1970,
                rating: 4,
                isOutOfRotation: false,
                washR: 0.55, washG: 0.78, washB: 0.92,
                pausedSince: nil))
    }
}

#Preview(as: .systemSmall) {
    RecentPlaysWidget()
} timeline: {
    RecentPlaysEntry(date: .now, snapshot: .placeholder)
}

#Preview(as: .systemMedium) {
    RecentPlaysWidget()
} timeline: {
    RecentPlaysEntry(date: .now, snapshot: .placeholder)
}

#Preview(as: .systemLarge) {
    RecentPlaysWidget()
} timeline: {
    RecentPlaysEntry(date: .now, snapshot: .placeholder)
}
#endif
