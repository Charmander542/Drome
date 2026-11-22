import SwiftUI

struct SettingsAppearanceView: View {
    var body: some View {
        List {
            Section {
                AccentColourPicker()
            } header: {
                Text("Accent")
            } footer: {
                Text("Accent colours buttons, tabs, and highlights. Amber is Drome’s default.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                LabeledContent("Appearance", value: "Dark")
            } footer: {
                Text("Drome is designed for dark Listening Club chrome.")
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollIndicators(.hidden)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.large)
    }
}
