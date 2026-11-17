import SwiftUI

struct MergedPullRequestDetailSheet: View {
    let pullRequest: MergedPullRequest
    let repositoryFullName: String
    let vibeTally: PullRequestVibeTally
    let onToggleReaction: (GitHubReaction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(pullRequest.title)
                        .font(.title2.bold())
                        .foregroundStyle(RevylBrandColor.textPrimary)
                    HStack(spacing: 10) {
                        GitHubAvatarView(avatarURL: pullRequest.author?.avatarURL, diameter: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "@\(pullRequest.author?.login ?? "ghost")")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(RevylBrandColor.textPrimary)
                            Text("Merged \(pullRequest.mergedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(RevylBrandColor.textMuted)
                        }
                    }
                    HStack(spacing: 10) {
                        Text(verbatim: "\(repositoryFullName)#\(pullRequest.number)")
                            .foregroundStyle(RevylBrandColor.textMuted)
                        Text(verbatim: "+\(pullRequest.additions)").foregroundStyle(RevylBrandColor.success)
                        Text(verbatim: "−\(pullRequest.deletions)").foregroundStyle(RevylBrandColor.danger)
                        Text(verbatim: pullRequest.changedFiles == 1 ? "1 file" : "\(pullRequest.changedFiles) files")
                            .foregroundStyle(RevylBrandColor.textMuted)
                    }
                    .font(.caption.monospacedDigit())
                    labelChips
                    vibeAndReactionCounts
                    Link(destination: pullRequest.url) {
                        Label("Open on GitHub", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.revylPrimary)
                    if MarkdownSummaryParser.blocks(from: pullRequest.descriptionMarkdown).isEmpty {
                        Text("No description.")
                            .font(.subheadline)
                            .foregroundStyle(RevylBrandColor.textMuted)
                    } else {
                        MarkdownSummaryView(markdown: pullRequest.descriptionMarkdown)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .centeredInReadableContentColumn()
            }
            .background(RevylBrandColor.surface)
            .navigationTitle(Text(verbatim: "#\(pullRequest.number)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(RevylBrandColor.surface)
    }

    @ViewBuilder
    private var labelChips: some View {
        if !pullRequest.labels.isEmpty {
            WrappingHorizontalLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(pullRequest.labels, id: \.name) { label in
                    let labelColor = Color(rgbHex: label.rgbHex)
                    Text(verbatim: label.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RevylBrandColor.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(labelColor.opacity(0.25)))
                        .overlay(Capsule().stroke(labelColor, lineWidth: 1))
                }
            }
        }
    }

    @ViewBuilder
    private var vibeAndReactionCounts: some View {
        let reactionCounts = GitHubReaction.allCases
            .map { (reaction: $0, count: pullRequest.reactions.count(of: $0)) }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
        if vibeTally.goodVibeCount + vibeTally.badVibeCount > 0 || !reactionCounts.isEmpty {
            WrappingHorizontalLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach([PullRequestVibe.good, .bad], id: \.self) { vibe in
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

    private func vibeCountChip(_ vibe: PullRequestVibe) -> some View {
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

    private func reactionChip(_ reaction: GitHubReaction, count: Int) -> some View {
        let viewerReacted = pullRequest.reactions.viewerReactions.contains(reaction)
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
