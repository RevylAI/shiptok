import SwiftUI

// The row's button flips the setting and the switch only shows it (AGENTS.md, "Settings").
struct ToggleSettingRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Toggle(title, isOn: $isOn)
                .allowsHitTesting(false)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
        }
    }
}
