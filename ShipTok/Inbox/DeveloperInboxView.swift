import SwiftUI

struct DeveloperInboxView: View {
    let store: DeveloperInboxStore
    let viewerRevylUserID: String
    let onOpenItem: (ShipTokInboxItem) -> Void
    let onHide: (ReportableContent) -> Void
    let onShowFeed: (() -> Void)?
    @State private var contentAwaitingHideConfirmation: ReportableContent?
    @State private var reportConfirmationMessage: String?
    @State private var reportFailureMessage: String?
    @Environment(\.shipTokAnalytics) private var analytics

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
                } else if store.items.isEmpty {
                    RevylContentUnavailableView(
                        systemImageName: "tray",
                        title: Text("Nothing yet"),
                        message: Text("When teammates like, react to, vibe or comment on your pull requests and videos, or reply to your comments, it lands here.")
                    )
                } else {
                    List {
                        Section {
                            if let errorMessage = store.errorMessage {
                                Label("Couldn't refresh your inbox: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(RevylBrandColor.warning)
                                    .listRowBackground(RevylBrandColor.surface)
                            }
                            ForEach(store.items) { inboxItem in
                                Button { onOpenItem(inboxItem) } label: {
                                    DeveloperInboxRow(inboxItem: inboxItem, isUnread: store.isUnread(inboxItem), viewerRevylUserID: viewerRevylUserID)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    ContentModerationButtons(
                                        reportableContent: ReportableContent(inboxItem: inboxItem),
                                        onReport: report,
                                        onHide: { contentAwaitingHideConfirmation = $0 }
                                    )
                                }
                                .listRowBackground(RevylBrandColor.surface)
                                .listRowSeparatorTint(RevylBrandColor.border)
                            }
                            if store.hasMorePages {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .listRowBackground(RevylBrandColor.surface)
                                    .onAppear { Task { await store.loadMore() } }
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
        .confirmingHide(of: $contentAwaitingHideConfirmation, onHide: onHide)
        .alert("Reported", isPresented: Binding(get: { reportConfirmationMessage != nil }, set: { if !$0 { reportConfirmationMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reportConfirmationMessage ?? "")
        }
        .alert("Couldn't report it", isPresented: Binding(get: { reportFailureMessage != nil }, set: { if !$0 { reportFailureMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reportFailureMessage ?? "")
        }
        .onAppear { analytics?.capture(.inboxOpened(unreadCount: store.unreadCount)) }
        .task { await store.refresh() }
        .onDisappear { Task { await store.markAllItemsRead() } }
    }

    private func report(_ reportableContent: ReportableContent) {
        Task {
            do {
                try await store.report(reportableContent)
                analytics?.capture(.contentReported(reportableContent, control: .inboxRow))
                reportConfirmationMessage = "Thanks. Your organization's owners and admins will look at it."
            } catch {
                reportFailureMessage = error.localizedDescription
            }
        }
    }
}

private struct DeveloperInboxRow: View {
    let inboxItem: ShipTokInboxItem
    let isUnread: Bool
    let viewerRevylUserID: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(avatarURL: inboxItem.actor.avatarURL, diameter: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Text(verbatim: inboxItem.actor.displayName).bold()) \(actionDescription)")
                    .font(.subheadline)
                    .foregroundStyle(RevylBrandColor.textPrimary)
                if let quotedText = inboxItem.text?.trimmingCharacters(in: .whitespacesAndNewlines), !quotedText.isEmpty {
                    Text(verbatim: "“\(quotedText)”")
                        .font(.subheadline)
                        .foregroundStyle(RevylBrandColor.textBody)
                        .lineLimit(3)
                }
                Text(verbatim: postDescription)
                    .font(.caption)
                    .foregroundStyle(RevylBrandColor.textMuted)
                    .lineLimit(1)
                LiveRelativeTimeText(date: inboxItem.createdAt)
                    .font(.caption2)
                    .foregroundStyle(RevylBrandColor.textSubtle)
            }
            Spacer(minLength: 0)
            if isUnread {
                Circle().fill(RevylBrandColor.brand).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var actionDescription: String {
        switch inboxItem.kind {
        case .vibe: inboxItem.vibe == .bad ? "gave it bad vibes" : "gave it good vibes"
        case .comment: "commented"
        case .reply: replyAnswersViewer ? "replied to your comment" : "replied in your thread"
        case .reaction: inboxItem.reaction.map { $0 == .heart ? "liked it" : "reacted \($0.emoji)" } ?? "reacted"
        }
    }

    private var replyAnswersViewer: Bool {
        inboxItem.replyToAuthor.map { $0.revylUserID == viewerRevylUserID } ?? true
    }

    private var postDescription: String {
        switch inboxItem.post.kind {
        case .pullRequest: "on #\(inboxItem.post.githubIssueNumber) \(inboxItem.post.title)"
        case .weeklyEdition, .feature: "on “\(inboxItem.post.title)”"
        }
    }
}
