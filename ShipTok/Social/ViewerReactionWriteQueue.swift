import Foundation

// What a reaction goes on: a post, or a comment or reply on one.
enum ReactionSubject: Hashable, Sendable {
    case post(postID: String)
    case comment(postID: String, commentID: String)
}

// Each write of one reaction on one subject waits for the one before it, so Revyl ends where the last tap left it. Only the newest write's failure restores what's shown, to what Revyl last confirmed, since an older one's result is overtaken by the newer tap.
@MainActor
final class ViewerReactionWriteQueue {
    enum Outcome {
        case succeeded
        // Nil when a newer write of the same reaction owns what's shown.
        case failed(Error, restoredViewerHasReacted: Bool?)
    }

    private struct WriteKey: Hashable {
        let subject: ReactionSubject
        let reaction: ShipTokReaction
    }

    private var newestWriteByKey: [WriteKey: (id: UUID, task: Task<Result<Void, Error>, Never>)] = [:]
    private var confirmedViewerHasReactedByKey: [WriteKey: Bool] = [:]
    private let api: RevylShipTokAPI

    init(api: RevylShipTokAPI) {
        self.api = api
    }

    // A write always changes what's shown, so until one succeeds Revyl is taken to hold the opposite of it.
    func write(_ reaction: ShipTokReaction, viewerHasReacted: Bool, on subject: ReactionSubject) async -> Outcome {
        let writeKey = WriteKey(subject: subject, reaction: reaction)
        if confirmedViewerHasReactedByKey[writeKey] == nil {
            confirmedViewerHasReactedByKey[writeKey] = !viewerHasReacted
        }
        let previousWriteTask = newestWriteByKey[writeKey]?.task
        let writeID = UUID()
        let writeTask = Task { [api] () -> Result<Void, Error> in
            _ = await previousWriteTask?.value
            do {
                switch subject {
                case .post(let postID):
                    try await api.setPostReaction(reaction, isReacting: viewerHasReacted, postID: postID)
                case .comment(let postID, let commentID):
                    try await api.setCommentReaction(reaction, isReacting: viewerHasReacted, postID: postID, commentID: commentID)
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
