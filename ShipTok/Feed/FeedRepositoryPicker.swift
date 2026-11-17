import SwiftUI

enum FeedRepositoryChoice {
    static let defaultRepositoryFullName = "RevylAI/shiptok-demo"

    static func defaultsKey(githubUserID: Int64) -> String {
        "feed-repository-full-name-github-\(githubUserID)"
    }
}

struct FeedRepositoryPickerView: View {
    let accountAPI: GitHubAccountAPI
    let chosenRepositoryFullName: String?
    let message: String?
    let choosesDefaultRepositoryWhenReachable: Bool
    let onSignInRejected: @MainActor (GitHubAPIError) -> Void
    let onChoose: @MainActor (String) async -> Void
    @State private var reachableRepositoryFullNames: [String]?
    @State private var loadFailureMessage: String?
    @State private var searchText = ""
    @State private var isChoosing = false

    private var matchingRepositoryFullNames: [String] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return reachableRepositoryFullNames ?? [] }
        return (reachableRepositoryFullNames ?? []).filter { $0.localizedCaseInsensitiveContains(trimmedSearchText) }
    }

    var body: some View {
        List {
            if let message {
                Section {
                    Text(message)
                        .foregroundStyle(RevylBrandColor.warning)
                }
            }
            if let loadFailureMessage {
                Section {
                    Text(loadFailureMessage)
                        .foregroundStyle(RevylBrandColor.warning)
                    Button("Try again") {
                        Task { await loadReachableRepositories() }
                    }
                }
            } else if let reachableRepositoryFullNames {
                if reachableRepositoryFullNames.isEmpty {
                    Section {
                        Text("Revyl's GitHub App isn't installed on any repository you can open. An organization admin can install it on the repositories ShipTok should show.")
                            .foregroundStyle(RevylBrandColor.textMuted)
                        Link("How to install Revyl's GitHub App", destination: URL(string: "https://docs.revyl.com/integrations/github")!)
                        Button("Check again") {
                            Task { await loadReachableRepositories() }
                        }
                    }
                } else {
                    Section {
                        ForEach(matchingRepositoryFullNames, id: \.self) { repositoryFullName in
                            Button {
                                choose(repositoryFullName)
                            } label: {
                                HStack {
                                    Text(verbatim: repositoryFullName)
                                        .foregroundStyle(RevylBrandColor.textPrimary)
                                    Spacer()
                                    if repositoryFullName == chosenRepositoryFullName {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(RevylBrandColor.brand)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Every repository where an organization installed Revyl's GitHub App and you have access. The feed, weekly videos and inbox follow your choice.")
                    }
                }
            } else {
                Section {
                    ProgressView("Finding your repositories")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search repositories")
        .disabled(isChoosing)
        .scrollContentBackground(.hidden)
        .scrollContentCenteredInReadableContentColumn()
        .background(RevylBrandColor.surface)
        .navigationTitle("Repository")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadReachableRepositories() }
    }

    private func choose(_ repositoryFullName: String) {
        guard repositoryFullName != chosenRepositoryFullName else { return }
        isChoosing = true
        Task {
            await onChoose(repositoryFullName)
            isChoosing = false
        }
    }

    private func loadReachableRepositories() async {
        loadFailureMessage = nil
        do {
            let repositoryFullNames = try await accountAPI.fetchReachableRepositoryFullNames()
            if choosesDefaultRepositoryWhenReachable,
               let defaultRepositoryFullName = repositoryFullNames.first(where: {
                   $0.caseInsensitiveCompare(FeedRepositoryChoice.defaultRepositoryFullName) == .orderedSame
               }) {
                await onChoose(defaultRepositoryFullName)
                return
            }
            reachableRepositoryFullNames = repositoryFullNames
        } catch {
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                onSignInRejected(githubAPIError)
                return
            }
            loadFailureMessage = error.localizedDescription
        }
    }
}
