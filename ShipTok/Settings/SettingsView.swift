import SwiftUI

struct SettingsView: View {
    let viewer: GitHubUserIdentity
    let signInID: UUID
    let userSettingsStore: UserSettingsStore
    let hiddenPeopleStore: HiddenPeopleStore
    let accountAPI: GitHubAccountAPI
    let chosenRepositoryFullName: String
    let signInSession: GitHubSignInSession
    let onChooseRepository: @MainActor (String) async -> Void
    let onShowFeed: (() -> Void)?
    @Environment(\.shipTokAnalytics) private var analytics

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    HStack(spacing: 12) {
                        GitHubAvatarView(avatarURL: viewer.githubAvatarURL, diameter: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(viewer.githubLogin)")
                                .font(.headline)
                                .foregroundStyle(RevylBrandColor.textPrimary)
                            Text("Signed in with Revyl, using your GitHub account")
                                .font(.caption)
                                .foregroundStyle(RevylBrandColor.textMuted)
                        }
                    }
                }
                Section {
                    NavigationLink {
                        FeedRepositoryPickerView(
                            accountAPI: accountAPI,
                            chosenRepositoryFullName: chosenRepositoryFullName,
                            message: nil,
                            choosesDefaultRepositoryWhenReachable: false,
                            onSignInRejected: { signInSession.handleRejectedGitHubAccess($0, endingSignInID: signInID) },
                            onChoose: onChooseRepository
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Repository")
                                .foregroundStyle(RevylBrandColor.textPrimary)
                            Text(verbatim: chosenRepositoryFullName)
                                .font(.caption)
                                .foregroundStyle(RevylBrandColor.textMuted)
                        }
                    }
                    Toggle("Videos only", isOn: showsOnlyPullRequestsWithVideosBinding)
                } header: {
                    Text("Feed")
                } footer: {
                    Text("Open and Merged show only pull requests that lead with a video. Turn it off to see ones with only screenshots or GIFs too. Weekly videos always show.")
                }
                Section {
                    Toggle("Ask for feedback on good vibes", isOn: feedbackBoxBinding(for: .good))
                    Toggle("Ask for feedback on bad vibes", isOn: feedbackBoxBinding(for: .bad))
                } header: {
                    Text("Vibe feedback")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Every vibe posts to GitHub as a comment from you. The feedback box is optional and never blocks a swipe.")
                        if let refreshFailureMessage = userSettingsStore.refreshFailureMessage {
                            Text("Couldn't load your saved settings: \(refreshFailureMessage)")
                                .foregroundStyle(RevylBrandColor.warning)
                        }
                    }
                }
                HiddenPeopleSection(hiddenPeopleStore: hiddenPeopleStore)
                GesturesSection()
                AccountActionsSections(signInSession: signInSession)
            }
            .scrollContentBackground(.hidden)
            .scrollContentCenteredInReadableContentColumn()
            .background(RevylBrandColor.surface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .backToFeedToolbarItem(onShowFeed)
        }
        .task { await userSettingsStore.refresh() }
        .alert(
            "Couldn't save your setting",
            isPresented: Binding(get: { userSettingsStore.saveFailureMessage != nil }, set: { if !$0 { userSettingsStore.saveFailureMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(userSettingsStore.saveFailureMessage ?? "")
        }
    }

    private var showsOnlyPullRequestsWithVideosBinding: Binding<Bool> {
        Binding(
            get: { userSettingsStore.userSettings.showsOnlyPullRequestsWithVideos },
            set: { showsOnlyPullRequestsWithVideos in
                analytics?.capture(.showsOnlyPullRequestsWithVideosChanged(showsOnlyPullRequestsWithVideos))
                Task { await userSettingsStore.setShowsOnlyPullRequestsWithVideos(showsOnlyPullRequestsWithVideos) }
            }
        )
    }

    private func feedbackBoxBinding(for vibe: PullRequestVibe) -> Binding<Bool> {
        Binding(
            get: { userSettingsStore.showsFeedbackBox(for: vibe) },
            set: { showsFeedbackBox in Task { await userSettingsStore.setShowsFeedbackBox(showsFeedbackBox, for: vibe) } }
        )
    }
}
