import Foundation

// Someone signed in to Revyl looking around the demo feed until they connect GitHub, App Review included. Nothing of the visit outlives it (AGENTS.md, "Demo Mode").
struct DemoVisitor {
    let visitID: UUID
    let repositoryFullName: String
    let demoFeed: ShipTokDemoFeed
    let analytics: ShipTokAnalytics
    let hiddenPeopleStore: HiddenPeopleStore
    let mediaCache: FeedViewerMediaCache
    let feedWork: FeedViewerWork
}
