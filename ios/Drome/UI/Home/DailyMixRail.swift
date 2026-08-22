import SwiftUI

struct DailyMixRail: View {
    let mixes: [DailyMix]
    var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daily Mixes")
                .font(DromeTheme.headlineFont)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    if mixes.isEmpty && isLoading {
                        ForEach(0..<4, id: \.self) { _ in
                            DailyMixPlaceholder()
                        }
                    } else {
                        ForEach(mixes) { mix in
                            NavigationLink {
                                DailyMixDetailView(mix: mix)
                            } label: {
                                DailyMixCard(mix: mix)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct DailyMixCard: View {
    let mix: DailyMix
    var isPlaying: Bool = false

    @EnvironmentObject private var session: AppSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                collage
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                LinearGradient(
                    colors: [
                        Color(hex: mix.colors.first ?? "#2A9D8F").opacity(0.15),
                        Color(hex: mix.colors.last ?? "#1D3557").opacity(0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .allowsHitTesting(false)
                VStack {
                    Spacer()
                    HStack {
                        Text("\(mix.index)")
                            .font(.system(size: 42, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                        Spacer()
                    }
                    .padding(10)
                }
                if isPlaying {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 148, height: 148)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }

            Text(mix.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(mix.subtitle)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
        }
        .frame(width: 148, alignment: .leading)
        .hoverEffectDisabled()
    }

    private var collage: some View {
        let ids = mix.coverArtIds.isEmpty
            ? mix.songs.prefix(4).compactMap { $0.coverArt ?? $0.albumId ?? $0.id }
            : mix.coverArtIds
        return VStack(spacing: 1) {
            HStack(spacing: 1) {
                tile(ids, 0)
                tile(ids, 1)
            }
            HStack(spacing: 1) {
                tile(ids, 2)
                tile(ids, 3)
            }
        }
    }

    @ViewBuilder
    private func tile(_ ids: [String], _ index: Int) -> some View {
        let id = index < ids.count ? ids[index] : ids.first
        RemoteImage(url: session.artworkURL(id: id, size: 200))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DailyMixPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DromeTheme.elevated2)
                .frame(width: 148, height: 148)
            RoundedRectangle(cornerRadius: 3)
                .fill(DromeTheme.elevated2)
                .frame(width: 100, height: 12)
            RoundedRectangle(cornerRadius: 3)
                .fill(DromeTheme.elevated2)
                .frame(width: 80, height: 10)
        }
        .frame(width: 148, alignment: .leading)
        .redacted(reason: .placeholder)
    }
}
