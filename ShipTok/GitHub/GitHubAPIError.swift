import Foundation

enum GitHubAPIError: LocalizedError {
    case accessTokenRejected
    case feedRepositoryNotVisible(repositoryFullName: String)
    case rateLimited
    case requestFailed(operationName: String, statusCode: Int)
    case graphQLErrors(operationName: String, messages: [String])
    case responseUnreadable(operationName: String)
    case pullRequestNotMerged(number: Int)
    case weeklyEditionUnreadable(number: Int)
    case signInRequired

    var rejectsFeedAccess: Bool {
        switch self {
        case .accessTokenRejected, .feedRepositoryNotVisible:
            true
        case .rateLimited, .requestFailed, .graphQLErrors, .responseUnreadable, .pullRequestNotMerged, .weeklyEditionUnreadable, .signInRequired:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .accessTokenRejected:
            "GitHub no longer accepts this sign-in. Sign in with Revyl again."
        case .feedRepositoryNotVisible(let repositoryFullName):
            "Revyl's GitHub App no longer reaches \(repositoryFullName) for you. Choose another repository."
        case .rateLimited:
            "GitHub's rate limit is used up for now. ShipTok tries again shortly."
        case .requestFailed(let operationName, let statusCode):
            "GitHub answered \(statusCode) to \(operationName)."
        case .graphQLErrors(let operationName, let messages):
            "GitHub refused \(operationName): \(messages.joined(separator: " "))"
        case .responseUnreadable(let operationName):
            "GitHub's answer to \(operationName) couldn't be read."
        case .pullRequestNotMerged(let number):
            "#\(number) isn't merged."
        case .weeklyEditionUnreadable(let number):
            "#\(number) isn't a weekly video ShipTok can read."
        case .signInRequired:
            "Sign in with Revyl to do that."
        }
    }
}

extension Error {
    var isTaskCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
