import Foundation

// The feed's reads and saves for one person's own feed. Sign out, Delete my ShipTok data and Delete my Revyl account stop it and wait for what's running before they go on, so nothing read for a sign-in is saved after it ended (AGENTS.md, "Feed Caching").
@MainActor
final class FeedViewerWork {
    private var runningTasksByID: [UUID: Task<Void, Never>] = [:]
    private(set) var hasStopped = false

    // Nil once the work is stopped, which starts nothing more.
    @discardableResult
    func start(_ operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never>? {
        guard !hasStopped else { return nil }
        let taskID = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.runningTasksByID[taskID] = nil
        }
        runningTasksByID[taskID] = task
        return task
    }

    // Cancelling the caller cancels the work it started.
    func perform(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        guard let task = start(operation) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func stop() {
        hasStopped = true
        for task in runningTasksByID.values {
            task.cancel()
        }
    }

    func stopAndWaitForRunningWork() async {
        stop()
        for task in Array(runningTasksByID.values) {
            await task.value
        }
    }
}
