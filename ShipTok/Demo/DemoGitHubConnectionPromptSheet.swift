import SwiftUI

// What a demo visitor tried that needs their GitHub account, or the feed's own Connect GitHub, so it asks them to connect GitHub first.
enum DemoGitHubConnectionPromptAction: String, Identifiable, Sendable {
    case connectGitHub = "connect_github"
    case like
    case reaction
    case comment
    case vibe
    case report
    case inbox

    var id: String { rawValue }

    var promptTitle: String {
        switch self {
        case .connectGitHub: "Connect GitHub"
        case .like: "Connect GitHub to like"
        case .reaction: "Connect GitHub to react"
        case .comment: "Connect GitHub to comment"
        case .vibe: "Connect GitHub to send vibes"
        case .report: "Connect GitHub to report"
        case .inbox: "Connect GitHub for your inbox"
        }
    }
}

// Asks a demo visitor to connect GitHub when they try something that needs their GitHub account; connecting from here lands in their own feed (AGENTS.md, "Demo Mode").
struct DemoGitHubConnectionPromptSheet: View {
    let action: DemoGitHubConnectionPromptAction
    let signInSession: ShipTokSignInSession
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
            Text("You're looking around a demo repository. Connect your GitHub account to see your team's repositories, where likes, reactions, comments and vibes post to GitHub under your name.")
                .font(.subheadline)
                .foregroundStyle(RevylBrandColor.textMuted)
                .multilineTextAlignment(.center)
            if let githubConnectionFailureMessage = signInSession.githubConnectionFailureMessage {
                Text(githubConnectionFailureMessage)
                    .font(.footnote)
                    .foregroundStyle(RevylBrandColor.warning)
                    .multilineTextAlignment(.center)
            }
            ConnectGitHubButton(signInSession: signInSession)
            Button("Not now") { dismiss() }
                .buttonStyle(.revylSecondary)
                .disabled(signInSession.isConnectingGitHub)
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
    func demoGitHubConnectionPrompt(_ promptedAction: Binding<DemoGitHubConnectionPromptAction?>, signInSession: ShipTokSignInSession) -> some View {
        sheet(item: promptedAction) { action in
            DemoGitHubConnectionPromptSheet(action: action, signInSession: signInSession)
        }
    }
}
