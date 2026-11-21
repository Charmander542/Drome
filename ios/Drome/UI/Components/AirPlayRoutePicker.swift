import SwiftUI
import AVKit
import UIKit

/// System AirPlay / Bluetooth / device route picker (same control Spotify uses).
struct AirPlayRoutePicker: UIViewRepresentable {
    var tintColor: UIColor = .white
    var activeTintColor: UIColor = UIColor(red: 0.25, green: 0.55, blue: 0.98, alpha: 1)
    /// When true, the system button fills the representable’s bounds (needed for tiny chrome).
    var fillsBounds: Bool = true

    func makeUIView(context: Context) -> RoutePickerContainer {
        let container = RoutePickerContainer()
        container.picker.prioritizesVideoDevices = false
        container.picker.tintColor = tintColor
        container.picker.activeTintColor = activeTintColor
        container.fillsBounds = fillsBounds
        return container
    }

    func updateUIView(_ uiView: RoutePickerContainer, context: Context) {
        uiView.picker.tintColor = tintColor
        uiView.picker.activeTintColor = activeTintColor
        uiView.fillsBounds = fillsBounds
        uiView.setNeedsLayout()
    }
}

/// Hosts `AVRoutePickerView` and stretches its internal button to the full frame
/// so hits aren’t lost when SwiftUI only allocates a small tap target.
final class RoutePickerContainer: UIView {
    let picker = AVRoutePickerView()
    var fillsBounds = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        picker.backgroundColor = .clear
        addSubview(picker)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        picker.frame = bounds
        guard fillsBounds else { return }
        // AVRoutePickerView’s tappable control is often a small centered button.
        if let button = picker.subviews.compactMap({ $0 as? UIButton }).first
            ?? picker.subviews.first {
            button.frame = picker.bounds
            button.backgroundColor = .clear
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point), !isHidden, isUserInteractionEnabled, alpha > 0.01 else {
            return nil
        }
        // Prefer the route button; fall back to ourselves so the hit isn’t dropped.
        if let hit = picker.hitTest(convert(point, to: picker), with: event) {
            return hit
        }
        return picker
    }
}
