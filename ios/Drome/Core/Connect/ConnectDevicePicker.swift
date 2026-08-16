import SwiftUI

/// Spotify-style device picker: Drome Connect devices + system AirPlay / Bluetooth.
struct ConnectDevicePicker: View {
    @ObservedObject var connect: ConnectController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let serverStatus = connect.serverStatus {
                    Section {
                        Text(serverStatus)
                            .foregroundStyle(.red)
                        Text("Companion isn’t answering Connect. Rebuild/restart it (`docker compose up -d --build`) using the same URL as Wishlist.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Server")
                    }
                }

                Section {
                    deviceRow(
                        id: connect.deviceId,
                        name: connect.deviceName,
                        platform: ConnectPlatform.current,
                        isHere: true,
                        isActive: !connect.isRemote
                    ) {
                        Task { await connect.takeControl() }
                    }
                } header: {
                    Text("This device")
                }

                Section {
                    let others = connect.devices.filter { $0.id != connect.deviceId }
                    if others.isEmpty {
                        Text("No other devices online")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(others) { device in
                            deviceRow(
                                id: device.id,
                                name: device.name,
                                platform: device.platform,
                                isHere: false,
                                isActive: device.isActive == true
                            ) {
                                Task {
                                    await connect.transfer(to: device)
                                    dismiss()
                                }
                            }
                        }
                    }
                } header: {
                    Text("Drome devices")
                } footer: {
                    Text("Open Drome on another phone or Apple TV with the same login and companion server.")
                }

                #if os(iOS)
                Section {
                    ZStack(alignment: .leading) {
                        HStack(spacing: 14) {
                            Image(systemName: "airplayaudio")
                                .font(.title2)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AirPlay & Bluetooth")
                                Text("Speakers, TVs, and headphones")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .allowsHitTesting(false)

                        // Invisible system control — tap anywhere in the row.
                        AirPlayRoutePicker(tintColor: .clear, activeTintColor: .clear)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                } header: {
                    Text("Audio output")
                } footer: {
                    Text("Routes this phone’s audio like Spotify’s AirPlay picker.")
                }
                #endif
            }
            #if os(iOS)
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .navigationTitle("Connect")
            #endif
        }
    }

    private func deviceRow(id: String, name: String, platform: String,
                            isHere: Bool, isActive: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: ConnectDevice(id: id, name: name, platform: platform).systemImage)
                    .font(.title2)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .foregroundStyle(.primary)
                    Text(isHere ? "This \(platformLabel(platform))" : platformLabel(platform))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func platformLabel(_ platform: String) -> String {
        switch platform {
        case "tvos": return "Apple TV"
        case "web": return "Browser"
        case "desktop": return "Computer"
        case "android": return "Android"
        case "ios": return "iPhone"
        default: return platform
        }
    }
}
