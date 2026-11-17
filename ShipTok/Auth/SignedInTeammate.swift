import Foundation

struct SignedInTeammate {
    // Work started for one sign-in can finish after it ended, so what it ends or deletes names the sign-in it ran for.
    let signInID = UUID()
    let user: GitHubUserIdentity
    let accountAPI: GitHubAccountAPI
    let accessTokenVault: GitHubAccessTokenVault
    let analytics: ShipTokAnalytics
    let hiddenPeopleStore: HiddenPeopleStore
}
