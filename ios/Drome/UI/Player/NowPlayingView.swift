import SwiftUI

/// Spotify-style full-screen Now Playing.
/// All sizing is derived from the local GeometryReader so content always fits
/// the visible phone width (no UIScreen / overflow clipping).
struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var ratings: RatingsStore
    @EnvironmentObject private var rotation: RotationManager
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Pane = .song
    @State private var showQueue = false
    @State private var showAddToPlaylist = false
    @State private var isSeeking = false
    @State private var seekElapsed: Double = 0
    @State private var dismissDrag: CGFloat = 0
    @State private var flashMessage: String?
    @State private var artDragX: CGFloat = 0
    @State private var artSwipeAnimating = false
    @State private var showMoreSheet = false

    private enum Pane: String, CaseIterable {
        case song = "Song"
        case lyrics = "Lyrics"
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                background
                    .frame(width: width, height: height)
                    .clipped()

                VStack(spacing: 0) {
                    grabber
                        .gesture(dismissGesture)

                    panePicker
                        .frame(maxWidth: min(280, width - 48))
                        .padding(.bottom, 8)

                    Group {
                        switch tab {
                        case .song:
                            songPane(width: width, height: height - 72)
                        case .lyrics:
                            lyricsPane
                        }
                    }
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                }
                .frame(width: width, height: height)
            }
            .frame(width: width, height: height)
            .offset(y: max(0, dismissDrag))
        }
        .ignoresSafeArea(edges: .bottom)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .dromeSession(session)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let song = player.current?.song {
                NavigationStack {
                    AddToPlaylistView(song: song)
                        .dromeSession(session)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showAddToPlaylist = false }
                            }
                        }
                }
                .preferredColorScheme(.dark)
            }
        }
        .sheet(isPresented: $showMoreSheet) {
            if let song = player.current?.song {
                NowPlayingMoreSheet(song: song, isPresented: $showMoreSheet) {
                    showAddToPlaylist = true
                }
                .dromeSession(session)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .overlay(alignment: .top) {
            if let flashMessage {
                Text(flashMessage)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 56)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: flashMessage)
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    private var grabber: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.white.opacity(0.45))
                .frame(width: 36, height: 5)
            Text(player.context.map { "Playing from \($0.label)" } ?? " ")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
                .frame(height: 16)
                .opacity(player.context == nil ? 0 : 1)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var panePicker: some View {
        Picker("", selection: $tab) {
            ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var background: some View {
        ZStack {
            Color.black
            if let song = player.current?.song {
                RemoteImage(url: session.client.coverArtURL(
                    id: song.coverArt ?? song.albumId ?? song.id, size: 200))
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(0.4)
                    .allowsHitTesting(false)
            }
            LinearGradient(
                colors: [.black.opacity(0.1), .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { dismissDrag = max(0, $0.translation.height) }
            .onEnded { value in
                if value.translation.height > 140 {
                    dismiss()
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    dismissDrag = 0
                }
            }
    }

    // MARK: - Song pane

    private func songPane(width: CGFloat, height: CGFloat) -> some View {
        let horizontalPad: CGFloat = 24
        let contentWidth = max(0, width - horizontalPad * 2)
        let artSide = min(contentWidth, max(180, height * 0.38))

        return VStack(spacing: 0) {
            Spacer(minLength: 4)

            artwork(side: artSide, containerWidth: width)

            Spacer(minLength: 16)

            metadataBlock
                .frame(width: contentWidth, alignment: .leading)
                .id(player.current?.id)

            Spacer(minLength: 10)

            ratingBlock
                .frame(width: contentWidth, alignment: .leading)
                .id(player.current?.id)

            Spacer(minLength: 12)

            scrubber
                .frame(width: contentWidth)

            Spacer(minLength: 8)

            transport
                .frame(width: contentWidth)

            Spacer(minLength: 10)

            bottomBar
                .frame(width: contentWidth)
                .padding(.bottom, 24)
        }
        .frame(width: width, height: height)
    }

    private func artwork(side: CGFloat, containerWidth: CGFloat) -> some View {
        RemoteImage(url: coverURL)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
            .offset(x: artDragX)
            .opacity(1 - min(abs(artDragX) / (containerWidth * 0.9), 0.35))
            .gesture(artSwipeGesture(containerWidth: containerWidth))
            .animation(artSwipeAnimating ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.86),
                       value: artDragX)
            .id(player.current?.song.id ?? "none")
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.96)),
                removal: .opacity
            ))
            .frame(maxWidth: .infinity)
    }

    private func artSwipeGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 0.7 else { return }
                artDragX = value.translation.width
            }
            .onEnded { value in
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let threshold = min(110, containerWidth * 0.22)
                // Swipe left (finger moves left) → next track.
                let goNext = dx < -threshold || predicted < -threshold * 1.4
                // Swipe right → previous track (never restarts).
                let goPrevious = dx > threshold || predicted > threshold * 1.4

                if goNext {
                    artSwipeAnimating = true
                    withAnimation(.easeOut(duration: 0.18)) {
                        artDragX = -containerWidth
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        player.next()
                        artDragX = containerWidth * 0.35
                        artSwipeAnimating = false
                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.84)) {
                            artDragX = 0
                        }
                    }
                } else if goPrevious {
                    artSwipeAnimating = true
                    withAnimation(.easeOut(duration: 0.18)) {
                        artDragX = containerWidth
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        player.previous(preferPreviousTrack: true)
                        artDragX = -containerWidth * 0.35
                        artSwipeAnimating = false
                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.84)) {
                            artDragX = 0
                        }
                    }
                } else {
                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.85)) {
                        artDragX = 0
                    }
                }
            }
    }

    private var coverURL: URL? {
        guard let song = player.current?.song else { return nil }
        return session.client.coverArtURL(
            id: song.coverArt ?? song.albumId ?? song.id, size: 800)
    }

    private var metadataBlock: some View {
        let song = player.current?.song
        let title = cleaned(song?.title) ?? "Unknown Title"
        let artist = cleaned(song?.artist) ?? "Unknown Artist"

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                // Tap title → album (when we know the album id).
                if let song, let albumId = song.albumId, !albumId.isEmpty {
                    NavigationLink {
                        AlbumDetailView(
                            albumID: albumId,
                            placeholder: Album(
                                id: albumId,
                                name: song.album ?? title,
                                artist: song.artist,
                                artistId: song.artistId,
                                coverArt: song.coverArt,
                                songCount: nil, duration: nil, playCount: nil,
                                created: nil, year: nil, genre: nil, userRating: nil
                            )
                        )
                    } label: {
                        Text(title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                // Tap artist → artist page.
                if let song, let artistId = song.artistId, !artistId.isEmpty {
                    NavigationLink {
                        ArtistDetailView(artistID: artistId, placeholderName: artist)
                    } label: {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 48, alignment: .leading)

            if song != nil {
                Button {
                    showMoreSheet = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var ratingBlock: some View {
        Group {
            if let song = player.current?.song {
                StarRatingControl(rating: ratings.rating(for: song), size: 22) { newRating in
                    Task {
                        await ratings.setRating(newRating, for: song)
                        if newRating == 0 {
                            flash("Rating cleared")
                        } else {
                            flash("Rated \(newRating)★")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // Menu content moved to NowPlayingMoreSheet to avoid Menu flicker on playhead ticks.

    private var scrubber: some View {
        let total = stableDuration
        let displayed = isSeeking ? seekElapsed : min(max(0, player.elapsed), total)

        return VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { displayed },
                    set: { newValue in
                        seekElapsed = newValue
                        if !isSeeking { isSeeking = true }
                    }
                ),
                in: 0...max(total, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        if !isSeeking {
                            seekElapsed = min(max(0, player.elapsed), total)
                        }
                        isSeeking = true
                    } else {
                        let target = min(max(0, seekElapsed), total)
                        seekElapsed = target
                        player.seek(to: target)
                        // Hold the scrubbed time until AVPlayer finishes seeking.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            isSeeking = false
                        }
                    }
                }
            )
            .tint(.white)

            HStack {
                Text(Formatters.playbackTime(displayed))
                    .frame(minWidth: 40, alignment: .leading)
                Spacer()
                Text(Formatters.playbackTime(total))
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.7))
        }
        .frame(height: 44)
    }

    private var transport: some View {
        HStack {
            Button { player.cycleShuffleMode() } label: {
                Image(systemName: "shuffle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(shuffleColor)
                    .frame(width: 40, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if player.shuffleMode == .smart {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(DromeTheme.accent)
                                .offset(x: -2, y: 8)
                        }
                    }
            }

            Spacer(minLength: 0)

            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }

            Button { player.playPause() } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(ScaleButtonStyle())

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }

            Spacer(minLength: 0)

            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(player.repeatMode == .off ? Color.white.opacity(0.45) : DromeTheme.accent)
                    .frame(width: 40, height: 44)
            }
        }
        .frame(height: 68)
    }

    private var bottomBar: some View {
        HStack {
            AirPlayRoutePicker()
                .frame(width: 44, height: 44)
                .accessibilityLabel("Audio output")

            Spacer()

            Button {
                player.autoplayEnabled.toggle()
            } label: {
                Image(systemName: "infinity")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(player.autoplayEnabled ? DromeTheme.accent : Color.white.opacity(0.45))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Autoplay")

            Spacer()

            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Queue")
        }
        .frame(height: 44)
    }

    private var lyricsPane: some View {
        Group {
            if let song = player.current?.song {
                LyricsView(song: song)
            } else {
                EmptyStateView(title: "Nothing playing")
            }
        }
    }

    private var stableDuration: Double {
        let live = player.duration
        if live.isFinite, live > 0.5 { return live }
        if let meta = player.current?.song.duration, meta > 0 { return Double(meta) }
        return max(live, 0.1)
    }

    private var shuffleColor: Color {
        switch player.shuffleMode {
        case .off: return Color.white.opacity(0.45)
        case .smart, .random: return DromeTheme.accent
        }
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func flash(_ message: String) {
        flashMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if flashMessage == message { flashMessage = nil }
        }
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Stable action sheet for Now Playing — avoids SwiftUI `Menu` flicker while
/// the playhead publishes updates.
struct NowPlayingMoreSheet: View {
    let song: Song
    @Binding var isPresented: Bool
    var onAddToPlaylist: () -> Void

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var rotation: RotationManager
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let albumId = song.albumId, !albumId.isEmpty {
                        NavigationLink {
                            AlbumDetailView(
                                albumID: albumId,
                                placeholder: Album(
                                    id: albumId,
                                    name: song.album ?? song.title,
                                    artist: song.artist,
                                    artistId: song.artistId,
                                    coverArt: song.coverArt,
                                    songCount: nil, duration: nil, playCount: nil,
                                    created: nil, year: nil, genre: nil, userRating: nil
                                )
                            )
                        } label: {
                            Label("Open Album", systemImage: "square.stack")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    }

                    if let artistId = song.artistId, !artistId.isEmpty {
                        NavigationLink {
                            ArtistDetailView(artistID: artistId,
                                             placeholderName: song.artist ?? "Artist")
                        } label: {
                            Label("Open Artist", systemImage: "person.wave.2")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    }
                }

                Section {
                    Button {
                        isPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onAddToPlaylist()
                        }
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }
                    .listRowBackground(DromeTheme.elevated)

                    Button {
                        downloads.download([song])
                        isPresented = false
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .listRowBackground(DromeTheme.elevated)

                    if rotation.contains(song.id) {
                        Button {
                            Task {
                                await rotation.remove(song, manual: true)
                                isPresented = false
                            }
                        } label: {
                            Label("Remove from Out of Rotation", systemImage: "lock.open")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    } else {
                        Button {
                            Task {
                                await rotation.add(song, manual: true)
                                isPresented = false
                            }
                        } label: {
                            Label("Add to Out of Rotation", systemImage: "lock")
                        }
                        .listRowBackground(DromeTheme.elevated)
                    }

                    Button {
                        player.autoplayEnabled.toggle()
                        isPresented = false
                    } label: {
                        Label(player.autoplayEnabled ? "Turn Autoplay Off" : "Turn Autoplay On",
                              systemImage: "infinity")
                    }
                    .listRowBackground(DromeTheme.elevated)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DromeTheme.background)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

