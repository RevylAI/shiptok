import SwiftUI

struct DeveloperInboxView: View {
    let store: DeveloperInboxStore
    let onOpenPullRequest: (Int) -> Void
    let onReport: (GitHubPostedContent) -> Void
    let onHide: (GitHubPostedContent) -> Void
    let onShowFeed: (() -> Void)?
    @State private var postedContentAwaitingHideConfirmation: GitHubPostedContent?

    init(
        store: DeveloperInboxStore,
        onOpenPullRequest: @escaping (Int) -> Void,
        onReport: @escaping (GitHubPostedContent) -> Void,
        onHide: @escaping (GitHubPostedContent) -> Void,
        onShowFeed: (() -> Void)?
    ) {
        self.store = store
        self.onOpenPullRequest = onOpenPullRequest
        self.onReport = onReport
        self.onHide = onHide
        self.onShowFeed = onShowFeed
    }

    var body: some View {
        NavigationStack {
            Group {
                if !store.hasLoaded, let errorMessage = store.errorMessage {
                    RevylContentUnavailableView(
                        systemImageName: "exclamationmark.triangle",
                        title: Text("Couldn't load your inbox"),
                        message: Text(verbatim: errorMessage),
                        actionTitle: Text("Try again"),
                        action: { Task { await store.refresh() } }
                    )
                } else if !store.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.inboxItems.isEmpty {
                    RevylContentUnavailableView(
                        systemImageName: "tray",
                        title: Text("Nothing yet"),
                        message: Text("When teammates vibe, react to or comment on your open or merged pull requests, it lands here.")
                    )
                } else {
                    List {
                        Section {
                            if let errorMessage = store.errorMessage {
                                Label("Couldn't refresh from GitHub: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(RevylBrandColor.warning)
                                    .listRowBackground(RevylBrandColor.surface)
                            }
                            ForEach(store.inboxItems) { inboxItem in
                                Button { onOpenPullRequest(inboxItem.pullRequestNumber) } label: {
                                    DeveloperInboxRow(inboxItem: inboxItem, isUnseen: inboxItem.occurredAt > store.lastSeenOccurredAt)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if let postedContent = inboxItem.postedContent {
                                        GitHubPostedContentModerationButtons(
                                            postedContent: postedContent,
                                            onReport: onReport,
                                            onHide: { postedContentAwaitingHideConfirmation = $0 }
                                        )
                                    }
                                }
                                .listRowBackground(RevylBrandColor.surface)
                                .listRowSeparatorTint(RevylBrandColor.border)
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollContentCenteredInReadableContentColumn()
                    .refreshable { await store.refresh() }
                }
            }
            .background(RevylBrandColor.surface)
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .backToFeedToolbarItem(onShowFeed)
        }
        .confirmingHide(of: $postedContentAwaitingHideConfirmation, onHide: onHide)
        .task { await store.refresh() }
        .onDisappear { store.markAllItemsSeen() }
    }
}

private struct DeveloperInboxRow: View {
    let inboxItem: DeveloperInboxItem
    let isUnseen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GitHubAvatarView(avatarURL: inboxItem.actor?.avatarURL, diameter: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Text("@\(inboxItem.actor?.login ?? "ghost")").bold()) \(actionDescription)")
                    .font(.subheadline)
                    .foregroundStyle(RevylBrandColor.textPrimary)
                if !quotedVisibleMarkdown.isEmpty {
                    Text(AttributedString("“") + GitHubCommentBodyText.attributedText(fromVisibleMarkdown: quotedVisibleMarkdown) + AttributedString("”"))
                        .font(.subheadline)
                        .foregroundStyle(RevylBrandColor.textBody)
                        .lineLimit(3)
                }
                Text(verbatim: "on #\(inboxItem.pullRequestNumber) \(inboxItem.pullRequestTitle)")
                    .font(.caption)
                    .foregroundStyle(RevylBrandColor.textMuted)
                    .lineLimit(1)
                LiveRelativeTimeText(date: inboxItem.occurredAt)
                    .font(.caption2)
                    .foregroundStyle(RevylBrandColor.textSubtle)
            }
            Spacer(minLength: 0)
            if isUnseen {
                Circle().fill(RevylBrandColor.brand).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var actionDescription: String {
        switch inboxItem.action {
        case .vibe(.good, _): "gave it good vibes"
        case .vibe(.bad, _): "gave it bad vibes"
        case .comment: "commented"
        case .reaction(.heart): "liked it"
        case .reaction(let reaction): "reacted \(reaction.emoji)"
        }
    }

    private var quotedVisibleMarkdown: String {
        switch inboxItem.action {
        case .vibe(_, let feedbackText): GitHubCommentBodyText.visibleMarkdown(fromBodyMarkdown: feedbackText)
        case .comment(let bodyMarkdown): GitHubCommentBodyText.visibleMarkdown(fromBodyMarkdown: bodyMarkdown)
        case .reaction: ""
        }
    }
}
