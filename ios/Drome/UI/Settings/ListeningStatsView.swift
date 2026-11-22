import SwiftUI

struct ListeningStatsView: View {
    @EnvironmentObject private var session: AppSession
    @State private var period: ListeningStatsPeriod = .allTime
    @State private var stats: ListeningStats = .empty
    @State private var isLoading = true

    var body: some View {
        List {
            periodPicker
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(DromeTheme.elevated)
                }
            } else if stats.isEmpty {
                emptyState
            } else {
                summarySection
                rankedSection(title: "Top artists", items: stats.topArtists, placeholder: "person.fill")
                rankedSection(title: "Top albums", items: stats.topAlbums, placeholder: "square.stack.fill")
                topSongsSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Your listening")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("drome.listening.stats")
        .preferredColorScheme(.dark)
        .onAppear { reload() }
        .onChange(of: period) { _, _ in reload() }
    }

    private var periodPicker: some View {
        Section {
            Picker("Period", selection: $period) {
                ForEach(ListeningStatsPeriod.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("drome.listening.period")
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(DromeTheme.muted)
                Text("No plays yet")
                    .font(DromeTheme.rowTitle)
                    .foregroundStyle(.white)
                Text("Start listening and your stats will show up here.")
                    .font(DromeTheme.captionFont)
                    .foregroundStyle(DromeTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .listRowBackground(DromeTheme.elevated)
        }
    }

    private var summarySection: some View {
        Section {
            HStack(spacing: 0) {
                summaryCell(
                    value: hoursLabel,
                    label: "Hours"
                )
                Divider().frame(height: 36).overlay(DromeTheme.divider)
                summaryCell(
                    value: "\(stats.totalPlays)",
                    label: "Plays"
                )
                Divider().frame(height: 36).overlay(DromeTheme.divider)
                summaryCell(
                    value: "\(stats.activeDays)",
                    label: "Days"
                )
            }
            .padding(.vertical, 8)
            .listRowBackground(DromeTheme.elevated)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(hoursLabel) hours, \(stats.totalPlays) plays, \(stats.activeDays) days")
        } header: {
            Text("Summary")
        }
    }

    private func summaryCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(DromeTheme.captionFont)
                .foregroundStyle(DromeTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private var hoursLabel: String {
        let hours = stats.hoursListened
        if hours >= 10 {
            return String(format: "%.0f", hours.rounded())
        }
        if hours >= 1 {
            return String(format: "%.1f", hours)
        }
        // Show minutes when under an hour so the cell isn't "0.0".
        let minutes = max(0, stats.totalSeconds / 60)
        if minutes > 0 { return "\(minutes)m" }
        return "0"
    }

    private func rankedSection(
        title: String,
        items: [ListeningStats.RankedItem],
        placeholder: String
    ) -> some View {
        Section {
            if items.isEmpty {
                Text("Nothing here yet")
                    .foregroundStyle(DromeTheme.muted)
                    .listRowBackground(DromeTheme.elevated)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(DromeTheme.muted)
                            .frame(width: 22, alignment: .trailing)
                        RemoteImage(
                            url: session.artworkURL(id: item.coverArt, size: 96),
                            placeholderSymbol: placeholder
                        )
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(DromeTheme.rowTitle)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(DromeTheme.captionFont)
                                    .foregroundStyle(DromeTheme.muted)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text("\(item.playCount)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(DromeTheme.muted)
                    }
                    .listRowBackground(DromeTheme.elevated)
                    .accessibilityLabel("\(item.name), \(item.playCount) plays")
                }
            }
        } header: {
            Text(title)
        }
    }

    private var topSongsSection: some View {
        Section {
            if stats.topSongs.isEmpty {
                Text("Nothing here yet")
                    .foregroundStyle(DromeTheme.muted)
                    .listRowBackground(DromeTheme.elevated)
            } else {
                ForEach(Array(stats.topSongs.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(DromeTheme.muted)
                            .frame(width: 22, alignment: .trailing)
                        RemoteImage(url: session.artworkURL(for: entry.song, size: 96))
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.song.title)
                                .font(DromeTheme.rowTitle)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(entry.song.displayArtist)
                                .font(DromeTheme.captionFont)
                                .foregroundStyle(DromeTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("\(entry.playCount)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(DromeTheme.muted)
                    }
                    .listRowBackground(DromeTheme.elevated)
                    .accessibilityLabel("\(entry.song.title), \(entry.playCount) plays")
                }
            }
        } header: {
            Text("Top songs")
        }
    }

    private func reload() {
        isLoading = true
        let database = session.database
        let userKey = session.account.userKey
        let selected = period
        Task.detached(priority: .userInitiated) {
            let next = (try? database.listeningStats(userKey: userKey, period: selected)) ?? .empty
            await MainActor.run {
                stats = next
                isLoading = false
            }
        }
    }
}
