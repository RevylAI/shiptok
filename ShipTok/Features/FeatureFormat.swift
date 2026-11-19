import Foundation

// Reads a feature's description, in the "Features" format of docs/shiptok-format.md: its marker carries no date, since a feature dates from when its issue closed.
enum FeatureFormat {
    static let labelName = "shiptok-feature"

    private static let markerLine = "<!-- shiptok:feature -->"

    static func description(fromMarkdown markdown: String) -> PublishedIssueFormat.Description? {
        guard let publishedIssueDescription = PublishedIssueFormat.description(fromMarkdown: markdown),
              publishedIssueDescription.markerLine == markerLine
        else { return nil }
        return publishedIssueDescription
    }
}
