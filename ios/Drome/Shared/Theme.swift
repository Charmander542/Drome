import SwiftUI
import UIKit

enum DromeTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let elevated = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let elevated2 = Color(red: 0.16, green: 0.16, blue: 0.17)
    /// Soft system blue — used for accents across the app.
    static let accent = Color(red: 0.25, green: 0.55, blue: 0.98)
    static let muted = Color(white: 0.62)
    static let divider = Color(white: 0.22)

    static let titleFont = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let headlineFont = Font.system(.title2, design: .rounded).weight(.bold)
    static let rowTitle = Font.system(.body, design: .default).weight(.semibold)
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        switch cleaned.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        default:
            r = 0.2; g = 0.2; b = 0.22
        }
        self.init(red: r, green: g, blue: b)
    }
}

/// Extra bottom safe-area padding when the mini player is visible.
/// Nested `List`/`ScrollView` inside `TabView` + `NavigationStack` often ignore
/// the outer `safeAreaInset`, so tab content opts in via this environment value.
private struct MiniPlayerClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var miniPlayerClearance: CGFloat {
        get { self[MiniPlayerClearanceKey.self] }
        set { self[MiniPlayerClearanceKey.self] = newValue }
    }
}

enum MiniPlayerMetrics {
    /// Art (48) + vertical padding (16) + gap above the tab bar (4) + slack.
    static let clearanceHeight: CGFloat = 76
}

extension View {
    func dromeScreen() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DromeTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

    /// Keeps scrollable content clear of the mini player. No-op when clearance is 0.
    /// Prefer applying once per navigation stack; also safe on individual lists.
    func dromeMiniPlayerClearance(_ height: CGFloat? = nil) -> some View {
        modifier(MiniPlayerClearanceModifier(overrideHeight: height))
    }
}

private struct MiniPlayerClearanceModifier: ViewModifier {
    var overrideHeight: CGFloat?
    @Environment(\.miniPlayerClearance) private var clearance

    func body(content: Content) -> some View {
        let amount = max(0, overrideHeight ?? clearance)
        content
            // Push UIKit additionalSafeAreaInsets onto the hosting navigation
            // controller so every page (root + NavigationLink pushes) clears
            // the mini player. TabView children ignore the outer safeAreaInset.
            .background {
                MiniPlayerSafeAreaSync(bottomInset: amount)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
    }
}

/// Pushes `additionalSafeAreaInsets` onto the hosting navigation stack so every
/// pushed page (including destination `NavigationLink`s) clears the mini player.
private struct MiniPlayerSafeAreaSync: UIViewControllerRepresentable {
    var bottomInset: CGFloat

    func makeUIViewController(context: Context) -> Controller {
        Controller(bottomInset: bottomInset)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.bottomInset = bottomInset
        DispatchQueue.main.async { controller.apply() }
    }

    final class Controller: UIViewController {
        var bottomInset: CGFloat
        private var observation: NSKeyValueObservation?
        private weak var observedNav: UINavigationController?

        init(bottomInset: CGFloat) {
            self.bottomInset = bottomInset
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
            startObserving()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
            startObserving()
        }

        func apply() {
            guard let nav = nearestNavigationController() else { return }
            var insets = nav.additionalSafeAreaInsets
            guard abs(insets.bottom - bottomInset) > 0.5 else { return }
            insets.bottom = bottomInset
            nav.additionalSafeAreaInsets = insets
        }

        private func nearestNavigationController() -> UINavigationController? {
            if let nav = navigationController { return nav }
            var current: UIViewController? = parent
            while let page = current {
                if let nav = page as? UINavigationController { return nav }
                if let nav = page.navigationController { return nav }
                current = page.parent
            }
            return nil
        }

        private func startObserving() {
            let nav = nearestNavigationController()
            guard observedNav !== nav else { return }
            observation?.invalidate()
            observedNav = nav
            observation = nav?.observe(\.viewControllers, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.apply() }
            }
        }

        deinit {
            observation?.invalidate()
            // Don't clear insets here — another sync probe may still be active.
        }
    }
}

extension View {
    /// Confirms before a play action that would replace an existing user queue.
    func confirmReplaceUserQueue(
        isPresented: Binding<Bool>,
        queueCount: Int,
        onClearAndPlay: @escaping () -> Void,
        onKeepAndPlay: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) -> some View {
        confirmationDialog(
            "Replace queue?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Clear Queue & Play") { onClearAndPlay() }
            Button("Keep Queue & Play") { onKeepAndPlay() }
            Button("Cancel", role: .cancel) { onCancel?() }
        } message: {
            Text(queueCount == 1
                  ? "You have 1 song queued. Clear it, or keep it and play this song now?"
                  : "You have \(queueCount) songs queued. Clear them, or keep them and play this song now?")
        }
    }
}
