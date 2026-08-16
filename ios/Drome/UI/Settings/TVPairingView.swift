import SwiftUI

struct TVPairingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var client = DromeTVPairingClient()
    @State private var pin = ""
    @State private var selected: DromeTVPairingClient.FoundTV?
    @State private var isSending = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text(client.status)
                    .foregroundStyle(DromeTheme.muted)
                ForEach(client.televisions) { tv in
                    Button {
                        selected = tv
                    } label: {
                        HStack {
                            Text(tv.name)
                            Spacer()
                            if selected?.id == tv.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DromeTheme.accent)
                            }
                        }
                    }
                    .listRowBackground(DromeTheme.elevated)
                }
            } header: {
                Text("Apple TV")
            } footer: {
                Text("Leave Drome open on the Apple TV login screen. Both devices must be on the same Wi‑Fi.")
            }

            Section {
                TextField("PIN from the TV", text: $pin)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                Button(isSending ? "Sending…" : "Send \(session.account.username)") {
                    Task { await send() }
                }
                .disabled(isSending || selected == nil || pin.count < 6)
                if let message {
                    Text(message).font(.caption)
                }
            } header: {
                Text("PIN")
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .scrollContentBackground(.hidden)
        .background(DromeTheme.background)
        .navigationTitle("Send to Apple TV")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear { client.start() }
        .onDisappear { client.stop() }
    }

    private func send() async {
        guard let selected else { return }
        guard let password = env.accounts.password(for: session.account) else {
            message = DromeTVPairingIO.PairingError.noPassword.localizedDescription
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            try await client.send(
                to: selected,
                pin: pin.trimmingCharacters(in: .whitespacesAndNewlines),
                account: session.account,
                password: password)
            message = "Signed in on Apple TV."
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
