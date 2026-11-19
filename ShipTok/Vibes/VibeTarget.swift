import Foundation

// What a vibe goes on: a pull request, or a weekly edition's or feature's issue, which takes vibes the same way (AGENTS.md, "Vibes").
struct VibeTarget: Hashable {
    enum Kind: Hashable {
        case pullRequest
        case weeklyEdition
        case feature
    }

    let kind: Kind
    let threadID: String
    let number: Int
    let title: String
    let reference: String

    var analyticsSubject: ShipTokAnalyticsSubject {
        let analyticsSubjectKind: ShipTokAnalyticsSubject.Kind = switch kind {
        case .pullRequest: .pullRequest
        case .weeklyEdition: .weeklyEdition
        case .feature: .feature
        }
        return ShipTokAnalyticsSubject(kind: analyticsSubjectKind, nodeID: threadID, number: number)
    }

    init(pullRequest: PullRequest) {
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
        reference = weeklyEdition.reference
    }

    init(feature: Feature) {
        kind = .feature
        threadID = feature.id
        number = feature.number
        title = feature.title
        reference = feature.reference
    }
}
