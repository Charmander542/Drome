import SwiftUI

/// Synced lyrics with duet left/right alignment.
/// Layout stays fixed (same font size for every line) so highlighting and
/// auto-scroll never shove neighboring lines around.
struct LyricsView: View {
    let song: Song

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var document: LyricsDocument?
    @State private var isLoading = true
    @State private var error: String?
    @State private var activeIndex: Int = 0
    @State private var elapsedMs: Int = 0
    @State private var userScrolling = false
    @State private var reenableFollowTask: Task<Void, Never>?
    @State private var lastScrolledIndex: Int = -1

    private enum LineState {
        case past, active, upcoming
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView(message: "Loading lyrics…")
            } else if let error {
                ErrorStateView(message: error) { Task { await load(force: true) } }
            } else if let document, !document.lines.isEmpty {
                lyricsBody(document)
            } else {
                EmptyStateView(
                    title: "No lyrics yet",
                    systemImage: "text.quote",
                    message: "Checked Navidrome and LRCLIB. The background indexer fills this over time.")
            }
        }
        .task(id: song.id) {
            activeIndex = 0
            lastScrolledIndex = -1
            userScrolling = false
            await load(force: false)
        }
        // Drive the playhead from a background ticker so the ScrollView itself
        // isn't rebuilt 20×/sec inside a TimelineView.
        .background {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, _ in
                        tick()
                    }
                    .onAppear { tick() }
            }
        }
    }

    private func tick() {
        let ms = Int(player.accurateElapsed() * 1000)
        elapsedMs = ms
        guard let document, document.synced else { return }
        let idx = activeLineIndex(at: ms, in: document)
        if idx != activeIndex {
            activeIndex = idx
        }
    }

    private func lyricsBody(_ document: LyricsDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // Eager VStack (not Lazy) keeps measured heights stable for smooth scrollTo.
                VStack(spacing: 0) {
                    ForEach(Array(document.lines.enumerated()), id: \.element.id) { index, line in
                        KaraokeLine(
                            line: line,
                            state: lineState(index: index, active: activeIndex, synced: document.synced),
                            elapsedMs: elapsedMs
                        )
                        .id(line.id)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let start = line.startMs {
                                userScrolling = false
                                lastScrolledIndex = index
                                player.seek(to: Double(start) / 1000.0)
                                activeIndex = index
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 160)
                .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard !userScrolling else { return }
                        // Finger moving up through the list = reading ahead.
                        if value.translation.height < -8 || abs(value.translation.width) > 20 {
                            userScrolling = true
                            reenableFollowTask?.cancel()
                        }
                    }
                    .onEnded { _ in
                        guard userScrolling else { return }
                        reenableFollowTask?.cancel()
                        reenableFollowTask = Task {
                            try? await Task.sleep(nanoseconds: 2_800_000_000)
                            guard !Task.isCancelled else { return }
                            userScrolling = false
                            lastScrolledIndex = -1
                        }
                    }
            )
            .onChange(of: activeIndex) { _, newValue in
                scrollToActive(proxy: proxy, document: document, index: newValue, animated: true)
            }
            .onChange(of: document.lines.first?.id) { _, _ in
                lastScrolledIndex = -1
                scrollToActive(proxy: proxy, document: document, index: activeIndex, animated: false)
            }
            .onAppear {
                scrollToActive(proxy: proxy, document: document, index: activeIndex, animated: false)
            }
        }
        .overlay(alignment: .bottom) {
            Text(sourceLabel(document.source))
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.bottom, 10)
        }
    }

    private func scrollToActive(proxy: ScrollViewProxy, document: LyricsDocument, index: Int, animated: Bool) {
        guard document.synced, !userScrolling else { return }
        guard document.lines.indices.contains(index) else { return }
        guard index != lastScrolledIndex else { return }
        lastScrolledIndex = index
        let id = document.lines[index].id
        if animated {
            withAnimation(.interactiveSpring(response: 0.45, dampingFraction: 0.86, blendDuration: 0.2)) {
                proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.38))
            }
        } else {
            proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.38))
        }
    }

    private func lineState(index: Int, active: Int, synced: Bool) -> LineState {
        guard synced else { return .upcoming }
        if index < active { return .past }
        if index == active { return .active }
        return .upcoming
    }

    private func activeLineIndex(at elapsedMs: Int, in document: LyricsDocument) -> Int {
        var idx = 0
        for (i, line) in document.lines.enumerated() {
            guard let start = line.startMs else { continue }
            if start <= elapsedMs { idx = i } else { break }
        }
        return idx
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "navidrome": return "From your library"
        case "lrclib", "lrclib.v2": return "From LRCLIB"
        default: return ""
        }
    }

    private func load(force: Bool) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        if force {
            document = await session.lyricsService.refetch(for: song)
        } else {
            document = await session.lyricsService.lyrics(for: song)
        }
        if let document, document.synced {
            activeIndex = activeLineIndex(at: Int(player.accurateElapsed() * 1000), in: document)
        }
    }

    // MARK: - Line

    private struct KaraokeLine: View {
        let line: LRCParser.Line
        let state: LineState
        let elapsedMs: Int

        /// Same size for every line — only opacity / scale change, so neighbors don't jump.
        private let baseSize: CGFloat = 24

        var body: some View {
            VStack(alignment: stackAlignment, spacing: 3) {
                if let label = line.singerLabel {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(labelColor)
                        .opacity(state == .upcoming ? 0.35 : 1)
                }

                words
                    .frame(maxWidth: line.side == .group ? 300 : 270, alignment: frameAlignment)
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(.leading, line.side == .secondary ? 28 : 0)
            .padding(.trailing, line.side == .primary ? 28 : 0)
            // Scale does not affect layout — keeps scroll positions stable.
            .scaleEffect(state == .active ? 1.05 : 1.0, anchor: scaleAnchor)
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: state == .active)
        }

        @ViewBuilder
        private var words: some View {
            if line.words.isEmpty {
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: baseSize, weight: .semibold))
                    .foregroundStyle(baseColor)
                    .multilineTextAlignment(textAlignment)
            } else {
                WordFlowLayout(spacing: 7, lineSpacing: 5) {
                    ForEach(line.words) { word in
                        Text(word.text)
                            .font(.system(size: baseSize, weight: .semibold))
                            .foregroundStyle(color(for: word))
                    }
                }
            }
        }

        private var stackAlignment: HorizontalAlignment {
            switch line.side {
            case .primary: return .leading
            case .secondary: return .trailing
            case .group: return .center
            }
        }

        private var frameAlignment: Alignment {
            switch line.side {
            case .primary: return .leading
            case .secondary: return .trailing
            case .group: return .center
            }
        }

        private var scaleAnchor: UnitPoint {
            switch line.side {
            case .primary: return .leading
            case .secondary: return .trailing
            case .group: return .center
            }
        }

        private var textAlignment: TextAlignment {
            switch line.side {
            case .primary: return .leading
            case .secondary: return .trailing
            case .group: return .center
            }
        }

        private var labelColor: Color {
            state == .active ? DromeTheme.accent : Color.white.opacity(0.45)
        }

        private var baseColor: Color {
            switch state {
            case .active: return .white
            case .past: return Color.white.opacity(0.32)
            case .upcoming: return Color.white.opacity(0.26)
            }
        }

        private func color(for word: LRCParser.Word) -> Color {
            switch state {
            case .past:
                return Color.white.opacity(0.32)
            case .upcoming:
                return Color.white.opacity(0.26)
            case .active:
                if elapsedMs < word.startMs {
                    return Color.white.opacity(0.28)
                }
                if let end = word.endMs, elapsedMs >= end {
                    return Color.white.opacity(0.7)
                }
                return .white
            }
        }
    }
}

struct WordFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
