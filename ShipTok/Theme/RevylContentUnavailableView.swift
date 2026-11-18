import SwiftUI

// Every empty, finished or failed screen, in the feed, weekly mode and the inbox alike, uses the system's layout with at most one quiet action.
struct RevylContentUnavailableView: View {
    let systemImageName: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImageName)
            }
        } description: {
            Text(verbatim: message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.revylSecondary)
            }
        }
        .centeredInReadableContentColumn()
    }
}
