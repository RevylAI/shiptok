import SwiftUI

// Settings → Account's GitHub username row (AGENTS.md, "Settings").
struct GitHubAccountSettingRow: View {
    let store: GitHubAccountStore

    var body: some View {
        NavigationLink {
            GitHubAccountView(store: store)
        } label: {
            HStack(spacing: 8) {
                Text("GitHub username")
                    .foregroundStyle(RevylBrandColor.textPrimary)
                Spacer()
                if let githubAccountSetting = store.githubAccountSetting {
                    if let githubAccount = githubAccountSetting.githubAccount {
                        AvatarView(avatarURL: githubAccount.avatarURL, diameter: 24)
                        Text(verbatim: "@\(githubAccount.login)")
                            .foregroundStyle(RevylBrandColor.textMuted)
                    } else {
                        Text("Not set")
                            .foregroundStyle(RevylBrandColor.textMuted)
                    }
                } else if store.refreshFailureMessage != nil {
                    Text("Couldn't load")
                        .foregroundStyle(RevylBrandColor.warning)
                } else {
                    ProgressView()
                }
            }
        }
    }
}

// Sets, changes or removes the person's GitHub username. It names the GitHub account whose posts are theirs, and signs in to nothing (AGENTS.md, "Settings").
struct GitHubAccountView: View {
    let store: GitHubAccountStore
    @State private var enteredLogin = ""
    @State private var changeInProgress: GitHubAccountChange?

    private enum GitHubAccountChange {
        case save
        case remove
    }

    private var trimmedLogin: String { enteredLogin.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var savedGitHubAccount: GitHubAccount? { store.githubAccountSetting?.githubAccount }

    var body: some View {
        List {
            Section {
                if let savedGitHubAccount {
                    HStack(spacing: 12) {
                        AvatarView(avatarURL: savedGitHubAccount.avatarURL, diameter: 32)
                        Text(verbatim: "@\(savedGitHubAccount.login)")
                            .font(.headline)
                            .foregroundStyle(RevylBrandColor.textPrimary)
                    }
                } else if store.githubAccountSetting != nil {
                    Text("Not set")
                        .foregroundStyle(RevylBrandColor.textMuted)
                } else if let refreshFailureMessage = store.refreshFailureMessage {
                    Text("Couldn't load your GitHub username: \(refreshFailureMessage)")
                        .foregroundStyle(RevylBrandColor.warning)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("Your GitHub account")
            } footer: {
                Text("You're the developer on pull requests this GitHub account opens: their feedback reaches your inbox and notifications. Each GitHub account can belong to one person in your organization, and its owners and admins can change or remove it. This isn't a GitHub sign-in.")
            }
            Section {
                TextField("GitHub username", text: $enteredLogin)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
                    .disabled(store.isChanging)
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text("Save")
                        if changeInProgress == .save {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(store.isChanging || trimmedLogin.isEmpty)
            } header: {
                Text(savedGitHubAccount == nil ? "Set your username" : "Change it")
            } footer: {
                if let changeFailureMessage = store.changeFailureMessage {
                    Text(changeFailureMessage)
                        .foregroundStyle(RevylBrandColor.warning)
                }
            }
            if savedGitHubAccount != nil {
                Section {
                    Button(role: .destructive) {
                        Task { await remove() }
                    } label: {
                        HStack {
                            Text("Remove")
                            if changeInProgress == .remove {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.isChanging)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollContentCenteredInReadableContentColumn()
        .background(RevylBrandColor.surface)
        .navigationTitle("GitHub username")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.changeFailureMessage = nil
            await store.refresh()
        }
    }

    private func save() async {
        let login = trimmedLogin
        guard !login.isEmpty, changeInProgress == nil else { return }
        changeInProgress = .save
        defer { changeInProgress = nil }
        if await store.saveGitHubAccount(login: login) {
            enteredLogin = ""
        }
    }

    private func remove() async {
        guard changeInProgress == nil else { return }
        changeInProgress = .remove
        defer { changeInProgress = nil }
        _ = await store.removeGitHubAccount()
    }
}
