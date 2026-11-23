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
            case .signedIn(let teammate):
                SignedInView(teammate: teammate, signInSession: signInSession)
                    .id("\(teammate.account.revylUserID) \(teammate.account.organization.orgID)")
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
    @State private var chosenRepository: FeedRepositoryChoice?
    @State private var lostRepositoryMessage: String?
    @State private var showsAccount = false

    init(teammate: SignedInTeammate, signInSession: ShipTokSignInSession) {
        self.teammate = teammate
        self.signInSession = signInSession
        _chosenRepository = State(initialValue: FeedRepositoryChoice.load(revylUserID: teammate.account.revylUserID))
    }

    var body: some View {
        if let chosenRepository {
            FeedView(
                viewer: teammate,
                repository: chosenRepository,
                signInSession: signInSession,
                onChooseRepository: choose,
                onRepositoryLost: { message in
                    lostRepositoryMessage = message
                    FeedRepositoryChoice.remove(revylUserID: teammate.account.revylUserID)
                    self.chosenRepository = nil
                }
            )
            .id(chosenRepository.githubRepositoryID)
        } else {
            NavigationStack {
                FeedRepositoryPickerView(
                    api: teammate.api,
                    chosenRepositoryID: nil,
                    message: lostRepositoryMessage,
                    choosesOnlyRepositoryAutomatically: lostRepositoryMessage == nil,
                    onChoose: { repository in
                        lostRepositoryMessage = nil
                        choose(repository)
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
                    .navigationTitle(Text(verbatim: teammate.account.displayName))
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

    private func choose(_ repository: ShipTokRepository) {
        let repositoryChoice = FeedRepositoryChoice(repository: repository)
        repositoryChoice.save(revylUserID: teammate.account.revylUserID)
        chosenRepository = repositoryChoice
    }
}
