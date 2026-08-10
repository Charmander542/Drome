import SwiftUI

/// Matches the system launch screen (black + centered mark), then fades out
/// once the app UI is ready so the cold start feels continuous.
struct SplashOverlay: View {
    @Binding var isVisible: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.35), value: isVisible)
    }
}
