import Foundation

struct SignedInTeammate {
    // Work started for one sign-in can finish after it ended, so what it ends or deletes names the sign-in it ran for.
    let signInID: UUID
    var account: RevylAccount
    let api: RevylShipTokAPI
    let analytics: ShipTokAnalytics
    let hiddenPeopleStore: HiddenPeopleStore
    let mediaCache: FeedViewerMediaCache
    let feedWork: FeedViewerWork
}
