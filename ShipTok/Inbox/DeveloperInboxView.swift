import SwiftUI

struct DeveloperInboxView: View {
    let store: DeveloperInboxStore
    let onOpenPullRequest: (Int) -> Void

    init(store: DeveloperInboxStore, onOpenPullRequest: @escaping (Int) -> Void) {
        self.store = store
        self.onOpenPullRequest = onOpenPullRequest
    }

    var body: some View {
        NavigationStack {
            Group {
                if !store.hasLoaded, let errorMessage = store.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load your inbox", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { Task { await store.refresh() } }
                            .buttonStyle(.revylPrimary)
                    }
                    .centeredInReadableContentColumn()
                } else if !store.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.inboxItems.isEmpty {
                    ContentUnavailableView(
                        "Nothing yet",
                        systemImage: "tray",
                        description: Text("When teammates vibe, react to or comment on pull requests you merged, it lands here.")
                    )
                    .centeredInReadableContentColumn()
                } else {
                    List {
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
                            .listRowBackground(RevylBrandColor.surface)
                            .listRowSeparatorTint(RevylBrandColor.border)
                        }
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
        }
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
                Text("on #\(inboxItem.pullRequestNumber) \(inboxItem.pullRequestTitle)")
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
