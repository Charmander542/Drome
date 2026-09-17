import SwiftUI

/// Shell chrome (tab bar) visibility for immersive TV screens.
@MainActor
final class TVChromeState: ObservableObject {
    @Published var hidesTabBar = false
}
