import SwiftUI

struct DailyMixRail: View {
    let mixes: [DailyMix]
    var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily Mixes")
                    .font(DromeTheme.headlineFont)
                Text("Made for you from ratings, plays, and similar artists — refreshes daily.")
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if mixes.isEmpty && isLoading {
                        ForEach(0..<4, id: \.self) { _ in
                            DailyMixPlaceholder()
                        }
                    } else if mixes.isEmpty {
                        Text("Couldn’t load Daily Mixes. Check Settings → Wishlist companion and make sure the server is running.")
                            .font(.caption)
                            .foregroundStyle(DromeTheme.muted)
                            .frame(width: 220, alignment: .leading)
                    } else {
                        ForEach(mixes) { mix in
                            NavigationLink {
                                DailyMixDetailView(mix: mix)
                            } label: {
                                DailyMixCard(mix: mix)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 148, alignment: .topLeading)
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

    private var cover: some View {
        Group {
            if let first = mix.songs.first {
                let coverId = mix.coverArtIds.first
                    ?? first.artistId
                    ?? first.coverArt
                    ?? first.albumId
                    ?? first.id
                RemoteImage(url: session.artworkURL(id: coverId, size: 300),
                            placeholderSymbol: "music.note")
            } else {
                Color(DromeTheme.elevated2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                cover
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
            .aspectRatio(1, contentMode: .fit)
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
        .hoverEffectDisabled()
    }
}

private struct DailyMixPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DromeTheme.elevated2)
                .aspectRatio(1, contentMode: .fit)
            RoundedRectangle(cornerRadius: 3)
                .fill(DromeTheme.elevated2)
                .frame(width: 100, height: 12)
            RoundedRectangle(cornerRadius: 3)
                .fill(DromeTheme.elevated2)
                .frame(width: 80, height: 10)
        }
        .frame(width: 148, alignment: .topLeading)
        .redacted(reason: .placeholder)
    }
}
