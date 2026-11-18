import AuthenticationServices
import SwiftUI

struct SignInView: View {
    let signInSession: GitHubSignInSession
    let message: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image("RevylMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                VStack(spacing: 10) {
                    Text(verbatim: "ShipTok")
                        .font(.largeTitle.weight(.heavy))
                        .foregroundStyle(RevylBrandColor.textPrimary)
                    Text("Every merged pull request with a video or screenshot, one swipe at a time. Swipe right for good vibes, left for bad, and like, react and comment, all on GitHub.")
                        .font(.body)
                        .foregroundStyle(RevylBrandColor.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer()
            VStack(spacing: 12) {
                if let message {
                    signedOutNote(message)
                }
                SignInWithRevylButton(signInSession: signInSession)
                Button {
                    Task { await signInSession.exploreDemo() }
                } label: {
                    HStack(spacing: 10) {
                        if signInSession.isOpeningDemo {
                            ProgressView()
                        }
                        Text("Look around first")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.revylSecondary)
                .disabled(signInSession.isSigningIn || signInSession.isOpeningDemo)
                Text("Revyl signs you in with your GitHub account. ShipTok shows the repositories where your organization installed Revyl's GitHub App, and your vibes, likes, reactions and comments post to GitHub under your name. Look around first to watch a demo repository without an account.")
                    .font(.caption)
                    .foregroundStyle(RevylBrandColor.textSubtle)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 440)
        .padding(28)
        .frame(maxWidth: .infinity)
        .animation(.default, value: message)
    }

    // The same message says the data is deleted, why a sign-in ended, or why the demo didn't open, so it reads as a note rather than a warning.
    private func signedOutNote(_ message: String) -> some View {
        Label {
            Text(message)
                .foregroundStyle(RevylBrandColor.textBody)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(RevylBrandColor.textMuted)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RevylBrandColor.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RevylBrandColor.border, lineWidth: 1))
        .transition(.opacity)
    }
}

struct SignInWithRevylButton: View {
    let signInSession: GitHubSignInSession
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        Button {
            Task { await signInSession.signIn(using: webAuthenticationSession) }
        } label: {
            HStack(spacing: 10) {
                if signInSession.isSigningIn {
                    ProgressView().tint(.white)
                } else {
                    Image("RevylMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
                Text("Sign in with Revyl")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.revylPrimary)
        .disabled(signInSession.isSigningIn || signInSession.isOpeningDemo)
    }
}
