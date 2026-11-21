import AuthenticationServices
import SwiftUI

struct ConnectGitHubButton: View {
    let signInSession: ShipTokSignInSession
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        Button {
            Task { await signInSession.connectGitHub(using: webAuthenticationSession) }
        } label: {
            HStack(spacing: 10) {
                if signInSession.isConnectingGitHub {
                    ProgressView().tint(.white)
                }
                Text("Connect GitHub")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.revylPrimary)
        .disabled(signInSession.isConnectingGitHub || signInSession.isSigningOut || signInSession.isDeletingRevylAccount)
    }
}

// Signed in to Revyl without a connected GitHub account, so connecting GitHub is the only way on (AGENTS.md, "Revyl Sign-In").
struct ConnectGitHubView: View {
    let signInSession: ShipTokSignInSession
    let connectGitHubVisit: ConnectGitHubVisit
    @State private var showsAccount = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                Image("RevylMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                Text("Connect GitHub")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(RevylBrandColor.textPrimary)
                Text("ShipTok shows the repositories where your organization installed Revyl's GitHub App, and your vibes, likes, reactions and comments post to GitHub under your name.")
                    .font(.subheadline)
                    .foregroundStyle(RevylBrandColor.textMuted)
                    .multilineTextAlignment(.center)
                if let message = connectGitHubVisit.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(RevylBrandColor.warning)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                ConnectGitHubButton(signInSession: signInSession)
            }
            .frame(maxWidth: 440)
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RevylBrandColor.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Account", systemImage: "person.crop.circle") { showsAccount = true }
                }
            }
        }
        .sheet(isPresented: $showsAccount) {
            NavigationStack {
                List {
                    AccountActionsSections(signInSession: signInSession)
                }
                .scrollContentBackground(.hidden)
                .background(RevylBrandColor.surface)
                .navigationTitle("Account")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsAccount = false }
                    }
                }
            }
        }
    }
}
