import SwiftUI

extension View {
    // Hiding someone takes everything they post out of the app, so it waits for a confirmation.
    func confirmingHide(of reportableContent: Binding<ReportableContent?>, onHide: @escaping (ReportableContent) -> Void) -> some View {
        confirmationDialog(
            reportableContent.wrappedValue.map { "Hide \($0.poster.displayName)?" } ?? "",
            isPresented: Binding(get: { reportableContent.wrappedValue != nil }, set: { if !$0 { reportableContent.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: reportableContent.wrappedValue
        ) { contentToHide in
            Button("Hide \(contentToHide.poster.displayName)", role: .destructive) { onHide(contentToHide) }
            Button("Cancel", role: .cancel) {}
        } message: { contentToHide in
            switch contentToHide.poster.account {
            case .github:
                Text("Their pull requests, weekly and feature videos won't show in ShipTok on this iPhone. \(contentToHide.poster.displayName) isn't told and nothing changes on GitHub. Unhide them anytime in Settings.")
            case .revyl:
                Text("Their comments, replies and feedback won't show in ShipTok on this iPhone. \(contentToHide.poster.displayName) isn't told. Unhide them anytime in Settings.")
            }
        }
    }
}
