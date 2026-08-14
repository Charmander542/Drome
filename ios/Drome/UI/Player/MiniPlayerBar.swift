import SwiftUI

struct MiniPlayerBar: View {
    var onOpen: () -> Void

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var session: AppSession

    var body: some View {
        if let current = player.current {
            let title = current.song.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = (current.song.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            HStack(spacing: 12) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        RemoteImage(url: session.artworkURL(for: current.song, size: 120),
                                    holdImageWhileLoading: true)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(title.isEmpty ? "Unknown Title" : title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(artist.isEmpty ? "Unknown Artist" : (current.song.displayArtist.isEmpty ? artist : current.song.displayArtist))
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.65))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(current.id)

                        // Tiny progress so the bar feels alive without layout churn.
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(DromeTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 18, height: 18)
                            .opacity(clock.duration > 0 ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    player.playPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    }
            }
            .padding(.horizontal, 8)
            .id(current.id)
        }
    }

    private var progress: CGFloat {
        let total = clock.duration
        guard total.isFinite, total > 0 else { return 0 }
        return CGFloat(min(max(clock.elapsed / total, 0), 1))
    }
}
