import SwiftUI

struct AccountActionsSections: View {
    let signInSession: ShipTokSignInSession
    @State private var confirmsDataDeletion = false
    @State private var dataDeletionFailureMessage: String?
    @State private var signOutFailureMessage: String?
    @State private var confirmsRevylAccountDeletion = false
    @State private var revylAccountDeletionFailureMessage: String?

    private var isDeletingData: Bool { signInSession.isDeletingShipTokData }
    private var isDeletingRevylAccount: Bool { signInSession.isDeletingRevylAccount }
    private var isEndingSignIn: Bool { isDeletingData || isDeletingRevylAccount || signInSession.isSigningOut }

    private var hasConnectedGitHub: Bool {
        guard case .signedIn = signInSession.phase else { return false }
        return true
    }

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
            .disabled(isEndingSignIn)
            .alert(
                "Couldn't sign out",
                isPresented: Binding(get: { signOutFailureMessage != nil }, set: { if !$0 { signOutFailureMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(signOutFailureMessage ?? "")
            }
        } footer: {
            Text(hasConnectedGitHub ? "Signs this iPhone out of Revyl and GitHub." : "Signs this iPhone out of Revyl.")
        }
        if hasConnectedGitHub {
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
                .disabled(isEndingSignIn)
                .confirmationDialog("Delete your ShipTok data?", isPresented: $confirmsDataDeletion, titleVisibility: .visible) {
                    Button("Delete my ShipTok data", role: .destructive, action: deleteShipTokData)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Revyl deletes your ShipTok settings and ends ShipTok's access to your GitHub account, and this iPhone signs out of Revyl and forgets your sign-ins, the people you hid, saved feeds and media. Your comments, reactions and vibes stay on GitHub.")
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
            .disabled(isEndingSignIn)
            .confirmationDialog("Delete your Revyl account?", isPresented: $confirmsRevylAccountDeletion, titleVisibility: .visible) {
                Button("Delete my Revyl account", role: .destructive, action: deleteRevylAccount)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Revyl deletes your Revyl account, its GitHub connection and your ShipTok settings, and ends ShipTok's access to your GitHub account. This iPhone signs out and forgets everything ShipTok kept. Your comments, reactions and vibes stay on GitHub.")
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
