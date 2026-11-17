import Foundation

struct SignedInTeammate {
    let user: GitHubUserIdentity
    let accountAPI: GitHubAccountAPI
    let accessTokenVault: GitHubAccessTokenVault
    let analytics: ShipTokAnalytics
    let hiddenPeopleStore: HiddenPeopleStore
}
