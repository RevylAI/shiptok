import SwiftUI

struct RootView: View {
    let signInSession: ShipTokSignInSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            RevylBrandColor.canvas.ignoresSafeArea()
            switch signInSession.phase {
            case .restoring:
                ProgressView().controlSize(.large)
            case .signedOut(let firstScreenVisit):
                FirstScreenView(signInSession: signInSession, firstScreenVisit: firstScreenVisit)
                    .id(firstScreenVisit.visitID)
            case .connectingGitHub(let connectGitHubVisit):
                ConnectGitHubView(signInSession: signInSession, connectGitHubVisit: connectGitHubVisit)
                    .id(connectGitHubVisit.visitID)
            case .signedIn(let teammate):
                SignedInView(teammate: teammate, signInSession: signInSession)
                    .id(teammate.user.githubUserID)
            }
        }
        .task {
            await signInSession.restoreSavedSession()
            await signInSession.verifyRevylSignIn()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            guard newScenePhase == .active else { return }
            Task { await signInSession.verifyRevylSignIn() }
        }
    }
}

private struct SignedInView: View {
    let teammate: SignedInTeammate
    let signInSession: ShipTokSignInSession
    @AppStorage private var chosenRepositoryFullName: String?
    @State private var lostRepositoryMessage: String?
    @State private var showsAccount = false

    init(teammate: SignedInTeammate, signInSession: ShipTokSignInSession) {
        self.teammate = teammate
        self.signInSession = signInSession
        _chosenRepositoryFullName = AppStorage(FeedRepositoryChoice.defaultsKey(githubUserID: teammate.user.githubUserID))
    }

    var body: some View {
        if let chosenRepositoryFullName {
            FeedView(
                viewer: teammate,
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
