import SwiftUI

// Asks a demo visitor to sign in when they try something that posts to GitHub as them; signing in from here lands in the signed-in app (shiptok/AGENTS.md, "Demo Mode").
struct DemoSignInPromptSheet: View {
    let action: DemoSignInPromptAction
    let signInSession: GitHubSignInSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image("RevylMark")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            Text(action.promptTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(RevylBrandColor.textPrimary)
            Text("Likes, reactions, comments and vibes post to GitHub under your name, so ShipTok needs your GitHub account first. Sign in with Revyl to use them on your team's repositories.")
                .font(.subheadline)
                .foregroundStyle(RevylBrandColor.textMuted)
                .multilineTextAlignment(.center)
            if let signInFailureMessage = signInSession.demoSignInFailureMessage {
                Text(signInFailureMessage)
                    .font(.footnote)
                    .foregroundStyle(RevylBrandColor.warning)
                    .multilineTextAlignment(.center)
            }
            SignInWithRevylButton(signInSession: signInSession)
            Button("Not now") { dismiss() }
                .buttonStyle(.revylSecondary)
                .disabled(signInSession.isSigningIn)
        }
        .padding(24)
        .frame(maxWidth: 440)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(RevylBrandColor.surface)
    }
}

extension View {
    // Each presenting screen keeps its own prompt, since a sheet can't present over another sheet from the screen beneath.
    func demoSignInPrompt(_ promptedAction: Binding<DemoSignInPromptAction?>, signInSession: GitHubSignInSession) -> some View {
        sheet(item: promptedAction) { action in
            DemoSignInPromptSheet(action: action, signInSession: signInSession)
        }
    }
}
