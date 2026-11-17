import Foundation

// What a vibe goes on: a merged pull request, or a weekly edition's issue, which takes vibes the same way (shiptok/AGENTS.md, "Vibes").
struct VibeTarget: Hashable {
    enum Kind: Hashable {
        case pullRequest
        case weeklyEdition
    }

    let kind: Kind
    let threadID: String
    let number: Int
    let title: String
    let reference: String

    var analyticsSubject: ShipTokAnalyticsSubject {
        ShipTokAnalyticsSubject(kind: kind == .pullRequest ? .pullRequest : .weeklyEdition, nodeID: threadID, number: number)
    }

    init(pullRequest: MergedPullRequest) {
        kind = .pullRequest
        threadID = pullRequest.id
        number = pullRequest.number
        title = pullRequest.title
        reference = "#\(pullRequest.number)"
    }

    init(weeklyEdition: WeeklyEdition) {
        kind = .weeklyEdition
        threadID = weeklyEdition.id
        number = weeklyEdition.number
        title = weeklyEdition.title
        reference = "the week of \(weeklyEdition.weekDatesText)"
    }
}
