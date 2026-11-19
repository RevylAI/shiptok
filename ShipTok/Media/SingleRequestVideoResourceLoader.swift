import AVFoundation
import OSLog
import UniformTypeIdentifiers

struct MediaDownloadRejectedError: Error {
    let httpStatusCode: Int
}

struct VideoDownloadTooLargeError: Error {
    let byteCount: Int
}

// This viewer can't have the hosted video: Revyl's hosted video route refused them. No renewed URL or second request changes that (AGENTS.md, "Signed Media URLs").
struct HostedShipTokVideoRefusedError: Error {}

// The Revyl key a teammate's hosted videos are requested with, and what runs when Revyl refuses the sign-in itself rather than one video (AGENTS.md, "Signed Media URLs").
struct HostedVideoRevylSignIn: Sendable {
    let revylAPIKey: String
    let onRefused: @MainActor @Sendable () -> Void
}

// GitHub's signed media URLs expire five minutes after the fetch, so the video arrives in one request that keeps streaming past expiry and every later read, loops included, comes from memory. A finished download is saved on the device, and a saved video plays from there (AGENTS.md, "Signed Media URLs" and "Feed Caching").
final class SingleRequestVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let assetURL = SingleRequestVideoResourceLoader.makeAssetURL()
    let delegateQueue = DispatchQueue(label: "ai.revyl.shiptok.single-request-video-resource-loader")
    private let videoURLPathExtension: String
    private let videoURL: URL?
    private let savedMedia: PullRequestMediaDiskCache?
    // Only this build's own Revyl backend's hosted video route gets the person's Revyl key, so it never reaches another host, and only that route's own answer, never one after a redirect, refuses the viewer (AGENTS.md, "Signed Media URLs").
    private let isOnRevylHostedVideoRoute: Bool
    private let hostedVideoRevylSignIn: HostedVideoRevylSignIn?
    private var savedMediaItemID: String?
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionTask?
    private var hasFollowedRedirect = false
    // Revyl's refusal says in its body whether it refused the video or the sign-in, so the route's refusal is read to its end before the load fails.
    private var hostedVideoRefusalStatusCode: Int?
    private var hostedVideoRefusalBody = Data()
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
    private static let maximumHostedVideoRefusalByteCount = 16 * 1024
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")

    // A hosted video plays only for a Revyl account in an organization whose connected GitHub account GitHub lets read its repository, so a teammate's request for one carries their Revyl key. A demo visit sends no credential.
    init(videoURL: URL, savingInto savedMedia: PullRequestMediaDiskCache, asMediaItemID mediaItemID: String, failureLogLevel: OSLogType, hostedVideoRevylSignIn: HostedVideoRevylSignIn?) {
        self.videoURL = videoURL
        self.savedMedia = savedMedia
        videoURLPathExtension = videoURL.pathExtension
        isOnRevylHostedVideoRoute = RevylBackendConfiguration.servesHostedShipTokVideo(at: videoURL)
        self.hostedVideoRevylSignIn = isOnRevylHostedVideoRoute ? hostedVideoRevylSignIn : nil
        savedMediaItemID = mediaItemID
        self.failureLogLevel = failureLogLevel
        super.init()
        delegateQueue.async { self.startDownload() }
    }

    // Runs on the delegate queue, so a download that already finished has queued its save before this returns, and one that hasn't never saves. An unfinished load fails as cancelled at once, so AVFoundation's waiting requests are answered at once, and whatever the session reports later is ignored.
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
        hostedVideoRevylSignIn = nil
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

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        pendingLoadingRequests.append(loadingRequest)
        respondToPendingLoadingRequests()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pendingLoadingRequests.removeAll { $0 === loadingRequest }
    }

    private func startDownload() {
        guard let videoURL, !isDownloadStopped else { return }
        var request = URLRequest(url: videoURL)
        if let hostedVideoRevylSignIn {
            request.setValue("Bearer \(hostedVideoRevylSignIn.revylAPIKey)", forHTTPHeaderField: "Authorization")
        }
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === downloadTask else { return }
        guard acceptResponseOnFirstSight(of: dataTask) else {
            if hostedVideoRefusalStatusCode != nil {
                hostedVideoRefusalBody.append(data.prefix(Self.maximumHostedVideoRefusalByteCount - hostedVideoRefusalBody.count))
            }
            return
        }
        guard receivedBytes.count + data.count <= Self.maximumVideoByteCount else {
            failOversizedDownload(of: dataTask, byteCount: receivedBytes.count + data.count)
            return
        }
        receivedBytes.append(data)
        respondToPendingLoadingRequests()
    }

    // The hosted video's redirect goes to a file signed in its query string, which S3 refuses beside an Authorization header, and the Revyl key must never leave Revyl's backend, so the redirect never carries it, and what answers after it never speaks for the Revyl sign-in (AGENTS.md, "Signed Media URLs").
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if task === downloadTask {
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
        } else if let hostedVideoRefusalStatusCode {
            refuseHostedVideo(httpStatusCode: hostedVideoRefusalStatusCode)
        }
        respondToPendingLoadingRequests()
    }

    // Revyl refusing the Revyl key itself, rather than this video, means the sign-in changed, so the app asks Revyl where it stands (AGENTS.md, "Signed Media URLs").
    private func refuseHostedVideo(httpStatusCode: Int) {
        downloadFailure = HostedShipTokVideoRefusedError()
        let refusalKey = RevylRefusal.decode(from: hostedVideoRefusalBody)?.key
        Self.logger.notice("Revyl refused a hosted video with HTTP status \(httpStatusCode) \(refusalKey ?? "without a key", privacy: .public)")
        let refusesRevylSignIn = switch refusalKey {
        case RevylRefusal.revylSignInRequiredKey?, RevylRefusal.revylOrganizationRequiredKey?, RevylRefusal.githubAccountRequiredKey?: true
        default: httpStatusCode == 401
        }
        guard refusesRevylSignIn, let hostedVideoRevylSignIn else { return }
        Task { @MainActor in hostedVideoRevylSignIn.onRefused() }
    }

    private func acceptResponseOnFirstSight(of task: URLSessionTask) -> Bool {
        if downloadFailure != nil { return false }
        if hasAcceptedResponse { return true }
        let httpResponse = task.response as? HTTPURLResponse
        let httpStatusCode = httpResponse?.statusCode ?? 0
        guard httpStatusCode == 200, let response = task.response else {
            if isOnRevylHostedVideoRoute, !hasFollowedRedirect, [401, 403, 404].contains(httpStatusCode) {
                hostedVideoRefusalStatusCode = httpStatusCode
                return false
            }
            downloadFailure = MediaDownloadRejectedError(httpStatusCode: httpStatusCode)
            Self.logger.log(level: failureLogLevel, "Video download rejected with HTTP status \(httpStatusCode)")
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
