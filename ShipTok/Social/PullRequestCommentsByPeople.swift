import Foundation

extension PullRequestComment {
    // Bots and comments carrying a ShipTok tag are never discussion comments: shiptok/AGENTS.md, "Ownership And Boundaries".
    var isWrittenByPerson: Bool {
        author?.isBot != true && !PullRequestMediaExtraction.containsShipTokVideoTag(bodyMarkdown)
    }
}
