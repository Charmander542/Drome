import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Cross-platform color helpers.
enum DromeColors {
    static var elevatedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGray6)
        #else
        Color.gray.opacity(0.3)
        #endif
    }

    static var secondaryButtonBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGray5)
        #else
        Color.gray.opacity(0.3)
        #endif
    }
}
