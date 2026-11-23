import Foundation

enum FeedSwipeDirection: CaseIterable {
    case up
    case down
    case left
    case right

    var arrowSystemImageName: String {
        switch self {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        }
    }
}

enum FeedSwipeAction {
    case showNextPullRequest
    case showPreviousPullRequest
    case castGoodVibes
    case castBadVibes

    var castVibe: ShipTokVibe? {
        switch self {
        case .castGoodVibes: .good
        case .castBadVibes: .bad
        case .showNextPullRequest, .showPreviousPullRequest: nil
        }
    }

    var legendLabel: String {
        switch self {
        case .showNextPullRequest: "Next PR"
        case .showPreviousPullRequest: "Previous PR"
        case .castGoodVibes: "Good vibes"
        case .castBadVibes: "Bad vibes"
        }
    }
}

enum FeedSwipeGestureMapping {
    // Swipe directions are a product decision (AGENTS.md, "Swipe Gestures").
    static func action(for direction: FeedSwipeDirection) -> FeedSwipeAction {
        switch direction {
        case .up: .showNextPullRequest
        case .down: .showPreviousPullRequest
        case .right: .castGoodVibes
        case .left: .castBadVibes
        }
    }

    static func direction(for action: FeedSwipeAction) -> FeedSwipeDirection {
        guard let direction = FeedSwipeDirection.allCases.first(where: { self.action(for: $0) == action }) else {
            preconditionFailure("Every swipe action needs exactly one swipe direction")
        }
        return direction
    }
}
