import SwiftUI

/// Spotify-style device picker for Drome Connect.
struct ConnectDevicePicker: View {
    @ObservedObject var connect: ConnectController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
                    Text("Other devices")
                } footer: {
                    Text("Uses your companion server. Open Drome on another phone or Apple TV with the same login.")
                }
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
