import SwiftUI
import AVKit

/// System AirPlay / Bluetooth / device route picker (same control Spotify uses).
struct AirPlayRoutePicker: UIViewRepresentable {
    var tintColor: UIColor = .white
    var activeTintColor: UIColor = UIColor(red: 0.25, green: 0.55, blue: 0.98, alpha: 1)

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = tintColor
        view.activeTintColor = activeTintColor
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor
    }
}
