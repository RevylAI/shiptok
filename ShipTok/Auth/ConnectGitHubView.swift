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

// Signed in to Revyl without a connected GitHub account while the demo can't open, so connecting GitHub, or trying the demo again, is the way on (AGENTS.md, "Demo Mode").
struct ConnectGitHubView: View {
    let signInSession: ShipTokSignInSession
    let message: String
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
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(RevylBrandColor.warning)
                    .multilineTextAlignment(.center)
                Spacer()
                ConnectGitHubButton(signInSession: signInSession)
                Button {
                    Task { await signInSession.openDemoAgain() }
                } label: {
                    HStack(spacing: 10) {
                        if signInSession.isOpeningDemo {
                            ProgressView()
                        }
                        Text("Try the demo again")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.revylSecondary)
                .disabled(signInSession.isConnectingGitHub || signInSession.isOpeningDemo || signInSession.isDeletingRevylAccount)
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
