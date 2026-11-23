import SwiftUI

struct PullRequestDetailSheet: View {
    let post: ShipTokPost
    let vibeTally: VibeTally
    let moderation: ContentModeration
    let onToggleReaction: (ShipTokReaction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: post.title)
                        .font(.title2.bold())
                        .foregroundStyle(RevylBrandColor.textPrimary)
                    HStack(spacing: 10) {
                        AvatarView(avatarURL: post.githubAuthor.avatarURL, diameter: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "@\(post.githubAuthor.login ?? "ghost")")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(RevylBrandColor.textPrimary)
                            Group {
                                if let pullRequest = post.pullRequest {
                                    if let mergedAt = pullRequest.mergedAt {
                                        Text("Merged \(mergedAt.formatted(date: .abbreviated, time: .shortened))")
                                    } else {
                                        Text("\(pullRequest.state == .closed ? "Closed" : pullRequest.isDraft ? "Draft" : "Open") · Updated \(pullRequest.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    }
                                }
                            }
                                .font(.caption)
                                .foregroundStyle(RevylBrandColor.textMuted)
                        }
                    }
                    HStack(spacing: 10) {
                        Text(verbatim: "\(post.githubRepositoryFullName)#\(post.githubIssueNumber)")
                            .foregroundStyle(RevylBrandColor.textMuted)
                        if let pullRequest = post.pullRequest {
                            PullRequestDiffStats(pullRequest: pullRequest)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    labelChips
                    vibeAndReactionCounts
                    Link(destination: post.githubURL) {
                        Label("Open on GitHub", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.revylPrimary)
                    if MarkdownSummaryParser.blocks(from: post.descriptionMarkdown).isEmpty {
                        Text("No description.")
                            .font(.subheadline)
                            .foregroundStyle(RevylBrandColor.textMuted)
                    } else {
                        MarkdownSummaryView(markdown: post.descriptionMarkdown)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .centeredInReadableContentColumn()
            }
            .background(RevylBrandColor.surface)
            .navigationTitle(Text(verbatim: "#\(post.githubIssueNumber)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !moderation.reportableContents.isEmpty {
                        ContentModerationMenu(moderation: moderation) {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                        .accessibilityHint("Report or hide a person")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(RevylBrandColor.surface)
    }

    @ViewBuilder
    private var labelChips: some View {
        if let labels = post.pullRequest?.labels, !labels.isEmpty {
            PullRequestLabelChips(labels: labels)
        }
    }

    @ViewBuilder
    private var vibeAndReactionCounts: some View {
        let reactionCounts = ShipTokReaction.allCases
            .map { (reaction: $0, count: post.reactions.count(of: $0)) }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
        if vibeTally.goodVibeCount + vibeTally.badVibeCount > 0 || !reactionCounts.isEmpty {
            WrappingHorizontalLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach([ShipTokVibe.good, .bad], id: \.self) { vibe in
                    if vibeTally.count(of: vibe) > 0 {
                        vibeCountChip(vibe)
                    }
                }
                ForEach(reactionCounts, id: \.reaction) { reactionCount in
                    reactionChip(reactionCount.reaction, count: reactionCount.count)
                }
            }
        }
    }

    private func vibeCountChip(_ vibe: ShipTokVibe) -> some View {
        let isViewerVibe = vibeTally.viewerVibe == vibe
        return Text("\(vibe.displayName) \(FeedCardView.compactCount(vibeTally.count(of: vibe)))")
            .font(.caption.weight(.bold))
            .foregroundStyle(isViewerVibe ? Color.white : vibe.tintColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(isViewerVibe ? vibe.tintColor.opacity(0.75) : Color.clear))
            .overlay(Capsule().stroke(vibe.tintColor, lineWidth: 1))
            .accessibilityLabel("\(vibe.displayName): \(vibeTally.count(of: vibe))\(isViewerVibe ? ", including yours" : "")")
    }

    private func reactionChip(_ reaction: ShipTokReaction, count: Int) -> some View {
        let viewerReacted = post.reactions.viewerReactions.contains(reaction)
        return Button {
            onToggleReaction(reaction)
        } label: {
            Text("\(reaction.emoji) \(FeedCardView.compactCount(count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RevylBrandColor.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(viewerReacted ? RevylBrandColor.brand.opacity(0.3) : RevylBrandColor.surfaceRaised))
                .overlay(Capsule().stroke(viewerReacted ? RevylBrandColor.brand : RevylBrandColor.border, lineWidth: 1))
                .expandingTapTargetVertically()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(reaction.accessibilityName), \(count)")
        .accessibilityAddTraits(viewerReacted ? .isSelected : [])
    }
}
