import SwiftUI
import UIKit

// At its partial detent the sheet draws its content at about 96% scale, so 48 pt still reaches 44 pt on screen.
private let commentsSheetMinimumTapTargetSidePoints: CGFloat = 48

struct PullRequestCommentsSheet<Thread: GitHubCommentThread>: View {

    // A demo visitor has none, and is asked to sign in for anything that posts to GitHub.
    let viewer: GitHubUserIdentity?
    private let signInSession: GitHubSignInSession
    private let hiddenPeopleStore: HiddenPeopleStore
    private let analytics: ShipTokAnalytics
    private let analyticsSubject: ShipTokAnalyticsSubject
    @State private var commentsStore: PullRequestCommentsStore<Thread>
    @State private var draftBodyMarkdown = ""
    @State private var commentIDAwaitingAction: String?
    @State private var commentAwaitingDeletion: PullRequestComment?
    @State private var postedContentAwaitingHideConfirmation: GitHubPostedContent?
    @State private var demoSignInPromptAction: DemoSignInPromptAction?
    @State private var selectedPresentationDetent: PresentationDetent = .fraction(0.72)
    @FocusState private var isComposerFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(
        thread: Thread,
        viewer: GitHubUserIdentity?,
        signInSession: GitHubSignInSession,
        hiddenPeopleStore: HiddenPeopleStore,
        githubAPIClient: GitHubAPIClient,
        analytics: ShipTokAnalytics,
        analyticsSubject: ShipTokAnalyticsSubject,
        fetchLatestThread: @escaping (Int) async throws -> Thread,
        onThreadChanged: @escaping (Thread) -> Void
    ) {
        self.viewer = viewer
        self.signInSession = signInSession
        self.hiddenPeopleStore = hiddenPeopleStore
        self.analytics = analytics
        self.analyticsSubject = analyticsSubject
        _commentsStore = State(initialValue: PullRequestCommentsStore(
            thread: thread,
            githubAPIClient: githubAPIClient,
            analytics: analytics,
            analyticsSubject: analyticsSubject,
            fetchLatestThread: fetchLatestThread,
            onThreadChanged: onThreadChanged
        ))
    }

