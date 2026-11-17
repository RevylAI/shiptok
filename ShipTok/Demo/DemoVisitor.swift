import Foundation

// Someone looking around the demo feed before signing in, App Review included. Nothing of the visit outlives it (AGENTS.md, "Demo Mode").
struct DemoVisitor {
    let visitID: UUID
    let repositoryFullName: String
    let demoFeed: ShipTokDemoFeed
    let analytics: ShipTokAnalytics
    let hiddenPeopleStore: HiddenPeopleStore
}
