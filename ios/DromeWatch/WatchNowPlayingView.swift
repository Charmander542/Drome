import SwiftUI
import UIKit

struct WatchNowPlayingView: View {
    @EnvironmentObject private var store: WatchSessionStore

    private var np: WatchNowPlaying? { store.payload.nowPlaying }

    var body: some View {
        Group {
            if let np {
                nowPlayingContent(np)
            } else {
                emptyContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func nowPlayingContent(_ np: WatchNowPlaying) -> some View {
        GeometryReader { geo in
            let artSize = min(geo.size.width * 0.70, 134)

            ZStack {
                WatchWashBackground(nowPlaying: np)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    ZStack(alignment: .bottom) {
                        artwork(for: np)
                            .id("\(np.songId)-\(store.artworkEpoch)")
                            .frame(width: artSize, height: artSize)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.62)],
                            startPoint: .center,
                            endPoint: .bottom)
                            .frame(width: artSize, height: artSize)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .allowsHitTesting(false)

                        VStack(spacing: 1) {
                            Text(np.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                            Text(np.artist)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .frame(width: artSize, height: artSize)
                    .frame(maxWidth: .infinity)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 14) {
                    TimelineView(.animation(minimumInterval: 0.5, paused: !np.isPlaying)) { timeline in
                        let elapsed = np.elapsed(at: timeline.date)
                        let progress = elapsed / max(np.duration, 1)

                        HStack(spacing: 20) {
                            WatchTransportButton(systemName: "backward.fill", size: 38) {
                                store.send(.previous)
                            }

                            WatchRadialPlayButton(
                                isPlaying: np.isPlaying,
                                progress: progress,
                                outerSize: 50,
                                innerSize: 40
                            ) {
                                store.send(.togglePlay)
                            }

                            WatchTransportButton(systemName: "forward.fill", size: 38) {
                                store.send(.next)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var emptyContent: some View {
        ZStack {
            Color(red: 0.18, green: 0.16, blue: 0.15)
            VStack(spacing: 10) {
                Image("LaunchLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                Text("Nothing playing")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(emptyMessage)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)

                Button("Sync with iPhone") {
                    store.refreshFromPhone()
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.8))
                .padding(.top, 4)
            }
            .padding(.horizontal, 12)
        }
    }

    private var emptyMessage: String {
        if !store.isActivated {
            return "Starting Watch link…"
        }
        if !store.isPhoneConnected {
            return "Install Drome on the paired iPhone, then open both apps"
        }
        if let error = store.lastSyncError {
            return error
        }
        if store.isReachable {
            return "Connected — start music in Drome on iPhone"
        }
        return "Open Drome on iPhone (keep both apps in foreground to sync)"
    }

    @ViewBuilder
    private func artwork(for np: WatchNowPlaying) -> some View {
        let _ = store.artworkEpoch
        if let data = store.artworkData(for: np.songId),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            let wash = np.washColor
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: wash.r, green: wash.g, blue: wash.b))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }
        }
    }
}

// MARK: - Controls

private struct WatchTransportButton: View {
    let systemName: String
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(Color.white.opacity(0.22))
                }
        }
        .buttonStyle(.plain)
    }
}

private struct WatchRadialPlayButton: View {
    let isPlaying: Bool
    let progress: Double
    var outerSize: CGFloat = 52
    var innerSize: CGFloat = 42
    let action: () -> Void

    private let ringWidth: CGFloat = 2.5

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.24), lineWidth: ringWidth)
                    .frame(width: outerSize, height: outerSize)

                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(
                        Color.white.opacity(0.95),
                        style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: outerSize, height: outerSize)

                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: innerSize, height: innerSize)

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .offset(x: isPlaying ? 0 : 1)
            }
            .frame(width: outerSize, height: outerSize)
        }
        .buttonStyle(.plain)
    }
}

private struct WatchWashBackground: View {
    let nowPlaying: WatchNowPlaying

    var body: some View {
        let wash = nowPlaying.washColor
        LinearGradient(
            colors: [
                Color(red: wash.r, green: wash.g, blue: wash.b),
                Color(
                    red: max(wash.r * 0.88, 0),
                    green: max(wash.g * 0.88, 0),
                    blue: max(wash.b * 0.88, 0)),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
        .ignoresSafeArea()
    }
}
