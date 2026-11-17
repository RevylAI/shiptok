import AuthenticationServices
import SwiftUI

struct SignInView: View {
    let signInSession: GitHubSignInSession
    let message: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("RevylMark")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(verbatim: "ShipTok")
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(RevylBrandColor.textPrimary)
            Text("Every merged pull request with a video or screenshot, one swipe at a time. Swipe right for good vibes, left for bad, and like, react and comment, all on GitHub.")
                .font(.body)
                .foregroundStyle(RevylBrandColor.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(RevylBrandColor.warning)
                    .multilineTextAlignment(.center)
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
        }
        .frame(maxWidth: 440)
        .padding(28)
        .frame(maxWidth: .infinity)
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
