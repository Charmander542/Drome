import SwiftUI

/// SubSonify-style Playback page: Autoplay, Transitions, Equalizer, ReplayGain, lyrics.
struct SettingsPlaybackView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var lyricsIndexer: LyricsIndexer

    var openEqualizer: () -> Void

    var body: some View {
        List {
            Section {
                Toggle(isOn: $player.autoplayEnabled) {
                    Text("Autoplay")
                }
                .tint(DromeTheme.accent)
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Toggle(isOn: Binding(
                    get: { AudioFXPreferences.mixTransitionMode != .off },
                    set: { on in
                        AudioFXPreferences.mixTransitionMode = on ? .soft : .off
                    }
                )) {
                    Text("Crossfade")
                }
                .tint(DromeTheme.accent)

                Toggle(isOn: Binding(
                    get: { AudioFXPreferences.mixTransitionMode == .beatAligned },
                    set: { on in
                        if on {
                            AudioFXPreferences.mixTransitionMode = .beatAligned
                        } else if AudioFXPreferences.mixTransitionMode == .beatAligned {
                            AudioFXPreferences.mixTransitionMode = .soft
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mix transitions")
                        Text("Automatically mixes one song into the next with a smart crossfade.")
                            .font(.caption)
                            .foregroundStyle(DromeTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(DromeTheme.accent)
                .disabled(AudioFXPreferences.mixTransitionMode == .off)

                if AudioFXPreferences.mixTransitionMode != .off {
                    Picker(selection: Binding(
                        get: {
                            let v = AudioFXPreferences.crossfadeSeconds
                            return v == 0 ? 6 : v
                        },
                        set: { AudioFXPreferences.crossfadeSeconds = $0 }
                    )) {
                        Text("3s").tag(3)
                        Text("6s").tag(6)
                        Text("9s").tag(9)
                        Text("12s").tag(12)
                    } label: {
                        Text("Length")
                    }
                }
            } header: {
                Text("Transitions")
            } footer: {
                Text("Same-album tracks stay gapless. Beat-aligned snaps the fade to an estimated beat grid.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Button(action: openEqualizer) {
                    HStack {
                        Text("Equalizer")
                            .foregroundStyle(.white)
                        Spacer()
                        Text(AudioFXPreferences.equalizerEnabled ? "On" : "Flat")
                            .foregroundStyle(DromeTheme.muted)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.28))
                    }
                }
                .buttonStyle(.borderless)
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Picker(selection: Binding(
                    get: { AudioFXPreferences.replayGainEnabled },
                    set: { AudioFXPreferences.replayGainEnabled = $0 }
                )) {
                    Text("Off").tag(false)
                    Text("On").tag(true)
                } label: {
                    Text("ReplayGain")
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Uses loudness tags from your server when present; otherwise a gentle fallback.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Toggle(isOn: Binding(
                    get: { lyricsIndexer.isEnabled },
                    set: { lyricsIndexer.isEnabled = $0 }
                )) {
                    Text("Lyrics from LRCLIB")
                }
                .tint(DromeTheme.accent)
            } footer: {
                Text("When your server has no lyrics for a song, its title, artist, album and length are sent to lrclib.net to look them up.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Toggle(isOn: Binding(
                    get: { PlaybackPreferences.skipLowRatedEverywhere },
                    set: { PlaybackPreferences.skipLowRatedEverywhere = $0 }
                )) {
                    Text("Skip low-rated songs")
                }
                .tint(DromeTheme.accent)

                Picker(selection: Binding(
                    get: { player.shuffleMode },
                    set: { player.shuffleMode = $0 }
                )) {
                    Text("Off").tag(ShuffleMode.off)
                    Text("Smart").tag(ShuffleMode.smart)
                    Text("Random").tag(ShuffleMode.random)
                } label: {
                    Text("Shuffle")
                }

                Picker(selection: Binding(
                    get: { StationSteeringStore.current },
                    set: { StationSteeringStore.current = $0 }
                )) {
                    ForEach(StationSteering.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Station steering")
                }

                Picker(selection: Binding(
                    get: { Int(PlaybackPreferences.autoplayRecencyHours) },
                    set: { PlaybackPreferences.autoplayRecencyHours = Double($0) }
                )) {
                    Text("24 hours").tag(24)
                    Text("3 days").tag(72)
                    Text("7 days").tag(168)
                    Text("30 days").tag(720)
                } label: {
                    Text("Autoplay recency")
                }
            } header: {
                Text("Queue")
            } footer: {
                Text("Skip low-rated does not apply while playing Out of Rotation — Shuffle and Keep Playing stay in that playlist.")
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollIndicators(.hidden)
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.large)
    }
}
