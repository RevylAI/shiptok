import SwiftUI

// A demo visitor's settings: what demo mode is, a way to sign in, and what works without an account (AGENTS.md, "Demo Mode").
struct DemoSettingsView: View {
    let demoVisitor: DemoVisitor
    let signInSession: GitHubSignInSession
    // Kept only for the visit, like everything else a demo visitor chooses.
    @Binding var showsOnlyPullRequestsWithVideos: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("You're looking around", systemImage: "eye")
                            .font(.headline)
                            .foregroundStyle(RevylBrandColor.textPrimary)
                        Text("This is a demo of ShipTok on a public repository, without an account. Sign in with Revyl, using your GitHub account, to see your team's repositories and to like, react, comment and send vibes.")
                            .font(.subheadline)
                            .foregroundStyle(RevylBrandColor.textMuted)
                        if let signInFailureMessage = signInSession.demoSignInFailureMessage {
                            Text(signInFailureMessage)
                                .font(.footnote)
                                .foregroundStyle(RevylBrandColor.warning)
                        }
                        SignInWithRevylButton(signInSession: signInSession)
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Demo")
                }
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Repository")
                            .foregroundStyle(RevylBrandColor.textPrimary)
                        Text(verbatim: demoVisitor.repositoryFullName)
                            .font(.caption)
                            .foregroundStyle(RevylBrandColor.textMuted)
                    }
                    Toggle("Videos only", isOn: Binding(
                        get: { showsOnlyPullRequestsWithVideos },
                        set: { newShowsOnlyPullRequestsWithVideos in
                            demoVisitor.analytics.capture(.showsOnlyPullRequestsWithVideosChanged(newShowsOnlyPullRequestsWithVideos))
                            showsOnlyPullRequestsWithVideos = newShowsOnlyPullRequestsWithVideos
                        }
                    ))
                } header: {
                    Text("Feed")
                } footer: {
                    Text("Open and Merged show only pull requests that lead with a video. Turn it off to see ones with only screenshots or GIFs too. Weekly videos always show. Your choice lasts for the rest of this visit.")
                }
                HiddenPeopleSection(
                    hiddenPeopleStore: demoVisitor.hiddenPeopleStore,
                    footerText: "Their pull requests, weekly videos, comments, vibes and media don't show for the rest of this visit. They aren't told, and nothing changes on GitHub."
                )
                GesturesSection()
                PrivacyAndSupportSection()
            }
            .scrollContentBackground(.hidden)
            .scrollContentCenteredInReadableContentColumn()
            .background(RevylBrandColor.surface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
