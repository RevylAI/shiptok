import SwiftUI

struct RootView: View {
    let signInSession: GitHubSignInSession

    var body: some View {
        ZStack {
            RevylBrandColor.canvas.ignoresSafeArea()
            switch signInSession.phase {
            case .restoring:
                ProgressView().controlSize(.large)
            case .signedOut(let message):
                SignInView(signInSession: signInSession, message: message)
            case .exploringDemo(let demoVisitor, _):
                // The demo has one repository and no account to lose access with, so it never chooses another or loses this one.
                FeedView(
                    viewer: .demoVisitor(demoVisitor),
                    repositoryFullName: demoVisitor.repositoryFullName,
                    signInSession: signInSession,
                    onChooseRepository: { _ in },
                    onFeedRepositoryLost: { _ in }
                )
                .id(demoVisitor.visitID)
            case .signedIn(let teammate):
                SignedInView(teammate: teammate, signInSession: signInSession)
                    .id(teammate.user.githubUserID)
            }
        }
        .task { await signInSession.restoreSavedSession() }
    }
}

private struct SignedInView: View {
    let teammate: SignedInTeammate
    let signInSession: GitHubSignInSession
    @AppStorage private var chosenRepositoryFullName: String?
    @State private var lostRepositoryMessage: String?
    @State private var showsAccount = false

    init(teammate: SignedInTeammate, signInSession: GitHubSignInSession) {
        self.teammate = teammate
        self.signInSession = signInSession
        _chosenRepositoryFullName = AppStorage(FeedRepositoryChoice.defaultsKey(githubUserID: teammate.user.githubUserID))
    }

    var body: some View {
        if let chosenRepositoryFullName {
            FeedView(
                viewer: .teammate(teammate),
                repositoryFullName: chosenRepositoryFullName,
                signInSession: signInSession,
                onChooseRepository: { self.chosenRepositoryFullName = $0 },
                onFeedRepositoryLost: { message in
                    lostRepositoryMessage = message
                    self.chosenRepositoryFullName = nil
                }
            )
            .id(chosenRepositoryFullName)
        } else {
            NavigationStack {
                FeedRepositoryPickerView(
                    accountAPI: teammate.accountAPI,
                    chosenRepositoryFullName: nil,
                    message: lostRepositoryMessage,
                    choosesDefaultRepositoryWhenReachable: lostRepositoryMessage == nil,
                    onSignInRejected: { signInSession.handleRejectedGitHubAccess($0, endingSignInID: teammate.signInID) },
                    onChoose: { repositoryFullName in
                        lostRepositoryMessage = nil
                        chosenRepositoryFullName = repositoryFullName
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Account", systemImage: "person.crop.circle") { showsAccount = true }
                    }
                }
            }
            .sheet(isPresented: $showsAccount) {
                NavigationStack {
                    List {
                        AccountActionsSections(signInSession: signInSession)
                    }
                    .scrollContentBackground(.hidden)
                    .background(RevylBrandColor.surface)
                    .navigationTitle("@\(teammate.user.githubLogin)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsAccount = false }
                        }
                    }
                }
            }
        }
    }
}
