import Foundation

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

    var mediaCache: FeedViewerMediaCache {
        switch self {
        case .teammate(let teammate): teammate.mediaCache
        case .demoVisitor(let demoVisitor): demoVisitor.mediaCache
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
