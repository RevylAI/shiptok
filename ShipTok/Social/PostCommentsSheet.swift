import SwiftUI
import UIKit

// At its partial detent the sheet draws its content at about 96% scale, so 48 pt still reaches 44 pt on screen.
private let commentsSheetMinimumTapTargetSidePoints: CGFloat = 48

// A post's comments, with each one's replies indented under it, and its vibes, in the order they were given, held by Revyl (AGENTS.md, "Comments" and "Vibes").
struct PostCommentsSheet: View {
    private enum TimelineEntry: Identifiable {
        case comment(ShipTokPostComment)
        case vibe(ShipTokPostVibe)

        var id: String {
            switch self {
            case .comment(let comment): comment.id
            case .vibe(let vibe): vibe.id
            }
        }

        var createdAt: Date {
            switch self {
            case .comment(let comment): comment.createdAt
            case .vibe(let vibe): vibe.createdAt
            }
        }
    }

    let viewer: RevylAccount
    private let hiddenPeopleStore: HiddenPeopleStore
    private let analytics: ShipTokAnalytics
    private let focusedCommentID: String?
    @State private var commentsStore: PostCommentsStore
    @State private var draftBody = ""
    @State private var repliedCommentID: String?
    @State private var commentIDAwaitingAction: String?
    @State private var commentAwaitingDeletion: ShipTokPostComment?
    @State private var vibeIDAwaitingAction: String?
    @State private var vibeAwaitingDeletion: ShipTokPostVibe?
    @State private var contentAwaitingHideConfirmation: ReportableContent?
    @State private var hasScrolledToFocusedComment = false
    @State private var selectedPresentationDetent: PresentationDetent = .fraction(0.72)
    @FocusState private var isComposerFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        post: ShipTokPost,
        viewer: RevylAccount,
        hiddenPeopleStore: HiddenPeopleStore,
        api: RevylShipTokAPI,
        analytics: ShipTokAnalytics,
        focusedCommentID: String? = nil,
        onCommentCountChange: @escaping (Int) -> Void,
        onVibeDeleted: @escaping () -> Void
    ) {
        self.viewer = viewer
        self.hiddenPeopleStore = hiddenPeopleStore
        self.analytics = analytics
        self.focusedCommentID = focusedCommentID
        _commentsStore = State(initialValue: PostCommentsStore(
            postID: post.id,
            api: api,
            analytics: analytics,
            analyticsSubject: ShipTokAnalyticsSubject(post: post),
            onCommentCountChange: onCommentCountChange,
            onVibeDeleted: onVibeDeleted
        ))
    }

    private var trimmedDraft: String {
        draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var repliedComment: ShipTokPostComment? {
        repliedCommentID.flatMap(commentsStore.comment(withID:))
    }

    private var commentAwaitingAction: ShipTokPostComment? {
        commentIDAwaitingAction.flatMap(commentsStore.comment(withID:))
    }

    private var vibeAwaitingAction: ShipTokPostVibe? {
        vibeIDAwaitingAction.flatMap { vibeID in commentsStore.vibes.first { $0.id == vibeID } }
    }

    private var isActionOverlayShown: Bool {
        commentIDAwaitingAction != nil || vibeIDAwaitingAction != nil
    }

    // Comments and vibes in the order they were given, with what a hidden person gave left out; a hidden person's comment leaves with its replies, which answer something no longer shown. While either list has older pages unread, nothing of the other past its last loaded entry shows, so a page that loads later never lands above what's shown.
    private var timeline: [TimelineEntry] {
        let visibleComments = commentsStore.comments.compactMap { comment -> ShipTokPostComment? in
            guard !hiddenPeopleStore.isHidden(comment.author) else { return nil }
            var visibleComment = comment
            visibleComment.replies.removeAll { hiddenPeopleStore.isHidden($0.author) }
            return visibleComment
        }
        let visibleVibes = commentsStore.vibes.filter { !hiddenPeopleStore.isHidden($0.author) }
        let pageEnds = [
            commentsStore.commentsNextCursor == nil ? nil : commentsStore.comments.last?.createdAt,
            commentsStore.vibesNextCursor == nil ? nil : commentsStore.vibes.last?.createdAt,
        ].compactMap { $0 }
        let shownUntil = pageEnds.min()
        return (visibleComments.map(TimelineEntry.comment) + visibleVibes.map(TimelineEntry.vibe))
            .filter { shownUntil == nil || $0.createdAt <= shownUntil! }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        let timeline = timeline
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                ZStack {
                    Text(headerTitle(timeline: timeline))
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
                    LazyVStack(alignment: .leading, spacing: PostCommentRow.metaTapTargetOverhangPoints) {
                        if let refreshFailureMessage = commentsStore.refreshFailureMessage {
                            Label("Couldn't refresh comments: \(refreshFailureMessage)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(RevylBrandColor.warning)
                        }
                        if !commentsStore.hasLoadedFirstPage {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else if timeline.isEmpty {
                            Text("No comments yet. Say what you think of this one.")
                                .font(.subheadline)
                                .foregroundStyle(RevylBrandColor.textMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(timeline) { timelineEntry in
                            switch timelineEntry {
                            case .comment(let comment):
                                commentRow(comment)
                                ForEach(comment.replies) { reply in
                                    commentRow(reply)
                                        .padding(.leading, 44)
                                }
                            case .vibe(let vibe):
                                PostVibeRow(vibe: vibe, bodyLineLimit: nil, onShowActions: { showActions(for: vibe) })
                                    .id(vibe.id)
                            }
                        }
                        if commentsStore.hasMorePages {
                            Button {
                                Task { await commentsStore.loadMore() }
                            } label: {
                                ZStack {
                                    if commentsStore.isLoadingMore {
                                        ProgressView()
                                    } else {
                                        Text("Load more comments")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(RevylBrandColor.brand)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: commentsSheetMinimumTapTargetSidePoints)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(commentsStore.isLoadingMore)
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
            .onChange(of: commentsStore.hasLoadedFirstPage) { _, hasLoadedFirstPage in
                guard hasLoadedFirstPage else { return }
                Task { await scrollToFocusedComment(scrollProxy: scrollProxy) }
            }
        }
        .background(RevylBrandColor.surface)
        .overlay {
            if let commentAwaitingAction {
                FeedbackActionsOverlay(
                    viewerReactions: commentAwaitingAction.reactions.viewerReactions,
                    onToggleReaction: { reaction in toggleReaction(reaction, on: commentAwaitingAction) },
                    actions: actions(for: commentAwaitingAction),
                    onDismiss: { commentIDAwaitingAction = nil }
                ) {
                    PostCommentRow(comment: commentAwaitingAction, bodyLineLimit: 8, onReply: {}, onToggleReaction: { _ in }, onShowActions: {})
                }
                .transition(.opacity)
            } else if let vibeAwaitingAction {
                FeedbackActionsOverlay(
                    viewerReactions: nil,
                    onToggleReaction: { _ in },
                    actions: actions(for: vibeAwaitingAction),
                    onDismiss: { vibeIDAwaitingAction = nil }
                ) {
                    PostVibeRow(vibe: vibeAwaitingAction, bodyLineLimit: 8, onShowActions: {})
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isActionOverlayShown)
        .sensoryFeedback(.impact(weight: .medium), trigger: isActionOverlayShown) { _, isShown in isShown }
        .confirmationDialog(
            commentAwaitingDeletion?.parentCommentID == nil ? "Delete this comment?" : "Delete this reply?",
            isPresented: Binding(get: { commentAwaitingDeletion != nil }, set: { if !$0 { commentAwaitingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: commentAwaitingDeletion
        ) { comment in
            Button("Delete", role: .destructive) {
                if repliedCommentID == comment.id || comment.replies.contains(where: { $0.id == repliedCommentID }) {
                    repliedCommentID = nil
                }
                Task { await commentsStore.deleteComment(comment) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { comment in
            Text(comment.replies.isEmpty ? "It's deleted for everyone." : "It's deleted for everyone, with its replies.")
        }
        .confirmationDialog(
            "Delete this vibe?",
            isPresented: Binding(get: { vibeAwaitingDeletion != nil }, set: { if !$0 { vibeAwaitingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: vibeAwaitingDeletion
        ) { vibe in
            Button("Delete", role: .destructive) {
                Task { await commentsStore.deleteVibe(vibe) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { vibe in
            Text(vibe.author.revylUserID == viewer.revylUserID ? "Your vibe and its feedback are deleted for everyone." : "It's deleted for everyone.")
        }
        .confirmingHide(of: $contentAwaitingHideConfirmation) { reportableContent in
            hiddenPeopleStore.hide(reportableContent.poster)
            analytics.capture(.personHidden(reportableContent, control: .commentActions))
        }
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
            "Couldn't update comments",
            isPresented: Binding(get: { commentsStore.actionFailureMessage != nil }, set: { if !$0 { commentsStore.actionFailureMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(commentsStore.actionFailureMessage ?? "")
        }
        .alert(
            "Reported",
            isPresented: Binding(get: { commentsStore.reportConfirmationMessage != nil }, set: { if !$0 { commentsStore.reportConfirmationMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(commentsStore.reportConfirmationMessage ?? "")
        }
    }

    private func commentRow(_ comment: ShipTokPostComment) -> some View {
        PostCommentRow(
            comment: comment,
            bodyLineLimit: nil,
            onReply: {
                guard !isActionOverlayShown else { return }
                startReply(to: comment)
            },
            onToggleReaction: { reaction in
                guard !isActionOverlayShown else { return }
                toggleReaction(reaction, on: comment)
            },
            onShowActions: { showActions(for: comment) }
        )
        .id(comment.id)
    }

    private func headerTitle(timeline: [TimelineEntry]) -> String {
        var commentCount = 0
        var vibeCount = 0
        for timelineEntry in timeline {
            switch timelineEntry {
            case .comment(let comment): commentCount += 1 + comment.replies.count
            case .vibe: vibeCount += 1
            }
        }
        let commentCountText = commentCount == 1 ? "1 comment" : "\(commentCount) comments"
        guard vibeCount > 0 else { return commentCountText }
        return "\(commentCountText) · \(vibeCount == 1 ? "1 vibe" : "\(vibeCount) vibes")"
    }

    private func actions(for comment: ShipTokPostComment) -> [FeedbackAction] {
        var actions = [
            FeedbackAction(title: "Reply", systemImage: "arrowshape.turn.up.left") { startReply(to: comment) },
            FeedbackAction(title: "Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = comment.body },
        ]
        if comment.author.revylUserID != viewer.revylUserID {
            actions += moderationActions(for: ReportableContent(comment: comment))
        }
        if comment.viewerCanDelete {
            actions.append(FeedbackAction(title: "Delete", systemImage: "trash", isDestructive: true) { commentAwaitingDeletion = comment })
        }
        return actions
    }

    private func actions(for vibe: ShipTokPostVibe) -> [FeedbackAction] {
        var actions: [FeedbackAction] = []
        if let feedbackText = vibe.feedbackText, !feedbackText.isEmpty {
            actions.append(FeedbackAction(title: "Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = feedbackText })
        }
        if vibe.author.revylUserID != viewer.revylUserID {
            actions += moderationActions(for: ReportableContent(vibe: vibe))
        }
        if vibe.viewerCanDelete {
            actions.append(FeedbackAction(title: "Delete", systemImage: "trash", isDestructive: true) { vibeAwaitingDeletion = vibe })
        }
        return actions
    }

    // Someone else's comment or vibe can be reported to the organization's owners and admins, or its author hidden (AGENTS.md, "Report And Hide").
    private func moderationActions(for reportableContent: ReportableContent) -> [FeedbackAction] {
        [
            FeedbackAction(title: "Report", systemImage: "flag") {
                Task { await commentsStore.report(reportableContent, control: .commentActions) }
            },
            FeedbackAction(title: "Hide \(reportableContent.poster.displayName)", systemImage: "eye.slash", isDestructive: true) {
                contentAwaitingHideConfirmation = reportableContent
            },
        ]
    }

    private func composer(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let repliedComment {
                HStack(spacing: 6) {
                    Text("Replying to \(repliedComment.author.displayName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RevylBrandColor.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { repliedCommentID = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(RevylBrandColor.textSubtle)
                            .frame(width: 44, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.leading, 54)
            }
            HStack(alignment: .bottom, spacing: 10) {
                AvatarView(avatarURL: viewer.avatarURL, diameter: 32)
                    .padding(.bottom, 6)
                TextField(repliedComment.map { "Reply to \($0.author.displayName)…" } ?? "Comment as \(viewer.displayName)…", text: $draftBody, axis: .vertical)
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
                .accessibilityLabel(repliedCommentID == nil ? "Post comment" : "Post reply")
            }
        }
        .padding(.horizontal, 12)
        .centeredInReadableContentColumn()
        .padding(.vertical, 11)
        .background(RevylBrandColor.surfaceFloating)
    }

    private func showActions(for comment: ShipTokPostComment) {
        isComposerFocused = false
        commentIDAwaitingAction = comment.id
    }

    private func showActions(for vibe: ShipTokPostVibe) {
        isComposerFocused = false
        vibeIDAwaitingAction = vibe.id
    }

    private func startReply(to comment: ShipTokPostComment) {
        repliedCommentID = comment.id
        isComposerFocused = true
    }

    private func toggleReaction(_ reaction: ShipTokReaction, on comment: ShipTokPostComment) {
        Task { await commentsStore.toggleReaction(reaction, on: comment) }
    }

    private func postDraft(scrollProxy: ScrollViewProxy) {
        let body = trimmedDraft
        let repliedComment = repliedComment
        Task {
            guard let postedComment = await commentsStore.postComment(body: body, replyingTo: repliedComment) else { return }
            if draftBody.trimmingCharacters(in: .whitespacesAndNewlines) == body {
                draftBody = ""
                repliedCommentID = nil
            }
            withAnimation { scrollProxy.scrollTo(postedComment.id, anchor: .top) }
        }
    }

    // A comment opened from the inbox or a notification can sit past the first page, so pages load until it's there.
    private func scrollToFocusedComment(scrollProxy: ScrollViewProxy) async {
        guard let focusedCommentID, !hasScrolledToFocusedComment else { return }
        hasScrolledToFocusedComment = true
        while commentsStore.comment(withID: focusedCommentID) == nil, commentsStore.commentsNextCursor != nil {
            await commentsStore.loadMore()
        }
        guard commentsStore.comment(withID: focusedCommentID) != nil else { return }
        withAnimation { scrollProxy.scrollTo(focusedCommentID, anchor: .center) }
    }
}

private struct PostCommentRow: View {
    static let metaLineHeightPoints: CGFloat = 22
    static let metaTapTargetOverhangPoints = commentsSheetMinimumTapTargetSidePoints - metaLineHeightPoints

    let comment: ShipTokPostComment
    let bodyLineLimit: Int?
    let onReply: () -> Void
    let onToggleReaction: (ShipTokReaction) -> Void
    let onShowActions: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(avatarURL: comment.author.avatarURL, diameter: comment.parentCommentID == nil ? 34 : 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: comment.author.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RevylBrandColor.textMuted)
                // A reply sits under its thread's top-level comment, so only one that answers another reply says whom it answers.
                if let replyToAuthor = comment.replyToAuthor, comment.replyToCommentID != comment.parentCommentID {
                    Text("Replying to \(replyToAuthor.displayName)")
                        .font(.caption)
                        .foregroundStyle(RevylBrandColor.textSubtle)
                        .lineLimit(1)
                }
                Text(verbatim: comment.body)
                    .font(.subheadline)
                    .foregroundStyle(RevylBrandColor.textPrimary)
                    .lineLimit(bodyLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
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
        let heartCount = comment.reactions.count(of: .heart)
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

    private var nonHeartReactions: [ShipTokReaction] {
        ShipTokReaction.allCases.filter { $0 != .heart && comment.reactions.count(of: $0) > 0 }
    }

    private func reactionChip(_ reaction: ShipTokReaction) -> some View {
        let viewerReacted = comment.reactions.viewerReactions.contains(reaction)
        return Button { onToggleReaction(reaction) } label: {
            Text("\(reaction.emoji) \(comment.reactions.count(of: reaction))")
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
        .accessibilityLabel("\(reaction.accessibilityName), \(comment.reactions.count(of: reaction))")
        .accessibilityAddTraits(viewerReacted ? .isSelected : [])
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

private struct PostVibeRow: View {
    let vibe: ShipTokPostVibe
    let bodyLineLimit: Int?
    let onShowActions: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(avatarURL: vibe.author.avatarURL, diameter: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: vibe.author.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RevylBrandColor.textMuted)
                    Label(vibe.vibe.displayName, systemImage: "\(vibe.vibe.systemImageName).fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(vibe.vibe.tintColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(vibe.vibe.tintColor.opacity(0.15)))
                }
                if let feedbackText = vibe.feedbackText, !feedbackText.isEmpty {
                    Text(verbatim: feedbackText)
                        .font(.subheadline)
                        .foregroundStyle(RevylBrandColor.textPrimary)
                        .lineLimit(bodyLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LiveRelativeTimeText(date: vibe.createdAt)
                    .font(.caption)
                    .foregroundStyle(RevylBrandColor.textSubtle)
                    .frame(minHeight: PostCommentRow.metaLineHeightPoints)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.4, perform: onShowActions)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "More actions", onShowActions)
    }
}

private struct FeedbackAction: Identifiable {
    let title: String
    let systemImage: String
    var isDestructive = false
    let action: () -> Void

    var id: String { title }
}

// A long press on a comment or vibe lifts it over the sheet with what the viewer can do to it, and for a comment the reactions to toggle.
private struct FeedbackActionsOverlay<Preview: View>: View {
    // Nil for a vibe, which takes no reactions.
    let viewerReactions: Set<ShipTokReaction>?
    let onToggleReaction: (ShipTokReaction) -> Void
    let actions: [FeedbackAction]
    let onDismiss: () -> Void
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close actions")
            VStack(spacing: 12) {
                if let viewerReactions {
                    ReactionPicker(viewerReactions: viewerReactions, cellSidePoints: commentsSheetMinimumTapTargetSidePoints) { reaction in
                        onToggleReaction(reaction)
                        onDismiss()
                    }
                }
                preview()
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(RevylBrandColor.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(RevylBrandColor.brand.opacity(0.7), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                if !actions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(actions) { feedbackAction in
                            if feedbackAction.id != actions.first?.id {
                                Divider().overlay(RevylBrandColor.border)
                            }
                            actionButton(feedbackAction)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(RevylBrandColor.surfaceFloating))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RevylBrandColor.border, lineWidth: 1))
                }
            }
            .centeredInReadableContentColumn()
            .padding(16)
        }
    }

    private func actionButton(_ feedbackAction: FeedbackAction) -> some View {
        Button {
            feedbackAction.action()
            onDismiss()
        } label: {
            Label(feedbackAction.title, systemImage: feedbackAction.systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(feedbackAction.isDestructive ? RevylBrandColor.danger : RevylBrandColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
