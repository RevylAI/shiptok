import Foundation

struct GitHubUserIdentity: Codable, Sendable, Equatable {
    var githubUserID: Int64
    var githubLogin: String
    var githubAvatarURLString: String?

    var githubAvatarURL: URL? { githubAvatarURLString.flatMap(URL.init(string:)) }
}
