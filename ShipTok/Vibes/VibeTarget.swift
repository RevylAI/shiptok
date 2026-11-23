import Foundation

// What a vibe goes on: a post, named the way the feed's toasts name it (AGENTS.md, "Vibes").
struct VibeTarget: Hashable {
    let postID: String
    let title: String
    let reference: String
    let analyticsSubject: ShipTokAnalyticsSubject

    init(post: ShipTokPost) {
        postID = post.id
        title = post.title
        reference = post.reference
        analyticsSubject = ShipTokAnalyticsSubject(post: post)
    }
}
