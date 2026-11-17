import SwiftUI

struct AccountActionsSections: View {
    let signInSession: GitHubSignInSession
    @State private var confirmsDataDeletion = false
    @State private var dataDeletionFailureMessage: String?
    @State private var signOutFailureMessage: String?

    private var isDeletingData: Bool { signInSession.isDeletingShipTokData }

    var body: some View {
        PrivacyAndSupportSection()
        Section {
            Button("Sign out", role: .destructive) {
                do {
                    try signInSession.signOut()
                } catch {
                    signOutFailureMessage = error.localizedDescription
                }
            }
            .disabled(isDeletingData)
            .alert(
                "Couldn't sign out",
                isPresented: Binding(get: { signOutFailureMessage != nil }, set: { if !$0 { signOutFailureMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(signOutFailureMessage ?? "")
            }
        }
        Section {
            Button(role: .destructive) {
                confirmsDataDeletion = true
            } label: {
                HStack {
                    Text(isDeletingData ? "Deleting your ShipTok data" : "Delete my ShipTok data")
                    if isDeletingData {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isDeletingData)
            .confirmationDialog("Delete your ShipTok data?", isPresented: $confirmsDataDeletion, titleVisibility: .visible) {
                Button("Delete my ShipTok data", role: .destructive, action: deleteShipTokData)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Revyl deletes your ShipTok settings and ends ShipTok's access to your GitHub account, and this iPhone forgets your sign-in, the people you hid, saved feeds and media. Your comments, reactions and vibes stay on GitHub.")
            }
            .alert(
                "Couldn't delete your ShipTok data",
                isPresented: Binding(get: { dataDeletionFailureMessage != nil }, set: { if !$0 { dataDeletionFailureMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(dataDeletionFailureMessage ?? "")
            }
        } footer: {
            Text("Your comments, reactions and vibes are GitHub's record and stay there.")
        }
    }

    private func deleteShipTokData() {
        Task {
            do {
                try await signInSession.deleteShipTokData()
            } catch {
                dataDeletionFailureMessage = error.localizedDescription
            }
        }
    }
}
