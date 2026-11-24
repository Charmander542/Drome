import SwiftUI

/// Settings ▸ Made for you — which on-device mixes Home builds, length, and left-out genres.
struct SettingsMadeForYouView: View {
    @EnvironmentObject private var session: AppSession

    @State private var daypart = MadeForYouPreferences.daypartEnabled
    @State private var discovery = MadeForYouPreferences.discoveryEnabled
    @State private var length = MadeForYouPreferences.length
    @State private var vibeOn: [MoodVibe: Bool] = [:]
    @State private var excluded: [String] = []
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
                Toggle("Fresh finds", isOn: $discovery)
                    .tint(DromeTheme.accent)
                    .onChange(of: discovery) { _, on in
                        MadeForYouPreferences.discoveryEnabled = on
                    }
            } header: {
                Text("Mixes")
            } footer: {
                Text("Morning, afternoon, evening, and late night follow the clock. Vibes use the same engine as Vibe Tuner.")
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
        length = MadeForYouPreferences.length
        vibeOn = Dictionary(
            uniqueKeysWithValues: MadeForYouPreferences.shelfVibes.map {
                ($0, MadeForYouPreferences.vibeEnabled($0))
            })
        excluded = MadeForYouPreferences.excludedGenres.sorted()
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
        MadeForYouPreferences.length = length
        MadeForYouPreferences.excludedGenres = Set(excluded.map { $0.lowercased() })
    }

    private func setExcluded(_ genre: String, _ on: Bool) {
        var next = Set(excluded.map { $0.lowercased() })
        if on {
            next.insert(genre.lowercased())
        } else {
            next.remove(genre.lowercased())
        }
        // Keep display casing from the server list when possible.
        let display = Dictionary(
            uniqueKeysWithValues: allGenres.map { ($0.lowercased(), $0) })
        excluded = next.sorted().map { display[$0] ?? $0 }
        MadeForYouPreferences.excludedGenres = next
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
