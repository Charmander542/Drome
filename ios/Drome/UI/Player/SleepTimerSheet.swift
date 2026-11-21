import SwiftUI
import UIKit

/// Half-sheet sleep timer with a scroll wheel — set minutes, swipe down to dismiss.
struct SleepTimerSheet: View {
    @EnvironmentObject private var sleepTimer: SleepTimerController
    @Environment(\.dismiss) private var dismiss

    var onSet: ((Int) -> Void)?
    var onCleared: (() -> Void)?

    @State private var minutes: Int = 15

    private let minuteOptions = Array(1...120)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let remaining = sleepTimer.remainingLabel {
                    Text(remaining)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DromeTheme.accent)
                        .padding(.top, 8)
                } else {
                    Text("Pauses music and podcasts when time’s up.")
                        .font(.subheadline)
                        .foregroundStyle(DromeTheme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }

                Picker("Minutes", selection: $minutes) {
                    ForEach(minuteOptions, id: \.self) { value in
                        Text(value == 1 ? "1 minute" : "\(value) minutes")
                            .tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .frame(height: 168)
                .padding(.vertical, 4)
                .accessibilityIdentifier("drome.sleep.wheel")

                VStack(spacing: 10) {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        sleepTimer.schedule(minutes: minutes)
                        onSet?(minutes)
                        dismiss()
                    } label: {
                        Text(sleepTimer.isActive ? "Restart Timer" : "Start Timer")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(DromeTheme.accent, in: Capsule(style: .continuous))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("drome.sleep.start")

                    if sleepTimer.isActive {
                        Button(role: .destructive) {
                            sleepTimer.cancel()
                            onCleared?()
                            dismiss()
                        } label: {
                            Text("Turn Off")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("drome.sleep.off")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                Spacer(minLength: 0)
            }
            .background(DromeTheme.background.ignoresSafeArea())
            .navigationTitle("Sleep timer")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("drome.sleep.screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .tint(.white)
            .onAppear {
                if let selected = sleepTimer.selectedMinutes,
                   minuteOptions.contains(selected) {
                    minutes = selected
                } else if let endsAt = sleepTimer.endsAt {
                    let remaining = max(1, Int(ceil(endsAt.timeIntervalSinceNow / 60)))
                    minutes = min(120, remaining)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
