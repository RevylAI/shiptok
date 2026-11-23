import Foundation
import Observation
import OSLog

// Feedback on the viewer's own posts and replies to their comments, newest first, as Revyl serves it; whether it's read is kept in the Revyl account, so every device agrees (AGENTS.md, "Inbox").
@Observable
@MainActor
final class DeveloperInboxStore {
    private static let refreshIntervalSeconds = 15
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "inbox")

    private var fetchedItems: [ShipTokInboxItem] = []
    private var nextCursor: String?
    private var loadedPageCount = 0
    private var revylUnreadCount = 0
    // Items Revyl marked unread before this device marked the inbox read through this time read as read at once.
    private var readThroughCreatedAt: Date?
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var isLoadingMore = false
    private let api: RevylShipTokAPI
    private let hiddenPeopleStore: HiddenPeopleStore

    init(api: RevylShipTokAPI, hiddenPeopleStore: HiddenPeopleStore) {
        self.api = api
        self.hiddenPeopleStore = hiddenPeopleStore
    }

    // People the viewer hid never reach the inbox (AGENTS.md, "Report And Hide").
    var items: [ShipTokInboxItem] {
        fetchedItems.filter { !hiddenPeopleStore.isHidden($0.actor) }
    }

    var hasMorePages: Bool {
        nextCursor != nil
    }

    // Revyl's count, less the unread items of people the viewer hid that are loaded here.
    var unreadCount: Int {
        let hiddenUnreadCount = fetchedItems.filter { isUnread($0) && hiddenPeopleStore.isHidden($0.actor) }.count
        return max(revylUnreadCount - hiddenUnreadCount, 0)
    }

    func isUnread(_ item: ShipTokInboxItem) -> Bool {
        item.isUnread && readThroughCreatedAt.map { item.createdAt > $0 } != false
    }

    // Reads the newest page again. Older pages already loaded stay below it, so a refresh never moves the list under the viewer.
    func refresh() async {
        do {
            let newestPage = try await api.fetchInboxPage(cursor: nil)
            revylUnreadCount = newestPage.unreadCount
            if loadedPageCount <= 1 {
                fetchedItems = newestPage.items
                nextCursor = newestPage.nextCursor
                loadedPageCount = 1
            } else {
                let newestPageItemIDs = Set(newestPage.items.map(\.id))
                let oldestNewestPageCreatedAt = newestPage.items.last?.createdAt ?? .distantFuture
                fetchedItems = newestPage.items + fetchedItems.filter { !newestPageItemIDs.contains($0.id) && $0.createdAt < oldestNewestPageCreatedAt }
            }
            errorMessage = nil
            hasLoaded = true
        } catch {
            if Task.isCancelled { return }
            Self.logger.error("Reading the inbox failed: \(error.publicLogDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func runLiveRefreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(Self.refreshIntervalSeconds))
        }
    }

    func loadMore() async {
        guard let nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let olderPage = try await api.fetchInboxPage(cursor: nextCursor)
            let loadedItemIDs = Set(fetchedItems.map(\.id))
            fetchedItems += olderPage.items.filter { !loadedItemIDs.contains($0.id) }
            self.nextCursor = olderPage.nextCursor
            loadedPageCount += 1
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    // Marks the inbox read through its newest item, in Revyl's own spelling of that item's time, so nothing newer is marked by accident.
    func markAllItemsRead() async {
        guard let newestItem = fetchedItems.first, fetchedItems.contains(where: { isUnread($0) }) || revylUnreadCount > 0 else { return }
        do {
            revylUnreadCount = try await api.markInboxRead(throughCreatedAtText: newestItem.createdAtText)
            readThroughCreatedAt = max(readThroughCreatedAt ?? .distantPast, newestItem.createdAt)
        } catch {
            Self.logger.error("Marking the inbox read failed: \(error.publicLogDescription, privacy: .public)")
        }
    }

    // A comment or reply goes to the organization's owners and admins; anything else can only be hidden.
    func report(_ reportableContent: ReportableContent) async throws {
        guard let commentID = reportableContent.commentID else { return }
        try await api.reportComment(commentID: commentID, postID: reportableContent.postID)
    }
}
