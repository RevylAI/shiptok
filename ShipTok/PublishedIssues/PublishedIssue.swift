import Foundation

// A closed issue ShipTok shows as a card of its own, in its format and with media: a weekly edition or a feature (docs/shiptok-format.md).
protocol PublishedIssue: GitHubCommentThread, Identifiable {
    var reactions: GitHubReactionSummary { get set }
    // How a sentence names it, as in "Couldn't like the week of Nov 9–15."
    var reference: String { get }
    static var analyticsSubjectKind: ShipTokAnalyticsSubject.Kind { get }
    static func fetchEveryPublishedIssue(from githubAPIClient: GitHubAPIClient) async throws -> [Self]
}

extension WeeklyEdition: PublishedIssue {
    static var analyticsSubjectKind: ShipTokAnalyticsSubject.Kind { .weeklyEdition }

    var reference: String { "the week of \(weekDatesText)" }

    static func fetchEveryPublishedIssue(from githubAPIClient: GitHubAPIClient) async throws -> [WeeklyEdition] {
        try await githubAPIClient.fetchWeeklyEditions()
    }
}

extension Feature: PublishedIssue {
    static var analyticsSubjectKind: ShipTokAnalyticsSubject.Kind { .feature }

    var reference: String { "the feature “\(title)”" }

    static func fetchEveryPublishedIssue(from githubAPIClient: GitHubAPIClient) async throws -> [Feature] {
        try await githubAPIClient.fetchFeatures()
    }
}
