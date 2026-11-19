import SwiftUI

// Report each description or comment a surface shows on GitHub, or hide its poster (AGENTS.md, "Report And Hide").
struct GitHubPostedContentModeration {
    let reportableContents: [GitHubPostedContent]
    let onReport: (GitHubPostedContent) -> Void
    let onHide: (GitHubPostedContent) -> Void
}

struct GitHubPostedContentModerationMenu<MenuLabel: View>: View {
    let moderation: GitHubPostedContentModeration
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
            ForEach(moderation.reportableContents) { postedContent in
                Section(sectionTitle(for: postedContent)) {
                    GitHubPostedContentModerationButtons(postedContent: postedContent, onReport: moderation.onReport, onHide: moderation.onHide)
                }
            }
        } label: {
            label()
        }
        .menuOrder(.fixed)
    }

    private func sectionTitle(for postedContent: GitHubPostedContent) -> String {
        switch (postedContent.kind, postedContent.postedOn?.kind) {
        case (.comment, _): "Comment by @\(postedContent.postedBy.login)"
        case (.reaction, _): "Reaction by @\(postedContent.postedBy.login)"
        case (.description, .weeklyEdition): "Weekly video by @\(postedContent.postedBy.login)"
        case (.description, .feature): "Feature video by @\(postedContent.postedBy.login)"
        case (.description, _): "Pull request by @\(postedContent.postedBy.login)"
        }
    }
}

// GitHub's report form takes a description or comment but not a reaction, so a reaction's poster can only be hidden.
struct GitHubPostedContentModerationButtons: View {
    let postedContent: GitHubPostedContent
    let onReport: (GitHubPostedContent) -> Void
    let onHide: (GitHubPostedContent) -> Void

    var body: some View {
        if postedContent.kind != .reaction {
            Button { onReport(postedContent) } label: {
                Label("Report on GitHub", systemImage: "flag")
            }
        }
        Button(role: .destructive) { onHide(postedContent) } label: {
            Label("Hide @\(postedContent.postedBy.login)", systemImage: "eye.slash")
        }
    }
}
