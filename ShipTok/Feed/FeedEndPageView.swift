import SwiftUI

// The page after a feed's last card: older pull requests loading, a failed load to retry, or the end of the repository's history (AGENTS.md, "Feed Order").
struct FeedEndPageView: View {
    let feed: PullRequestFeed
    let repositoryFullName: String
    let loadFailureMessage: String?
    let hasLoadedEveryPullRequest: Bool
    let onRetry: () -> Void

    var body: some View {
        Group {
            if let loadFailureMessage {
                RevylContentUnavailableView(
                    systemImageName: "exclamationmark.triangle",
                    title: Text(feed == .merged ? "Couldn't load older merged PRs" : "Couldn't load more open PRs"),
                    message: Text(verbatim: loadFailureMessage),
                    actionTitle: Text("Try again"),
                    action: onRetry
                )
            } else if !hasLoadedEveryPullRequest {
                FeedLoadingView(message: feed == .merged ? "Loading older merged PRs…" : "Loading more open PRs…")
            } else {
                switch feed {
                case .open:
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's every open PR"),
                        message: Text("You've seen every open pull request in \(repositoryFullName) with a video, screenshot or GIF.")
                    )
                case .merged:
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's every merged PR"),
                        message: Text("You've seen every pull request merged into \(repositoryFullName) with a video, screenshot or GIF.")
                    )
                }
            }
        }
        .background(RevylBrandColor.canvas)
    }
}
