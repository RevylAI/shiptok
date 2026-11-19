import SwiftUI

struct PullRequestDiffStats: View {
    let pullRequest: PullRequest

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: "+\(pullRequest.additions)").foregroundStyle(RevylBrandColor.success)
            Text(verbatim: "−\(pullRequest.deletions)").foregroundStyle(RevylBrandColor.danger)
            Text(verbatim: pullRequest.changedFiles == 1 ? "1 file" : "\(pullRequest.changedFiles) files")
                .foregroundStyle(RevylBrandColor.textMuted)
        }
        .font(.caption.monospacedDigit())
    }
}
