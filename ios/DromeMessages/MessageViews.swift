import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class TranscriptChrome: ObservableObject {
    @Published var track = ShareTrack(id: "", title: "", artist: "", album: "", coverArt: nil)
    @Published var cover: UIImage?
    @Published var canStream = false
    var onOpenInDrome: () -> Void = {}
}

struct TranscriptBubbleView: View {
    @ObservedObject var chrome: TranscriptChrome
    @Environment(\.openURL) private var openURL
    @ObservedObject var player: BubblePlayer

    private let artSize: CGFloat = 56

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if !chrome.track.id.isEmpty,
                   let url = URL(string: "drome://track/\(chrome.track.id)") {
                    openURL(url)
                }
                chrome.onOpenInDrome()
            } label: {
                HStack(spacing: 8) {
                    art
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chrome.track.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !chrome.track.artist.isEmpty {
                            Text(chrome.track.artist)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                    PlayingWaveform(isPlaying: player.isPlaying)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color(red: 0.24, green: 0.49, blue: 1))
            }
            .buttonStyle(.plain)
            .disabled(!chrome.canStream && !player.hasItem)
            .opacity((chrome.canStream || player.hasItem) ? 1 : 0.35)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    @ViewBuilder
    private var art: some View {
        Group {
            if let cover = chrome.cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(white: 0.18)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.white.opacity(0.5))
                    }
            }
        }
        .frame(width: artSize, height: artSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Six-glyph Drome mark. At rest it matches the logo; while playing the
/// pieces pulse like the splash animation.
struct PlayingWaveform: View {
    var isPlaying: Bool

    /// Same silhouette as `SplashScreenView` / LaunchLogo, scaled to the chip.
    private static let glyphs: [Glyph] = [
        .capsule(10),
        .circle(4.5),
        .capsule(16.5),
        .capsule(20),
        .capsule(10),
        .circle(3.8),
    ]
    private static let barWidth: CGFloat = 3.2
    private static let spacing: CGFloat = 1.6

    var body: some View {
        TimelineView(.animation(minimumInterval: isPlaying ? 1.0 / 24.0 : 10, paused: !isPlaying)) { timeline in
            let t = isPlaying ? timeline.date.timeIntervalSinceReferenceDate : 0
            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(Self.glyphs.indices, id: \.self) { i in
                    let scale = pulse(index: i, time: t)
                    Self.glyphs[i].shape(width: Self.barWidth, scale: scale)
                }
            }
            .frame(width: 28, height: 22)
        }
        .accessibilityHidden(true)
    }

    private func pulse(index: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else { return 1 }
        let phase = Double(index) * 1.6
        let wave = 0.55 + 0.45 * sin(time * 7.2 - phase)
        return max(0.35, wave)
    }

    private enum Glyph {
        case capsule(CGFloat)
        case circle(CGFloat)

        @ViewBuilder
        func shape(width: CGFloat, scale: CGFloat) -> some View {
            switch self {
            case .capsule(let height):
                Capsule()
                    .fill(Color.white)
                    .frame(width: width, height: height * scale)
            case .circle(let diameter):
                Circle()
                    .fill(Color.white)
                    .frame(width: diameter * scale, height: diameter * scale)
            }
        }
    }
}

@MainActor
final class BubblePlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var hasItem = false

    private let av = AVPlayer()
    private var endObserver: NSObjectProtocol?

    func load(url: URL?) {
        av.pause()
        isPlaying = false
        guard let url else {
            hasItem = false
            av.replaceCurrentItem(with: nil)
            return
        }
        hasItem = true
        av.replaceCurrentItem(with: AVPlayerItem(url: url))
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: av.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.av.seek(to: .zero)
                self?.isPlaying = false
            }
        }
    }

    func toggle() {
        guard hasItem else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        if isPlaying {
            av.pause()
            isPlaying = false
        } else {
            av.play()
            isPlaying = true
        }
    }

    func stop() {
        av.pause()
        isPlaying = false
    }
}

struct SongPickerView: View {
    @ObservedObject var model: SongPickerModel

    var body: some View {
        NavigationStack {
            Group {
                if model.client == nil {
                    ContentUnavailableView(
                        "Open Drome first",
                        systemImage: "music.note.house",
                        description: Text("Sign in to your library in Drome, then come back here to drop a playable card into the chat."))
                } else {
                    list
                }
            }
            .navigationTitle("Drome")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, prompt: "Search songs")
        }
        .preferredColorScheme(.dark)
    }

    private var list: some View {
        List {
            if !model.results.isEmpty {
                Section("Search") {
                    ForEach(model.results) { track in
                        row(track)
                    }
                }
            }
            if !model.recents.isEmpty {
                Section("Recently played") {
                    ForEach(model.recents) { track in
                        row(track)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.isWorking {
                ProgressView()
                    .scaleEffect(1.2)
            }
        }
    }

    private func row(_ track: ShareTrack) -> some View {
        Button {
            model.pick(track)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

@MainActor
final class SongPickerModel: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published var recents: [ShareTrack] = []
    @Published var results: [ShareTrack] = []
    @Published var isWorking = false

    let client: MessagesSubsonic?
    var onPick: ((ShareTrack) -> Void)?

    private var searchTask: Task<Void, Never>?

    init() {
        client = MessagesStore.client()
        recents = MessagesStore.recents()
    }

    func pick(_ track: ShareTrack) {
        onPick?(track)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, let client else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            let songs = await client.searchSongs(q)
            guard !Task.isCancelled else { return }
            results = songs
        }
    }
}
