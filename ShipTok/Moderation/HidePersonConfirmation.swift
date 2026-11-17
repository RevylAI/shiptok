import SwiftUI

extension View {
    // Hiding someone takes everything they post out of the app, so it waits for a confirmation.
    func confirmingHide(of postedContent: Binding<GitHubPostedContent?>, onHide: @escaping (GitHubPostedContent) -> Void) -> some View {
        confirmationDialog(
            postedContent.wrappedValue.map { "Hide @\($0.postedBy.login)?" } ?? "",
            isPresented: Binding(get: { postedContent.wrappedValue != nil }, set: { if !$0 { postedContent.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: postedContent.wrappedValue
        ) { contentToHide in
            Button("Hide @\(contentToHide.postedBy.login)", role: .destructive) { onHide(contentToHide) }
            Button("Cancel", role: .cancel) {}
        } message: { contentToHide in
            Text("Their pull requests, weekly videos, comments, vibes and media won't show in ShipTok on this iPhone. @\(contentToHide.postedBy.login) isn't told and nothing changes on GitHub. Unhide them anytime in Settings.")
        }
    }
}
