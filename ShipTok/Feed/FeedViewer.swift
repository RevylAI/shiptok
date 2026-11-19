import Foundation

// Who the feed is for: a teammate who connected GitHub, or a demo visitor, signed in to Revyl without a connected GitHub account, who reads the demo feed and is asked to connect GitHub for anything that writes.
enum FeedViewer {
    case teammate(SignedInTeammate)
    case demoVisitor(DemoVisitor)

    var analytics: ShipTokAnalytics {
        switch self {
        case .teammate(let teammate): teammate.analytics
        case .demoVisitor(let demoVisitor): demoVisitor.analytics
        }
    }

    var mediaCache: FeedViewerMediaCache {
        switch self {
        case .teammate(let teammate): teammate.mediaCache
        case .demoVisitor(let demoVisitor): demoVisitor.mediaCache
        }
    }

    var feedWork: FeedViewerWork {
        switch self {
        case .teammate(let teammate): teammate.feedWork
        case .demoVisitor(let demoVisitor): demoVisitor.feedWork
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
