import Foundation

// Someone looking around the demo feed before signing in, App Review included. Nothing of the visit outlives it (shiptok/AGENTS.md, "Demo Mode").
struct DemoVisitor {
    let visitID: UUID
    let repositoryFullName: String
    let demoFeed: ShipTokDemoFeed
    let analytics: ShipTokAnalytics
    let hiddenPeopleStore: HiddenPeopleStore
}

// What a demo visitor tried that posts to GitHub as them, so it asks them to sign in first.
enum DemoSignInPromptAction: String, Identifiable, Sendable {
    case like
    case reaction
    case comment
    case vibe
    case report
    case inbox

    var id: String { rawValue }

    var promptTitle: String {
        switch self {
        case .like: "Sign in to like"
        case .reaction: "Sign in to react"
        case .comment: "Sign in to comment"
        case .vibe: "Sign in to send vibes"
        case .report: "Sign in to report"
        case .inbox: "Sign in for your inbox"
        }
    }
}

// Who the feed is for: a signed-in teammate, or a demo visitor, who reads the demo feed and is asked to sign in for anything that writes.
enum FeedViewer {
    case teammate(SignedInTeammate)
    case demoVisitor(DemoVisitor)

    var analytics: ShipTokAnalytics {
        switch self {
        case .teammate(let teammate): teammate.analytics
        case .demoVisitor(let demoVisitor): demoVisitor.analytics
        }
    }

    var hiddenPeopleStore: HiddenPeopleStore {
        switch self {
        case .teammate(let teammate): teammate.hiddenPeopleStore
        case .demoVisitor(let demoVisitor): demoVisitor.hiddenPeopleStore
        }
    }

    var teammate: SignedInTeammate? {
        guard case .teammate(let teammate) = self else { return nil }
        return teammate
    }

    var githubLogin: String? {
        teammate?.user.githubLogin
    }
}
