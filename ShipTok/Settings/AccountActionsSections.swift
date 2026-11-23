import SwiftUI

struct AccountActionsSections: View {
    let signInSession: ShipTokSignInSession
    @State private var signOutFailureMessage: String?
    @State private var confirmsRevylAccountDeletion = false
    @State private var revylAccountDeletionFailureMessage: String?

    private var isDeletingRevylAccount: Bool { signInSession.isDeletingRevylAccount }
    private var isChangingSignIn: Bool { isDeletingRevylAccount || signInSession.isSigningOut }

    var body: some View {
        PrivacyAndSupportSection()
        Section {
            Button(role: .destructive) {
                Task {
                    do {
                        try await signInSession.signOut()
                    } catch {
                        signOutFailureMessage = error.localizedDescription
                    }
                }
            } label: {
                HStack {
                    Text(signInSession.isSigningOut ? "Signing out" : "Sign out")
                    if signInSession.isSigningOut {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isChangingSignIn)
            .alert(
                "Couldn't sign out",
                isPresented: Binding(get: { signOutFailureMessage != nil }, set: { if !$0 { signOutFailureMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(signOutFailureMessage ?? "")
            }
        } footer: {
            Text("Signs this iPhone out of Revyl, and it stops getting your ShipTok notifications.")
        }
        Section {
            Button(role: .destructive) {
                confirmsRevylAccountDeletion = true
            } label: {
                HStack {
                    Text(isDeletingRevylAccount ? "Deleting your Revyl account" : "Delete my Revyl account")
                    if isDeletingRevylAccount {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isChangingSignIn)
            .confirmationDialog("Delete your Revyl account?", isPresented: $confirmsRevylAccountDeletion, titleVisibility: .visible) {
                Button("Delete my Revyl account", role: .destructive, action: deleteRevylAccount)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Revyl deletes your Revyl account with the comments, replies, reactions, vibes and settings you made in ShipTok. This iPhone signs out and forgets everything ShipTok kept.")
            }
            .alert(
                "Couldn't delete your Revyl account",
                isPresented: Binding(get: { revylAccountDeletionFailureMessage != nil }, set: { if !$0 { revylAccountDeletionFailureMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(revylAccountDeletionFailureMessage ?? "")
            }
        } footer: {
            Text("An owner of an organization can't delete their Revyl account from ShipTok.")
        }
    }

    private func deleteRevylAccount() {
        Task {
            do {
                try await signInSession.deleteRevylAccount()
            } catch {
                revylAccountDeletionFailureMessage = error.localizedDescription
            }
        }
    }
}
