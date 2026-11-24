import SwiftUI

struct SettingsView: View {
    let viewer: SignedInTeammate
    let userSettingsStore: UserSettingsStore
    let chosenRepository: FeedRepositoryChoice
    let signInSession: ShipTokSignInSession
    let onChooseRepository: @MainActor (ShipTokRepository) async -> Void
    let onShowFeed: (() -> Void)?
    @State private var organizationSettingsStore: OrganizationSettingsStore
    @State private var githubAccountStore: GitHubAccountStore
    @Environment(\.shipTokAnalytics) private var analytics

    init(
        viewer: SignedInTeammate,
        userSettingsStore: UserSettingsStore,
        chosenRepository: FeedRepositoryChoice,
        signInSession: ShipTokSignInSession,
        onChooseRepository: @escaping @MainActor (ShipTokRepository) async -> Void,
        onShowFeed: (() -> Void)?
    ) {
        self.viewer = viewer
        self.userSettingsStore = userSettingsStore
        self.chosenRepository = chosenRepository
        self.signInSession = signInSession
        self.onChooseRepository = onChooseRepository
        self.onShowFeed = onShowFeed
        _organizationSettingsStore = State(initialValue: OrganizationSettingsStore(api: viewer.api))
        _githubAccountStore = State(initialValue: GitHubAccountStore(api: viewer.api))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    HStack(spacing: 12) {
                        AvatarView(avatarURL: viewer.account.avatarURL, diameter: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: viewer.account.displayName)
                                .font(.headline)
                                .foregroundStyle(RevylBrandColor.textPrimary)
                            Text(verbatim: viewer.account.email)
                                .font(.caption)
                                .foregroundStyle(RevylBrandColor.textMuted)
                            Text("Signed in to Revyl in \(viewer.account.organization.displayName)")
                                .font(.caption)
                                .foregroundStyle(RevylBrandColor.textMuted)
                        }
                    }
                    GitHubAccountSettingRow(store: githubAccountStore)
                }
                Section {
                    NavigationLink {
                        FeedRepositoryPickerView(
                            api: viewer.api,
                            chosenRepositoryID: chosenRepository.githubRepositoryID,
                            message: nil,
                            choosesOnlyRepositoryAutomatically: false,
                            onChoose: onChooseRepository
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Repository")
                                .foregroundStyle(RevylBrandColor.textPrimary)
                            Text(verbatim: chosenRepository.fullName)
                                .font(.caption)
                                .foregroundStyle(RevylBrandColor.textMuted)
                        }
                    }
                    Toggle("Videos only", isOn: showsOnlyPostsWithVideosBinding)
                } header: {
                    Text("Feed")
                } footer: {
                    Text("Open and Merged show only pull requests that lead with a video. Turn it off to see ones with only screenshots or GIFs too. Weekly, Features and the pull requests they open always show.")
                }
                Section {
                    ForEach(FeedMode.allCases, id: \.self) { feedMode in
                        Toggle(feedMode.tabTitle, isOn: feedModeTabBinding(for: feedMode))
                            .disabled(userSettingsStore.feedModesWithShownTabs == [feedMode])
                    }
                } header: {
                    Text("Feed tabs")
                } footer: {
                    Text("Choose which tabs show at the top of the feed. At least one stays on.")
                }
                Section {
                    Toggle("Ask for feedback on good vibes", isOn: feedbackBoxBinding(for: .good))
                    Toggle("Ask for feedback on bad vibes", isOn: feedbackBoxBinding(for: .bad))
                } header: {
                    Text("Vibe feedback")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your vibes and their feedback reach the pull request's developer in ShipTok. The feedback box is optional and never blocks a swipe.")
                        if let refreshFailureMessage = userSettingsStore.refreshFailureMessage {
                            Text("Couldn't load your saved settings: \(refreshFailureMessage)")
                                .foregroundStyle(RevylBrandColor.warning)
                        }
                    }
                }
                OrganizationSettingsSection(store: organizationSettingsStore, organizationName: viewer.account.organization.displayName)
                HiddenPeopleSection(hiddenPeopleStore: viewer.hiddenPeopleStore)
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
        .task { await organizationSettingsStore.refresh() }
        .task { await githubAccountStore.refresh() }
        .alert(
            "Couldn't save your setting",
            isPresented: Binding(get: { userSettingsStore.saveFailureMessage != nil }, set: { if !$0 { userSettingsStore.saveFailureMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(userSettingsStore.saveFailureMessage ?? "")
        }
        .alert(
            "Couldn't save your organization's setting",
            isPresented: Binding(get: { organizationSettingsStore.saveFailureMessage != nil }, set: { if !$0 { organizationSettingsStore.saveFailureMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(organizationSettingsStore.saveFailureMessage ?? "")
        }
    }

    private var showsOnlyPostsWithVideosBinding: Binding<Bool> {
        Binding(
            get: { userSettingsStore.userSettings.showsOnlyPostsWithVideos },
            set: { showsOnlyPostsWithVideos in
                analytics?.capture(.showsOnlyPostsWithVideosChanged(showsOnlyPostsWithVideos))
                Task { await userSettingsStore.setShowsOnlyPostsWithVideos(showsOnlyPostsWithVideos) }
            }
        )
    }

    private func feedModeTabBinding(for feedMode: FeedMode) -> Binding<Bool> {
        Binding(
            get: { userSettingsStore.feedModesWithShownTabs.contains(feedMode) },
            set: { showsFeedModeTab in
                analytics?.capture(.showsFeedModeTabChanged(feedMode, showsFeedModeTab: showsFeedModeTab))
                Task { await userSettingsStore.setShowsFeedModeTab(showsFeedModeTab, for: feedMode) }
            }
        )
    }

    private func feedbackBoxBinding(for vibe: ShipTokVibe) -> Binding<Bool> {
        Binding(
            get: { userSettingsStore.showsFeedbackBox(for: vibe) },
            set: { showsFeedbackBox in Task { await userSettingsStore.setShowsFeedbackBox(showsFeedbackBox, for: vibe) } }
        )
    }
}
