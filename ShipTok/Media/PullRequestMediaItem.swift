import Foundation

struct PullRequestMediaItem: Identifiable, Hashable, Sendable, Codable {
    enum Kind: Hashable, Sendable, Codable {
        case video
        case image
        case animatedImage
    }

    let id: String
    let kind: Kind
    // Nil on a saved card whose URL was signed: its media plays from the device or waits for the card's refetch (AGENTS.md, "Feed Caching").
    let url: URL?
    let isShipTokVideo: Bool
    let sourceCommentID: String?
    var sourceCommentDatabaseID: Int? = nil
    // Who posted the description or comment the media came from, so hiding a person hides their media (AGENTS.md, "Report And Hide").
    let postedBy: GitHubActor?
    // When the description or comment the media came from was last edited, or posted if never edited, so the newest tagged video leads the deck.
    let sourceLastEditedAt: Date

    // GitHub signs uploads in the query string and the signature expires; a URL without one, such as a tokened Revyl video link, works again when requested again.
    var hasExpiringSignedURL: Bool {
        url?.query != nil
    }

    // A Revyl-hosted upload's link on any Revyl backend, under whatever path that backend is served from: its hosted video route, then the upload's token and its MP4 or MOV container, read as a backend decodes the path, so an escaped spelling of a working link counts too. Extraction, media ids, saved feeds and redaction all recognize hosted links here (docs/shiptok-format.md, "ShipTok video").
    static func isHostedShipTokVideoURL(_ url: URL) -> Bool {
        let pathSegments = url.path(percentEncoded: false).split(separator: "/")
        return pathSegments.dropLast().suffix(4).elementsEqual(["api", "v1", "shiptok", "videos"])
            && pathSegments.last?.wholeMatch(of: #/[A-Za-z0-9_-]{43}\.(?:mp4|mov)/#) != nil
    }

    // A hosted video's tokened link and a media URL signed in its query string each open the file for whoever holds them, whatever the host.
    static func isCredentialMediaURL(_ url: URL) -> Bool {
        isHostedShipTokVideoURL(url) || url.query != nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case url
        case isShipTokVideo
        case sourceCommentID
        case sourceCommentDatabaseID
        case postedBy
        case sourceLastEditedAt
    }

    // A signed media URL is a credential, so a saved media item never holds one (AGENTS.md, "iOS App").
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        if !id.hasPrefix("shiptok-video:"), url.map(Self.isCredentialMediaURL) != true {
            try container.encodeIfPresent(url, forKey: .url)
        }
        try container.encode(isShipTokVideo, forKey: .isShipTokVideo)
        try container.encodeIfPresent(sourceCommentID, forKey: .sourceCommentID)
        try container.encodeIfPresent(sourceCommentDatabaseID, forKey: .sourceCommentDatabaseID)
        try container.encodeIfPresent(postedBy, forKey: .postedBy)
        try container.encode(sourceLastEditedAt, forKey: .sourceLastEditedAt)
    }
}
