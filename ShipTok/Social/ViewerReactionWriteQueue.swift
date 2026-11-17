import Foundation

// Each write of one reaction on one subject waits for the one before it, so GitHub ends where the last tap left it. Only the newest write's failure restores what's shown, to what GitHub last confirmed, since an older one's result is overtaken by the newer tap.
@MainActor
final class ViewerReactionWriteQueue {
    enum Outcome {
        case succeeded
        // Nil when a newer write of the same reaction owns what's shown.
        case failed(Error, restoredViewerHasReacted: Bool?)
    }

    private struct WriteKey: Hashable {
        let subjectID: String
        let reaction: GitHubReaction
    }

    private var newestWriteByKey: [WriteKey: (id: UUID, task: Task<Result<Void, Error>, Never>)] = [:]
    private var confirmedViewerHasReactedByKey: [WriteKey: Bool] = [:]
    private let githubAPIClient: GitHubAPIClient

    init(githubAPIClient: GitHubAPIClient) {
        self.githubAPIClient = githubAPIClient
    }

    // A write always changes what's shown, so until one succeeds GitHub is taken to hold the opposite of it.
    func write(_ reaction: GitHubReaction, viewerHasReacted: Bool, onSubjectID subjectID: String) async -> Outcome {
        let writeKey = WriteKey(subjectID: subjectID, reaction: reaction)
        if confirmedViewerHasReactedByKey[writeKey] == nil {
            confirmedViewerHasReactedByKey[writeKey] = !viewerHasReacted
        }
        let previousWriteTask = newestWriteByKey[writeKey]?.task
        let writeID = UUID()
        let writeTask = Task { [githubAPIClient] () -> Result<Void, Error> in
            _ = await previousWriteTask?.value
            do {
                if viewerHasReacted {
                    try await githubAPIClient.addReaction(reaction, toSubjectID: subjectID)
                } else {
                    try await githubAPIClient.removeReaction(reaction, fromSubjectID: subjectID)
                }
                confirmedViewerHasReactedByKey[writeKey] = viewerHasReacted
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        newestWriteByKey[writeKey] = (writeID, writeTask)
        let result = await writeTask.value
        let isNewestWrite = newestWriteByKey[writeKey]?.id == writeID
        let restoredViewerHasReacted = isNewestWrite ? confirmedViewerHasReactedByKey[writeKey] : nil
        if isNewestWrite {
            newestWriteByKey[writeKey] = nil
            confirmedViewerHasReactedByKey[writeKey] = nil
        }
        switch result {
        case .success:
            return .succeeded
        case .failure(let error):
            return .failed(error, restoredViewerHasReacted: restoredViewerHasReacted)
        }
    }
}
