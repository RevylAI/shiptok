import SwiftUI

// The repository whose feed the person watches, kept on this iPhone per Revyl account (AGENTS.md, "Repositories").
struct FeedRepositoryChoice: Codable, Equatable {
    let githubRepositoryID: Int64
    let fullName: String

    private enum CodingKeys: String, CodingKey {
        case githubRepositoryID = "github_repository_id"
        case fullName = "full_name"
    }

    init(repository: ShipTokRepository) {
        githubRepositoryID = repository.githubRepositoryID
        fullName = repository.fullName
    }

    static func load(revylUserID: String) -> FeedRepositoryChoice? {
        UserDefaults.standard.data(forKey: defaultsKey(revylUserID: revylUserID)).flatMap { try? JSONDecoder().decode(FeedRepositoryChoice.self, from: $0) }
    }

    func save(revylUserID: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey(revylUserID: revylUserID))
    }

    static func remove(revylUserID: String) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(revylUserID: revylUserID))
    }

    private static func defaultsKey(revylUserID: String) -> String {
        "feed-repository-revyl-\(revylUserID)"
    }
}

struct FeedRepositoryPickerView: View {
    let api: RevylShipTokAPI
    let chosenRepositoryID: Int64?
    let message: String?
    // The first choice of a person whose organization's GitHub App covers one repository is made for them.
    let choosesOnlyRepositoryAutomatically: Bool
    let onChoose: @MainActor (ShipTokRepository) async -> Void
    @State private var repositories: [ShipTokRepository]?
    @State private var loadFailureMessage: String?
    @State private var searchText = ""
    @State private var isChoosing = false

    private var matchingRepositories: [ShipTokRepository] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return repositories ?? [] }
        return (repositories ?? []).filter { $0.fullName.localizedCaseInsensitiveContains(trimmedSearchText) }
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
                        Task { await loadRepositories() }
                    }
                }
            } else if let repositories {
                if repositories.isEmpty {
                    Section {
                        Text("Your organization hasn't installed Revyl's GitHub App on any repository yet. Ask an admin to install it on the repositories ShipTok should show.")
                            .foregroundStyle(RevylBrandColor.textMuted)
                        Link("How to install Revyl's GitHub App", destination: URL(string: "https://docs.revyl.com/integrations/github")!)
                        Button("Check again") {
                            Task { await loadRepositories() }
                        }
                    }
                } else {
                    Section {
                        ForEach(matchingRepositories) { repository in
                            Button {
                                choose(repository)
                            } label: {
                                HStack {
                                    Text(verbatim: repository.fullName)
                                        .foregroundStyle(RevylBrandColor.textPrimary)
                                    if repository.isPrivate {
                                        Image(systemName: "lock.fill")
                                            .font(.caption)
                                            .foregroundStyle(RevylBrandColor.textMuted)
                                            .accessibilityLabel("Private")
                                    }
                                    Spacer()
                                    if repository.githubRepositoryID == chosenRepositoryID {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(RevylBrandColor.brand)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Every repository your organization's Revyl GitHub App covers. The feed, weekly and feature videos follow your choice.")
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
        .task { await loadRepositories() }
    }

    private func choose(_ repository: ShipTokRepository) {
        guard repository.githubRepositoryID != chosenRepositoryID else { return }
        isChoosing = true
        Task {
            await onChoose(repository)
            isChoosing = false
        }
    }

    private func loadRepositories() async {
        loadFailureMessage = nil
        do {
            let fetchedRepositories = try await api.fetchRepositories()
            if choosesOnlyRepositoryAutomatically, fetchedRepositories.count == 1 {
                await onChoose(fetchedRepositories[0])
                return
            }
            repositories = fetchedRepositories
        } catch {
            if error.isTaskCancellation { return }
            if let apiError = error as? RevylShipTokAPIError, apiError.refusesSignIn { return }
            loadFailureMessage = error.localizedDescription
        }
    }
}
