import SwiftUI

// Every empty, finished or failed screen, in the feed, weekly mode and the inbox alike, uses the system's layout with at most one quiet action.
struct RevylContentUnavailableView: View {
    let systemImageName: String
    let title: Text
    let message: Text
    var actionTitle: Text?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label {
                title
            } icon: {
                Image(systemName: systemImageName)
            }
        } description: {
            message
        } actions: {
            if let actionTitle, let action {
                Button(action: action) { actionTitle }
                    .buttonStyle(.revylSecondary)
            }
        }
        .centeredInReadableContentColumn()
    }
}