    private var trimmedDraft: String {
        draftBodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var commentAwaitingAction: PullRequestComment? {
        commentIDAwaitingAction.flatMap { commentID in commentsStore.thread.comments.first { $0.id == commentID } }
    }

    var body: some View {
        let commentsByPeopleNewestFirst = Array(commentsStore.thread.comments.filter { $0.isWrittenByPerson && !hiddenPeopleStore.isHidden($0.author) }.reversed())
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                ZStack {
                    Text(headerTitle(commentsByPeople: commentsByPeopleNewestFirst))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(RevylBrandColor.textPrimary)
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.subheadline.weight(.bold))
                                .frame(width: commentsSheetMinimumTapTargetSidePoints, height: commentsSheetMinimumTapTargetSidePoints)
                                .contentShape(Rectangle())
                        }
                        .foregroundStyle(RevylBrandColor.textMuted)
                        .accessibilityLabel("Close comments")
                    }
                }
                .padding(.vertical, -1)
                Divider().overlay(RevylBrandColor.border)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PullRequestCommentRow.metaTapTargetOverhangPoints) {
                        if let refreshFailureMessage = commentsStore.refreshFailureMessage {
                            Label("Couldn't refresh from GitHub: \(refreshFailureMessage)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(RevylBrandColor.warning)
                        }
                        if commentsByPeopleNewestFirst.isEmpty {
                            Text("No comments yet. Say what you think of this one.")
                                .font(.subheadline)
                                .foregroundStyle(RevylBrandColor.textMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(commentsByPeopleNewestFirst) { comment in
                            PullRequestCommentRow(
                                comment: comment,
                                attachedMediaItems: attachedMediaItems(of: comment),
                                bodyLineLimit: nil,
                                onReply: {
                                    guard commentIDAwaitingAction == nil else { return }
                                    startReply(to: comment)
                                },
                                onToggleReaction: { reaction in
                                    guard commentIDAwaitingAction == nil else { return }
                                    toggleReaction(reaction, on: comment)
                                },
                                onShowActions: { showActions(for: comment) }
                            )
                            .id(comment.id)
                        }
                    }
                    .padding(16)
                    .centeredInReadableContentColumn()
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer(scrollProxy: scrollProxy)
                }
            }
        }
        .background(RevylBrandColor.surface)
        .overlay {
            if let commentAwaitingAction {
                PullRequestCommentActionsOverlay(
                    comment: commentAwaitingAction,
                    attachedMediaItems: attachedMediaItems(of: commentAwaitingAction),
                    onToggleReaction: { reaction in toggleReaction(reaction, on: commentAwaitingAction) },
                    onReply: { startReply(to: commentAwaitingAction) },
                    onCopy: {
                        UIPasteboard.general.string = GitHubCommentBodyText.visibleMarkdown(fromBodyMarkdown: commentAwaitingAction.bodyMarkdown)
                    },
                    onOpenOnGitHub: { openURL(commentAwaitingAction.url) },
                    reportableContent: reportableContent(of: commentAwaitingAction),
                    onReport: { postedContent in
                        guard viewer != nil else { return promptSignIn(for: .report) }
                        analytics.capture(.contentReportOpened(postedContent, control: .commentActions))
                        openURL(postedContent.githubReportURL)
                    },
                    onHide: { postedContent in postedContentAwaitingHideConfirmation = postedContent },
                    onDelete: { commentAwaitingDeletion = commentAwaitingAction },
                    onDismiss: { commentIDAwaitingAction = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: commentIDAwaitingAction)
        .sensoryFeedback(.impact(weight: .medium), trigger: commentIDAwaitingAction) { _, newCommentID in newCommentID != nil }
        .confirmationDialog(
            deletionConfirmationTitle,
            isPresented: Binding(get: { commentAwaitingDeletion != nil }, set: { if !$0 { commentAwaitingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: commentAwaitingDeletion
        ) { comment in
            Button("Delete", role: .destructive) {
                Task { await commentsStore.deleteComment(id: comment.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's deleted on GitHub too.")
        }
        .confirmingHide(of: $postedContentAwaitingHideConfirmation) { postedContent in
            hiddenPeopleStore.hide(postedContent.postedBy)
            analytics.capture(.personHidden(postedContent, control: .commentActions))
        }
        .demoSignInPrompt($demoSignInPromptAction, signInSession: signInSession)
        .onChange(of: isComposerFocused) { _, isFocused in
            if isFocused {
                selectedPresentationDetent = .large
            }
        }
        .presentationDetents([.fraction(0.72), .large], selection: $selectedPresentationDetent)
        .presentationDragIndicator(.visible)
        .presentationBackground(RevylBrandColor.surface)
        .task { await commentsStore.runLiveRefreshLoop() }
        .alert(
            "Couldn't update GitHub",
            isPresented: Binding(get: { commentsStore.actionFailureMessage != nil }, set: { if !$0 { commentsStore.actionFailureMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(commentsStore.actionFailureMessage ?? "")
        }
    }

    private func headerTitle(commentsByPeople: [PullRequestComment]) -> String {
        let vibeCount = commentsByPeople.filter { PullRequestVibeComment(comment: $0) != nil }.count
        let commentCount = commentsByPeople.count - vibeCount
        let commentCountText = commentCount == 1 ? "1 comment" : "\(commentCount) comments"
        guard vibeCount > 0 else { return commentCountText }
        return "\(commentCountText) · \(vibeCount == 1 ? "1 vibe" : "\(vibeCount) vibes")"
    }

    @ViewBuilder
    private func composer(scrollProxy: ScrollViewProxy) -> some View {
        if let viewer {
            signedInComposer(viewer: viewer, scrollProxy: scrollProxy)
        } else {
            Button { promptSignIn(for: .comment) } label: {
                Text("Sign in to comment")
                    .foregroundStyle(RevylBrandColor.textSubtle)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(RevylBrandColor.surfaceRaised))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .centeredInReadableContentColumn()
            .padding(.vertical, 11)
            .background(RevylBrandColor.surfaceFloating)
        }
    }

    private func signedInComposer(viewer: GitHubUserIdentity, scrollProxy: ScrollViewProxy) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            GitHubAvatarView(avatarURL: viewer.githubAvatarURL, diameter: 32)
                .padding(.bottom, 6)
            TextField("Comment as @\(viewer.githubLogin)…", text: $draftBodyMarkdown, axis: .vertical)
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(RevylBrandColor.surfaceRaised))
            Button { postDraft(scrollProxy: scrollProxy) } label: {
                ZStack {
                    if commentsStore.isPostingComment {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .resizable()
                            .foregroundStyle(trimmedDraft.isEmpty ? RevylBrandColor.textSubtle : RevylBrandColor.brand)
                    }
                }
                .frame(width: 32, height: 32)
                .frame(width: commentsSheetMinimumTapTargetSidePoints, height: commentsSheetMinimumTapTargetSidePoints)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, -8)
            .padding(.vertical, -2)
            .disabled(trimmedDraft.isEmpty || commentsStore.isPostingComment)
            .accessibilityLabel("Post comment")
        }
        .padding(.horizontal, 12)
        .centeredInReadableContentColumn()
        .padding(.vertical, 11)
        .background(RevylBrandColor.surfaceFloating)
    }

    private var deletionConfirmationTitle: String {
        commentAwaitingDeletion.flatMap(PullRequestVibeComment.init(comment:)) == nil ? "Delete this comment?" : "Delete this vibe?"
    }

    private func attachedMediaItems(of comment: PullRequestComment) -> [PullRequestMediaItem] {
        commentsStore.thread.mediaItems.filter { $0.sourceCommentID == comment.id }
    }

    // Someone else's comment can be reported on GitHub or its author hidden (shiptok/AGENTS.md, "Report And Hide").
    private func reportableContent(of comment: PullRequestComment) -> GitHubPostedContent? {
        guard let author = comment.author, !(viewer.map { author.hasLogin($0.githubLogin) } ?? false) else { return nil }
        return GitHubPostedContent(kind: .comment, postedBy: author, githubURL: comment.url, postedOn: analyticsSubject)
    }

    private func showActions(for comment: PullRequestComment) {
        isComposerFocused = false
        commentIDAwaitingAction = comment.id
    }

    private func startReply(to comment: PullRequestComment) {
        guard viewer != nil else { return promptSignIn(for: .comment) }
        if let authorLogin = comment.author?.login, !draftBodyMarkdown.hasPrefix("@\(authorLogin) ") {
            draftBodyMarkdown = "@\(authorLogin) " + draftBodyMarkdown
        }
        isComposerFocused = true
    }

    private func toggleReaction(_ reaction: GitHubReaction, on comment: PullRequestComment) {
        guard viewer != nil else { return promptSignIn(for: .reaction) }
        Task { await commentsStore.toggleReaction(reaction, onCommentID: comment.id) }
    }

    private func promptSignIn(for action: DemoSignInPromptAction) {
        isComposerFocused = false
        analytics.capture(.demoSignInPrompted(action))
        demoSignInPromptAction = action
    }

    private func postDraft(scrollProxy: ScrollViewProxy) {
        let bodyMarkdown = trimmedDraft
        Task {
            guard let postedComment = await commentsStore.postComment(bodyMarkdown: bodyMarkdown) else { return }
            if draftBodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) == bodyMarkdown {
                draftBodyMarkdown = ""
            }
            withAnimation { scrollProxy.scrollTo(postedComment.id, anchor: .top) }
        }
    }
}

private struct PullRequestCommentRow: View {
    static let metaLineHeightPoints: CGFloat = 22
    static let metaTapTargetOverhangPoints = commentsSheetMinimumTapTargetSidePoints - metaLineHeightPoints

    let comment: PullRequestComment
    let attachedMediaItems: [PullRequestMediaItem]
    let bodyLineLimit: Int?
    let onReply: () -> Void
    let onToggleReaction: (GitHubReaction) -> Void
    let onShowActions: () -> Void

    var body: some View {
        let vibeComment = PullRequestVibeComment(comment: comment)
        let visibleMarkdown = GitHubCommentBodyText.visibleMarkdown(fromBodyMarkdown: vibeComment?.feedbackText ?? comment.bodyMarkdown)
        HStack(alignment: .top, spacing: 10) {
            GitHubAvatarView(avatarURL: comment.author?.avatarURL, diameter: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("@\(comment.author?.login ?? "ghost")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RevylBrandColor.textMuted)
                    if let vibeComment {
                        PullRequestVibeBadge(vibe: vibeComment.vibe)
                    }
                }
                if !visibleMarkdown.isEmpty {
                    Text(GitHubCommentBodyText.attributedText(fromVisibleMarkdown: visibleMarkdown))
                        .font(.subheadline)
                        .foregroundStyle(RevylBrandColor.textPrimary)
                        .lineLimit(bodyLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !attachedMediaItems.isEmpty {
                    Label(attachedMediaSummary, systemImage: "photo.on.rectangle")
                        .font(.caption)
                        .foregroundStyle(RevylBrandColor.textMuted)
                }
                WrappingHorizontalLayout(horizontalSpacing: 4, verticalSpacing: Self.metaTapTargetOverhangPoints) {
                    LiveRelativeTimeText(date: comment.createdAt)
                        .font(.caption)
                        .foregroundStyle(RevylBrandColor.textSubtle)
                        .frame(minHeight: Self.metaLineHeightPoints)
                        .padding(.trailing, 4)
                    Button(action: onReply) {
                        Text("Reply")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RevylBrandColor.textSubtle)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 44, minHeight: Self.metaLineHeightPoints)
                            .expandingTapTargetDownward(toMinimumSide: commentsSheetMinimumTapTargetSidePoints)
                    }
                    .buttonStyle(.plain)
                    ForEach(nonHeartReactions, id: \.self) { reaction in
                        reactionChip(reaction)
                    }
                }
            }
            Spacer(minLength: 8)
            heartButton
                .padding(.trailing, -15)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.4, perform: onShowActions)
        .accessibilityAction(named: "More actions", onShowActions)
    }

    private var heartButton: some View {
        let viewerHearted = comment.reactions.viewerReactions.contains(.heart)
        let heartCount = comment.reactions.countsByReaction[.heart] ?? 0
        return Button { onToggleReaction(.heart) } label: {
            VStack(spacing: 2) {
                Image(systemName: viewerHearted ? "heart.fill" : "heart")
                    .foregroundStyle(viewerHearted ? RevylBrandColor.danger : RevylBrandColor.textSubtle)
                    .symbolEffect(.bounce, value: viewerHearted)
                if heartCount > 0 {
                    Text(heartCount.formatted(.number.notation(.compactName)))
                        .font(.caption2)
                        .foregroundStyle(RevylBrandColor.textSubtle)
                }
            }
            .frame(width: commentsSheetMinimumTapTargetSidePoints, height: commentsSheetMinimumTapTargetSidePoints, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: viewerHearted)
        .accessibilityLabel(viewerHearted ? "Unlike comment" : "Like comment")
    }

    private var nonHeartReactions: [GitHubReaction] {
        GitHubReaction.allCases.filter { $0 != .heart && (comment.reactions.countsByReaction[$0] ?? 0) > 0 }
    }

    private func reactionChip(_ reaction: GitHubReaction) -> some View {
        let viewerReacted = comment.reactions.viewerReactions.contains(reaction)
        return Button { onToggleReaction(reaction) } label: {
            Text("\(reaction.emoji) \(comment.reactions.countsByReaction[reaction] ?? 0)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RevylBrandColor.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(viewerReacted ? RevylBrandColor.brand.opacity(0.3) : RevylBrandColor.surfaceRaised))
                .overlay(Capsule().stroke(viewerReacted ? RevylBrandColor.brand : RevylBrandColor.border, lineWidth: 1))
                .frame(minWidth: 44, minHeight: Self.metaLineHeightPoints)
                .expandingTapTargetDownward(toMinimumSide: commentsSheetMinimumTapTargetSidePoints)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(reaction.accessibilityName), \(comment.reactions.countsByReaction[reaction] ?? 0)")
        .accessibilityAddTraits(viewerReacted ? .isSelected : [])
    }

    private var attachedMediaSummary: String {
        let videoCount = attachedMediaItems.filter { $0.kind == .video }.count
        let imageCount = attachedMediaItems.filter { $0.kind == .image }.count
        let animatedImageCount = attachedMediaItems.filter { $0.kind == .animatedImage }.count
        return [
            videoCount > 0 ? "\(videoCount) \(videoCount == 1 ? "video" : "videos")" : nil,
            imageCount > 0 ? "\(imageCount) \(imageCount == 1 ? "photo" : "photos")" : nil,
            animatedImageCount > 0 ? "\(animatedImageCount) \(animatedImageCount == 1 ? "GIF" : "GIFs")" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

private extension View {
    func expandingTapTargetDownward(toMinimumSide minimumTapTargetSidePoints: CGFloat) -> some View {
        background(alignment: .top) {
            Color.clear
                .frame(minWidth: minimumTapTargetSidePoints, minHeight: minimumTapTargetSidePoints)
                .contentShape(Rectangle())
        }
    }
}

private struct PullRequestVibeBadge: View {
    let vibe: PullRequestVibe

    var body: some View {
        Label(vibe.displayName, systemImage: vibe == .good ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(vibe == .good ? RevylBrandColor.success : RevylBrandColor.danger)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill((vibe == .good ? RevylBrandColor.success : RevylBrandColor.danger).opacity(0.15)))
    }
}

private struct PullRequestCommentActionsOverlay: View {
    let comment: PullRequestComment
    let attachedMediaItems: [PullRequestMediaItem]
    let onToggleReaction: (GitHubReaction) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onOpenOnGitHub: () -> Void
    let reportableContent: GitHubPostedContent?
    let onReport: (GitHubPostedContent) -> Void
    let onHide: (GitHubPostedContent) -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close comment actions")
            VStack(spacing: 12) {
                GitHubReactionPicker(
                    viewerReactions: comment.reactions.viewerReactions,
                    cellSidePoints: commentsSheetMinimumTapTargetSidePoints
                ) { reaction in
                    onToggleReaction(reaction)
                    onDismiss()
                }
                PullRequestCommentRow(
                    comment: comment,
                    attachedMediaItems: attachedMediaItems,
                    bodyLineLimit: 8,
                    onReply: {},
                    onToggleReaction: { _ in },
                    onShowActions: {}
                )
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(RevylBrandColor.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(RevylBrandColor.brand.opacity(0.7), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                VStack(spacing: 0) {
                    actionButton("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
                    Divider().overlay(RevylBrandColor.border)
                    actionButton("Copy", systemImage: "doc.on.doc", action: onCopy)
                    Divider().overlay(RevylBrandColor.border)
                    actionButton("Open on GitHub", systemImage: "arrow.up.right.square", action: onOpenOnGitHub)
                    if let reportableContent {
                        Divider().overlay(RevylBrandColor.border)
                        actionButton("Report on GitHub", systemImage: "flag") { onReport(reportableContent) }
                        Divider().overlay(RevylBrandColor.border)
                        actionButton("Hide @\(reportableContent.postedBy.login)", systemImage: "eye.slash", isDestructive: true) { onHide(reportableContent) }
                    }
                    if comment.viewerCanDelete {
                        Divider().overlay(RevylBrandColor.border)
                        actionButton("Delete", systemImage: "trash", isDestructive: true, action: onDelete)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(RevylBrandColor.surfaceFloating))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RevylBrandColor.border, lineWidth: 1))
            }
            .centeredInReadableContentColumn()
            .padding(16)
        }
    }

    private func actionButton(_ title: String, systemImage: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onDismiss()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(isDestructive ? RevylBrandColor.danger : RevylBrandColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
