import SwiftUI

/// Settings ▸ Made for you — which on-device mixes Home builds, length, and left-out genres.
struct SettingsMadeForYouView: View {
    @EnvironmentObject private var session: AppSession

    @State private var daypart = MadeForYouPreferences.daypartEnabled
    @State private var discovery = MadeForYouPreferences.discoveryEnabled
    @State private var genreMixes = MadeForYouPreferences.genreMixesEnabled
    @State private var nonstop = MadeForYouPreferences.nonstopEnabled
    @State private var length = MadeForYouPreferences.length
    @State private var vibeOn: [MoodVibe: Bool] = [:]
    @State private var excluded: [String] = []
    @State private var preferred: [String] = []
    @State private var allGenres: [String] = []
    @State private var signatureOnAppear = ""
    @State private var isRebuilding = false

    var body: some View {
        List {
            Section {
                Toggle("Time of day mix", isOn: $daypart)
                    .tint(DromeTheme.accent)
                    .onChange(of: daypart) { _, on in
                        MadeForYouPreferences.daypartEnabled = on
                    }
                ForEach(MadeForYouPreferences.shelfVibes) { vibe in
                    Toggle(vibe.title, isOn: vibeBinding(vibe))
                        .tint(DromeTheme.accent)
                }
                Toggle("Genre mixes", isOn: $genreMixes)
                    .tint(DromeTheme.accent)
                    .onChange(of: genreMixes) { _, on in
                        MadeForYouPreferences.genreMixesEnabled = on
                    }
                Toggle("Nonstop", isOn: $nonstop)
                    .tint(DromeTheme.accent)
                    .onChange(of: nonstop) { _, on in
                        MadeForYouPreferences.nonstopEnabled = on
                    }
                Toggle("Fresh finds", isOn: $discovery)
                    .tint(DromeTheme.accent)
                    .onChange(of: discovery) { _, on in
                        MadeForYouPreferences.discoveryEnabled = on
                    }
            } header: {
                Text("Mixes")
            } footer: {
                Text("Morning through late night follow the clock. Genre mixes and Nonstop follow what you play. Vibes use the same engine as Vibe Tuner.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                ForEach(preferred, id: \.self) { genre in
                    HStack {
                        Text(genre)
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            setPreferred(genre, false)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DromeTheme.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(genre)")
                    }
                }
                Menu {
                    ForEach(allGenres.filter { genre in
                        !preferred.contains { $0.caseInsensitiveCompare(genre) == .orderedSame }
                    }, id: \.self) { genre in
                        Button(genre) { setPreferred(genre, true) }
                    }
                } label: {
                    Label(
                        preferred.isEmpty ? "Pick genres (optional)" : "Add a genre",
                        systemImage: "plus.circle")
                        .foregroundStyle(DromeTheme.accent)
                }
                .disabled(allGenres.isEmpty || preferred.count >= 4)
            } header: {
                Text("Genre mixes")
            } footer: {
                Text("Empty means Drome follows your top listened genres. Up to four.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                ForEach(excluded, id: \.self) { genre in
                    HStack {
                        Text(genre)
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            setExcluded(genre, false)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DromeTheme.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(genre)")
                    }
                }
                Menu {
                    ForEach(allGenres.filter { genre in
                        !excluded.contains { $0.caseInsensitiveCompare(genre) == .orderedSame }
                    }, id: \.self) { genre in
                        Button(genre) { setExcluded(genre, true) }
                    }
                } label: {
                    Label("Leave out a genre", systemImage: "minus.circle")
                        .foregroundStyle(DromeTheme.accent)
                }
                .disabled(allGenres.isEmpty)
            } header: {
                Text("Left out")
            } footer: {
                Text("Songs tagged with these genres never land on a Made for you card.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Picker("Songs per mix", selection: $length) {
                    Text("25").tag(25)
                    Text("40").tag(40)
                    Text("50").tag(50)
                }
                .pickerStyle(.segmented)
                .onChange(of: length) { _, value in
                    MadeForYouPreferences.length = value
                }
            } header: {
                Text("Length")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Button {
                    Task { await rebuildNow() }
                } label: {
                    HStack {
                        Text("Make new mixes now")
                            .foregroundStyle(DromeTheme.accent)
                        Spacer()
                        if isRebuilding { ProgressView() }
                    }
                }
                .disabled(isRebuilding || !MadeForYouPreferences.anyShelfEnabled)
            } footer: {
                Text("Mixes rebuild about every eight hours, and when the time of day changes.")
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Made for you")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadGenres() }
        .onAppear {
            hydrate()
            signatureOnAppear = MadeForYouPreferences.signature
        }
        .onDisappear {
            persistVibes()
            guard MadeForYouPreferences.signature != signatureOnAppear else { return }
            Task { _ = await MadeForYouStore.regenerate(session: session) }
        }
    }

    private func hydrate() {
        daypart = MadeForYouPreferences.daypartEnabled
        discovery = MadeForYouPreferences.discoveryEnabled
        genreMixes = MadeForYouPreferences.genreMixesEnabled
        nonstop = MadeForYouPreferences.nonstopEnabled
        length = MadeForYouPreferences.length
        vibeOn = Dictionary(
            uniqueKeysWithValues: MadeForYouPreferences.shelfVibes.map {
                ($0, MadeForYouPreferences.vibeEnabled($0))
            })
        excluded = MadeForYouPreferences.excludedGenres.sorted()
        preferred = MadeForYouPreferences.preferredGenres
    }

    private func vibeBinding(_ vibe: MoodVibe) -> Binding<Bool> {
        Binding(
            get: { vibeOn[vibe] ?? MadeForYouPreferences.vibeEnabled(vibe) },
            set: { on in
                vibeOn[vibe] = on
                MadeForYouPreferences.setVibeEnabled(vibe, on)
            })
    }

    private func persistVibes() {
        for vibe in MadeForYouPreferences.shelfVibes {
            MadeForYouPreferences.setVibeEnabled(vibe, vibeOn[vibe] ?? false)
        }
        MadeForYouPreferences.daypartEnabled = daypart
        MadeForYouPreferences.discoveryEnabled = discovery
        MadeForYouPreferences.genreMixesEnabled = genreMixes
        MadeForYouPreferences.nonstopEnabled = nonstop
        MadeForYouPreferences.length = length
        MadeForYouPreferences.excludedGenres = Set(excluded.map { $0.lowercased() })
        MadeForYouPreferences.preferredGenres = preferred
    }

    private func setExcluded(_ genre: String, _ on: Bool) {
        var next = Set(excluded.map { $0.lowercased() })
        if on {
            next.insert(genre.lowercased())
        } else {
            next.remove(genre.lowercased())
        }
        // Genres that differ only in case share a key — keep the first spelling.
        let display = Dictionary(
            allGenres.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { a, _ in a })
        excluded = next.sorted().map { display[$0] ?? $0 }
        MadeForYouPreferences.excludedGenres = next
    }

    private func setPreferred(_ genre: String, _ on: Bool) {
        var next = preferred
        if on {
            guard next.count < 4,
                  !next.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame })
            else { return }
            next.append(genre)
        } else {
            next.removeAll { $0.caseInsensitiveCompare(genre) == .orderedSame }
        }
        preferred = next
        MadeForYouPreferences.preferredGenres = next
    }

    private func loadGenres() async {
        let genres = (try? await session.client.genres()) ?? []
        allGenres = genres.map(\.value)
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func rebuildNow() async {
        isRebuilding = true
        defer { isRebuilding = false }
        persistVibes()
        _ = await MadeForYouStore.regenerate(session: session)
        signatureOnAppear = MadeForYouPreferences.signature
    }
}
