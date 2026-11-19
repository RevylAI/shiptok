import Foundation
import os
import OSLog

// The signed-in person's GitHub API. Every request carries their access token, and a refused one renews the sign-in once and tries again, since GitHub also refuses a token another refresh just retired (AGENTS.md, "iOS App").
final class GitHubAccountAPI: Sendable {
    private static let requestTimeoutSeconds: TimeInterval = 60
    private static let restPageSize = 100
    private static let rateLimitCooldownWithoutResetSeconds: TimeInterval = 60
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "github")

    private let accessTokenVault: GitHubAccessTokenVault
    private let urlSession: URLSession
    // GitHub refuses the account's requests until its limit resets, so none goes out before then, whichever part of the app asks.
    private let rateLimitCooldownEndDate = OSAllocatedUnfairLock<Date?>(initialState: nil)

    init(accessTokenVault: GitHubAccessTokenVault) {
        self.accessTokenVault = accessTokenVault
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = Self.requestTimeoutSeconds * 3
        urlSession = URLSession(configuration: sessionConfiguration, delegate: GitHubAPIRequestRedirectDelegate(), delegateQueue: nil)
    }

    deinit {
        urlSession.finishTasksAndInvalidate()
    }

    func sendAuthorizedRequest(_ request: URLRequest, operationName: String) async throws -> Data {
        if let currentCooldownEndDate = rateLimitCooldownEndDate.withLock({ $0 }), currentCooldownEndDate > .now {
            throw GitHubAPIError.rateLimited
        }
        let accessToken = try await accessTokenVault.validAccessToken()
        var (responseData, httpResponse) = try await send(request, accessToken: accessToken, operationName: operationName)
        if httpResponse.statusCode == 401 {
            Self.logger.notice("GitHub refused the access token on \(operationName, privacy: .public), so the sign-in is renewed")
            let replacementAccessToken = try await accessTokenVault.accessTokenReplacing(rejectedAccessToken: accessToken)
            (responseData, httpResponse) = try await send(request, accessToken: replacementAccessToken, operationName: operationName)
        }
        if httpResponse.statusCode == 401 {
            Self.logger.error("GitHub rejected the access token on \(operationName, privacy: .public)")
            throw GitHubAPIError.accessTokenRejected
        }
        let isRateLimitUsedUp = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
        let retryAfterSeconds = httpResponse.value(forHTTPHeaderField: "Retry-After").map { TimeInterval($0) ?? Self.rateLimitCooldownWithoutResetSeconds }
        let isRefusedForRateLimit = [403, 429].contains(httpResponse.statusCode) && (isRateLimitUsedUp || retryAfterSeconds != nil)
        if isRefusedForRateLimit || isRateLimitUsedUp {
            let rateLimitResetDate = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
            let cooldownEndDate = retryAfterSeconds.map { Date.now.addingTimeInterval($0) }
                ?? rateLimitResetDate
                ?? Date.now.addingTimeInterval(Self.rateLimitCooldownWithoutResetSeconds)
            rateLimitCooldownEndDate.withLock { $0 = max($0 ?? cooldownEndDate, cooldownEndDate) }
            Self.logger.error("GitHub's rate limit for this account is used up at \(operationName, privacy: .public), so nothing more is asked for \(Int(cooldownEndDate.timeIntervalSinceNow), privacy: .public) s")
        }
        if isRefusedForRateLimit {
            throw GitHubAPIError.rateLimited
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            Self.logger.error("GitHub answered \(httpResponse.statusCode) to \(operationName, privacy: .public)")
            throw GitHubAPIError.requestFailed(operationName: operationName, statusCode: httpResponse.statusCode)
        }
        return responseData
    }

    func fetchSignedInUserIdentity() async throws -> GitHubUserIdentity {
        let signedInUser: SignedInUserResponse = try await fetchRESTResource(path: "/user", operationName: "your GitHub account")
        return GitHubUserIdentity(githubUserID: signedInUser.id, githubLogin: signedInUser.login, githubAvatarURLString: signedInUser.avatarUrl)
    }

    // Exactly the repositories where an organization installed this build's GitHub App and the person has access, with no other allowlist (AGENTS.md, "iOS App").
    func fetchReachableRepositoryFullNames() async throws -> [String] {
        let installations = try await fetchEveryRESTPage(path: "/user/installations", operationName: "your GitHub App installations") { (page: InstallationsPage) in
            (page.totalCount, page.installations)
        }
        var repositoryFullNames: Set<String> = []
        for installation in installations {
            let repositories = try await fetchEveryRESTPage(path: "/user/installations/\(installation.id)/repositories", operationName: "an installation's repositories") { (page: InstallationRepositoriesPage) in
                (page.totalCount, page.repositories)
            }
            repositoryFullNames.formUnion(repositories.map(\.fullName))
        }
        return repositoryFullNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func fetchEveryRESTPage<Page: Decodable, Item>(
        path: String,
        operationName: String,
        items: (Page) -> (totalCount: Int, items: [Item])
    ) async throws -> [Item] {
        var everyItem: [Item] = []
        var pageNumber = 1
        while true {
            let page: Page = try await fetchRESTResource(path: path, queryItems: [
                URLQueryItem(name: "per_page", value: String(Self.restPageSize)),
                URLQueryItem(name: "page", value: String(pageNumber)),
            ], operationName: operationName)
            let (totalCount, pageItems) = items(page)
            everyItem += pageItems
            if pageItems.isEmpty || everyItem.count >= totalCount {
                return everyItem
            }
            pageNumber += 1
        }
    }

    private func fetchRESTResource<Resource: Decodable>(path: String, queryItems: [URLQueryItem] = [], operationName: String) async throws -> Resource {
        var urlComponents = URLComponents()
        urlComponents.scheme = "https"
        urlComponents.host = "api.github.com"
        urlComponents.path = path
        urlComponents.queryItems = queryItems.isEmpty ? nil : queryItems
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let responseData = try await sendAuthorizedRequest(request, operationName: operationName)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Resource.self, from: responseData)
        } catch {
            Self.logger.error("Reading GitHub's answer to \(operationName, privacy: .public) failed")
            throw GitHubAPIError.responseUnreadable(operationName: operationName)
        }
    }

    private func send(_ request: URLRequest, accessToken: String, operationName: String) async throws -> (Data, HTTPURLResponse) {
        var authorizedRequest = request
        authorizedRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (responseData, response) = try await urlSession.data(for: authorizedRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubAPIError.responseUnreadable(operationName: operationName)
        }
        return (responseData, httpResponse)
    }
}

private final class GitHubAPIRequestRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let isGitHubAPIRequest = request.url?.scheme == "https" && request.url?.host == "api.github.com"
        completionHandler(isGitHubAPIRequest ? request : nil)
    }
}

private struct SignedInUserResponse: Decodable {
    let id: Int64
    let login: String
    let avatarUrl: String?
}

private struct InstallationsPage: Decodable {
    struct Installation: Decodable {
        let id: Int64
    }
    let totalCount: Int
    let installations: [Installation]
}

private struct InstallationRepositoriesPage: Decodable {
    struct Repository: Decodable {
        let fullName: String
    }
    let totalCount: Int
    let repositories: [Repository]
}
