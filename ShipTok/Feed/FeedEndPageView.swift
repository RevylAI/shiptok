import SwiftUI

// The page after a feed's last card: older posts loading, a failed load to retry, or the end of the repository's history (AGENTS.md, "Feed Order").
struct FeedEndPageView: View {
    let feedMode: FeedMode
    let repositoryFullName: String
    let showsOnlyPostsWithVideos: Bool
    let loadFailureMessage: String?
    let hasLoadedEveryPost: Bool
    let onRetry: () -> Void

    var body: some View {
        Group {
            if let loadFailureMessage {
                RevylContentUnavailableView(
                    systemImageName: "exclamationmark.triangle",
                    title: Text("Couldn't load more \(morePostsName)"),
                    message: Text(verbatim: loadFailureMessage),
                    actionTitle: Text("Try again"),
                    action: onRetry
                )
            } else if !hasLoadedEveryPost {
                FeedLoadingView(message: "Loading more \(morePostsName)…")
            } else {
                switch feedMode {
                case .open:
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's every open PR"),
                        message: Text("You've seen every open pull request in \(repositoryFullName) \(shownMediaDescription).")
                    )
                case .merged:
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's every merged PR"),
                        message: Text("You've seen every pull request merged into \(repositoryFullName) \(shownMediaDescription).")
                    )
                case .weekly:
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's every weekly video"),
                        message: Text("A new one lands after each week ends, Monday to Sunday.")
                    )
                case .features:
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's every feature video"),
                        message: Text("A new one lands when its issue closes.")
                    )
                }
            }
        }
        .background(RevylBrandColor.canvas)
    }

    private var morePostsName: String {
        switch feedMode {
        case .open: "open PRs"
        case .merged: "merged PRs"
        case .weekly: "weekly videos"
        case .features: "feature videos"
        }
    }

    private var shownMediaDescription: String {
        showsOnlyPostsWithVideos ? "that leads with a video" : "with a video, screenshot or GIF"
    }
}
