import AVFoundation
import OSLog
import UniformTypeIdentifiers

struct MediaDownloadRejectedError: Error {
    let httpStatusCode: Int
}

struct VideoDownloadTooLargeError: Error {
    let byteCount: Int
}

// This viewer can't have the hosted video: Revyl's hosted video route refused them, or GitHub refused the sign-in whose token would ask. No renewed URL or second request changes that (AGENTS.md, "Signed Media URLs").
struct HostedShipTokVideoRefusedError: Error {}

// A signed-in person's GitHub token couldn't be had, so their hosted video was never requested without it.
struct GitHubAccessTokenUnavailableError: Error {}

// GitHub's signed media URLs expire five minutes after the fetch, so the video arrives in one request that keeps streaming past expiry and every later read, loops included, comes from memory. A finished download is saved on the device, and a saved video plays from there (AGENTS.md, "Signed Media URLs" and "Feed Caching").
final class SingleRequestVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let assetURL = SingleRequestVideoResourceLoader.makeAssetURL()
    let delegateQueue = DispatchQueue(label: "ai.revyl.shiptok.single-request-video-resource-loader")
    private let videoURLPathExtension: String
    private let videoURL: URL?
    private let savedMedia: PullRequestMediaDiskCache?
    // Only this build's own Revyl backend's hosted video route gets the person's GitHub token, so it never reaches another host, and only that route's own answer, never one after a redirect, refuses the viewer (AGENTS.md, "Signed Media URLs").
    private let isOnRevylHostedVideoRoute: Bool
    private let revylBackendAccessTokenVault: GitHubAccessTokenVault?
    private var savedMediaItemID: String?
    private var downloadSession: URLSession?
    // A request Revyl refused the token on is replaced once, and whatever its cancelled task still reports is ignored.
    private var downloadTask: URLSessionTask?
    private var presentedGitHubAccessToken: String?
    private var hasFollowedRedirect = false
    private var hasRenewedRejectedGitHubAccessToken = false
    private var isDownloadStopped = false
    private lazy var sessionDelegateQueue: OperationQueue = {
        let sessionDelegateQueue = OperationQueue()
        sessionDelegateQueue.underlyingQueue = delegateQueue
        sessionDelegateQueue.maxConcurrentOperationCount = 1
        return sessionDelegateQueue
    }()
    private var receivedBytes = Data()
    private var expectedByteCount: Int?
    private var contentTypeIdentifier = UTType.mpeg4Movie.identifier
    private var hasAcceptedResponse = false
    private var isDownloadComplete = false
    private var downloadFailure: (any Error)?
    private var pendingLoadingRequests: [AVAssetResourceLoadingRequest] = []
    private let failureLogLevel: OSLogType
    // The whole video is held in memory, so one over the size every ShipTok video keeps to fails like broken media (docs/shiptok-format.md, "ShipTok video").
    private static let maximumVideoByteCount = 100 * 1024 * 1024
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")

    // A hosted video on a private repository plays only for someone Revyl's backend sees GitHub lets read it, so a signed-in person's request for one carries their GitHub token and never goes without it.
    init(videoURL: URL, savingInto savedMedia: PullRequestMediaDiskCache, asMediaItemID mediaItemID: String, failureLogLevel: OSLogType, signedInGitHubAccessTokenVault: GitHubAccessTokenVault) {
        self.videoURL = videoURL
        self.savedMedia = savedMedia
        videoURLPathExtension = videoURL.pathExtension
        isOnRevylHostedVideoRoute = RevylBackendConfiguration.servesHostedShipTokVideo(at: videoURL)
        revylBackendAccessTokenVault = isOnRevylHostedVideoRoute ? signedInGitHubAccessTokenVault : nil
        savedMediaItemID = mediaItemID
        self.failureLogLevel = failureLogLevel
        super.init()
        guard let revylBackendAccessTokenVault else {
            delegateQueue.async { self.startDownload(presentingGitHubAccessToken: nil) }
            return
        }
        Task {
            do {
                let accessToken = try await revylBackendAccessTokenVault.validAccessToken()
                delegateQueue.async { self.startDownload(presentingGitHubAccessToken: accessToken) }
            } catch {
                let isSignInRefusal = Self.isSignInRefusal(error)
                delegateQueue.async { self.failWithoutGitHubAccessToken(isSignInRefusal: isSignInRefusal) }
            }
        }
    }

    // Runs on the delegate queue, so a download that already finished has queued its save before this returns, and one that hasn't never saves. An unfinished load fails as cancelled at once, so AVFoundation's waiting requests are answered even while the token is still on its way, and whatever the vault or the session reports later is ignored.
    func stopDownloadWithoutSaving() {
        delegateQueue.sync {
            savedMediaItemID = nil
            isDownloadStopped = true
            downloadSession?.invalidateAndCancel()
            if !isDownloadComplete, downloadFailure == nil {
                downloadFailure = URLError(.cancelled)
            }
            respondToPendingLoadingRequests()
        }
    }

    init(savedVideoFileURL: URL) throws {
        videoURL = nil
        savedMedia = nil
        videoURLPathExtension = savedVideoFileURL.pathExtension
        isOnRevylHostedVideoRoute = false
        revylBackendAccessTokenVault = nil
        savedMediaItemID = nil
        failureLogLevel = .error
        receivedBytes = try Data(contentsOf: savedVideoFileURL, options: .alwaysMapped)
        expectedByteCount = receivedBytes.count
        contentTypeIdentifier = UTType(filenameExtension: savedVideoFileURL.pathExtension)?.identifier ?? UTType.mpeg4Movie.identifier
        hasAcceptedResponse = true
        isDownloadComplete = true
        super.init()
    }

    private static func makeAssetURL() -> URL {
        var assetURLComponents = URLComponents()
        assetURLComponents.scheme = "shiptok-single-request-video"
        assetURLComponents.host = UUID().uuidString
        assetURLComponents.path = "/video"
        guard let assetURL = assetURLComponents.url else {
            preconditionFailure("A scheme, UUID host and fixed path always form a URL")
        }
        return assetURL
    }

    var hasFailed: Bool {
        delegateQueue.sync { downloadFailure != nil }
    }

    var wasRefusedToViewer: Bool {
        delegateQueue.sync { downloadFailure is HostedShipTokVideoRefusedError }
    }

    var lackedGitHubAccessToken: Bool {
        delegateQueue.sync { downloadFailure is GitHubAccessTokenUnavailableError }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        pendingLoadingRequests.append(loadingRequest)
        respondToPendingLoadingRequests()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pendingLoadingRequests.removeAll { $0 === loadingRequest }
    }

    private func startDownload(presentingGitHubAccessToken accessToken: String?) {
        guard let videoURL, !isDownloadStopped else { return }
        var request = URLRequest(url: videoURL)
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        presentedGitHubAccessToken = accessToken
        hasFollowedRedirect = false
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 30 * 60
        let downloadSession = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: sessionDelegateQueue)
        let downloadTask = downloadSession.dataTask(with: request)
        self.downloadSession = downloadSession
        self.downloadTask = downloadTask
        downloadTask.resume()
        downloadSession.finishTasksAndInvalidate()
    }

    // Revyl answers 401 when GitHub refuses the token, as it does once the token expires or another refresh retires it, so the sign-in is renewed and the video requested once more. A video's refusal never ends the sign-in (AGENTS.md, "iOS App").
    private func renewRejectedGitHubAccessToken(_ rejectedAccessToken: String, from accessTokenVault: GitHubAccessTokenVault, replacing rejectedTask: URLSessionTask) {
        hasRenewedRejectedGitHubAccessToken = true
        downloadTask = nil
        rejectedTask.cancel()
        Self.logger.notice("Revyl refused the GitHub token for a hosted video, so the sign-in is renewed and the video requested once more")
        Task {
            do {
                let replacementAccessToken = try await accessTokenVault.accessTokenReplacing(rejectedAccessToken: rejectedAccessToken)
                delegateQueue.async { self.startDownload(presentingGitHubAccessToken: replacementAccessToken) }
            } catch {
                let isSignInRefusal = Self.isSignInRefusal(error)
                delegateQueue.async { self.failWithoutGitHubAccessToken(isSignInRefusal: isSignInRefusal) }
            }
        }
    }

    // GitHub refusing the sign-in, with no refresh token left or a refresh it turned down, and the sign-in ending are final for this viewer, so the video is refused to them without ending the sign-in. Anything else, offline or the Keychain busy for example, says nothing about the video, so the load fails as one to try again (AGENTS.md, "Signed Media URLs").
    private func failWithoutGitHubAccessToken(isSignInRefusal: Bool) {
        guard !isDownloadStopped else { return }
        if isSignInRefusal {
            Self.logger.notice("The sign-in has no GitHub token Revyl can take for a hosted video, so the video is unavailable")
            downloadFailure = HostedShipTokVideoRefusedError()
        } else {
            Self.logger.notice("No GitHub token was at hand for a hosted video, so it waits to be tried again")
            downloadFailure = GitHubAccessTokenUnavailableError()
        }
        respondToPendingLoadingRequests()
    }

    private static func isSignInRefusal(_ accessTokenVaultError: any Error) -> Bool {
        switch accessTokenVaultError {
        case GitHubAPIError.accessTokenRejected, is CancellationError: true
        default: false
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === downloadTask, acceptResponseOnFirstSight(of: dataTask) else { return }
        guard receivedBytes.count + data.count <= Self.maximumVideoByteCount else {
            failOversizedDownload(of: dataTask, byteCount: receivedBytes.count + data.count)
            return
        }
        receivedBytes.append(data)
        respondToPendingLoadingRequests()
    }

    // The hosted video's redirect goes to a file signed in its query string, which S3 refuses beside an Authorization header, and the GitHub token must never leave Revyl's backend, so the redirect never carries it, and a 401 from where it leads never renews the token (AGENTS.md, "Signed Media URLs").
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if task === downloadTask {
            presentedGitHubAccessToken = nil
            hasFollowedRedirect = true
        }
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        var redirectedRequest = request
        redirectedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        redirectedRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(redirectedRequest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard task === downloadTask else { return }
        if let error {
            if downloadFailure == nil {
                downloadFailure = error
                let downloadError = error as NSError
                Self.logger.log(level: failureLogLevel, "Video download failed after \(self.receivedBytes.count) bytes: \(downloadError.domain, privacy: .public) \(downloadError.code)")
            }
        } else if acceptResponseOnFirstSight(of: task) {
            isDownloadComplete = true
            expectedByteCount = receivedBytes.count
            if let savedMediaItemID, let savedMedia {
                savedMedia.saveVideoInBackground(receivedBytes, contentTypeIdentifier: contentTypeIdentifier, forMediaItemID: savedMediaItemID)
            }
        }
        respondToPendingLoadingRequests()
    }

    private func acceptResponseOnFirstSight(of task: URLSessionTask) -> Bool {
        if downloadFailure != nil { return false }
        if hasAcceptedResponse { return true }
        let httpResponse = task.response as? HTTPURLResponse
        let httpStatusCode = httpResponse?.statusCode ?? 0
        if httpStatusCode == 401, let rejectedAccessToken = presentedGitHubAccessToken, let revylBackendAccessTokenVault, !hasRenewedRejectedGitHubAccessToken {
            renewRejectedGitHubAccessToken(rejectedAccessToken, from: revylBackendAccessTokenVault, replacing: task)
            return false
        }
        guard httpStatusCode == 200, let response = task.response else {
            if isOnRevylHostedVideoRoute, !hasFollowedRedirect, [401, 403, 404].contains(httpStatusCode) {
                downloadFailure = HostedShipTokVideoRefusedError()
                Self.logger.notice("Revyl refused a hosted video with HTTP status \(httpStatusCode)")
            } else {
                downloadFailure = MediaDownloadRejectedError(httpStatusCode: httpStatusCode)
                Self.logger.log(level: failureLogLevel, "Video download rejected with HTTP status \(httpStatusCode)")
            }
            task.cancel()
            return false
        }
        guard response.expectedContentLength <= Self.maximumVideoByteCount else {
            failOversizedDownload(of: task, byteCount: Int(response.expectedContentLength))
            return false
        }
        hasAcceptedResponse = true
        if response.expectedContentLength >= 0 {
            expectedByteCount = Int(response.expectedContentLength)
            receivedBytes.reserveCapacity(Int(response.expectedContentLength))
        }
        let movieType = [response.mimeType.flatMap { UTType(mimeType: $0) }, UTType(filenameExtension: videoURLPathExtension)]
            .compactMap { $0 }
            .first { $0.conforms(to: .movie) }
        if let movieType {
            contentTypeIdentifier = movieType.identifier
        }
        return true
    }

    private func failOversizedDownload(of task: URLSessionTask, byteCount: Int) {
        downloadFailure = VideoDownloadTooLargeError(byteCount: byteCount)
        Self.logger.log(level: failureLogLevel, "Video download stopped at \(byteCount) bytes, over the \(Self.maximumVideoByteCount)-byte limit")
        task.cancel()
    }

    private func respondToPendingLoadingRequests() {
        pendingLoadingRequests.removeAll { loadingRequest in
            if loadingRequest.isCancelled { return true }
            if let downloadFailure {
                loadingRequest.finishLoading(with: downloadFailure)
                return true
            }
            guard hasAcceptedResponse else { return false }
            if let contentInformationRequest = loadingRequest.contentInformationRequest {
                guard let expectedByteCount else { return false }
                contentInformationRequest.contentType = contentTypeIdentifier
                contentInformationRequest.contentLength = Int64(expectedByteCount)
                contentInformationRequest.isByteRangeAccessSupported = true
            }
            guard let dataRequest = loadingRequest.dataRequest else {
                loadingRequest.finishLoading()
                return true
            }
            let requestedEndOffset = dataRequest.requestsAllDataToEndOfResource
                ? (expectedByteCount ?? Int.max)
                : Int(dataRequest.requestedOffset) + dataRequest.requestedLength
            let availableEndOffset = min(requestedEndOffset, receivedBytes.count)
            let currentOffset = Int(dataRequest.currentOffset)
            if currentOffset < availableEndOffset {
                dataRequest.respond(with: receivedBytes.subdata(in: currentOffset..<availableEndOffset))
            }
            guard availableEndOffset >= requestedEndOffset || isDownloadComplete else { return false }
            loadingRequest.finishLoading()
            return true
        }
    }
}
