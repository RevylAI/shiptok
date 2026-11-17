import AVFoundation
import OSLog
import UniformTypeIdentifiers

struct MediaDownloadRejectedError: Error {
    let httpStatusCode: Int
}

// GitHub's signed media URLs expire five minutes after the fetch, so the video arrives in one request that keeps streaming past expiry and every later read, loops included, comes from memory. A finished download is saved on the device, and a saved video plays from there (shiptok/AGENTS.md, Signed Media URLs and Feed Caching).
final class SingleRequestVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let assetURL = SingleRequestVideoResourceLoader.makeAssetURL()
    let delegateQueue = DispatchQueue(label: "ai.revyl.shiptok.single-request-video-resource-loader")
    private let videoURLPathExtension: String
    private var savedMediaItemID: String?
    private var downloadSession: URLSession?
    private var receivedBytes = Data()
    private var expectedByteCount: Int?
    private var contentTypeIdentifier = UTType.mpeg4Movie.identifier
    private var hasAcceptedResponse = false
    private var isDownloadComplete = false
    private var downloadFailure: (any Error)?
    private var pendingLoadingRequests: [AVAssetResourceLoadingRequest] = []
    private let failureLogLevel: OSLogType
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")

    init(videoURL: URL, savingAsMediaItemID mediaItemID: String, failureLogLevel: OSLogType) {
        videoURLPathExtension = videoURL.pathExtension
        savedMediaItemID = mediaItemID
        self.failureLogLevel = failureLogLevel
        super.init()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 30 * 60
        let sessionDelegateQueue = OperationQueue()
        sessionDelegateQueue.underlyingQueue = delegateQueue
        sessionDelegateQueue.maxConcurrentOperationCount = 1
        let downloadSession = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: sessionDelegateQueue)
        self.downloadSession = downloadSession
        downloadSession.dataTask(with: videoURL).resume()
        downloadSession.finishTasksAndInvalidate()
    }

    // Runs on the delegate queue, so a download that already finished has queued its save before this returns, and one that hasn't never saves.
    func stopDownloadWithoutSaving() {
        delegateQueue.sync {
            savedMediaItemID = nil
            downloadSession?.invalidateAndCancel()
        }
    }

    init(savedVideoFileURL: URL) throws {
        videoURLPathExtension = savedVideoFileURL.pathExtension
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

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        pendingLoadingRequests.append(loadingRequest)
        respondToPendingLoadingRequests()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pendingLoadingRequests.removeAll { $0 === loadingRequest }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard acceptResponseOnFirstSight(of: dataTask) else { return }
        receivedBytes.append(data)
        respondToPendingLoadingRequests()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
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
        if let error {
            if downloadFailure == nil {
                downloadFailure = error
                let downloadError = error as NSError
                Self.logger.log(level: failureLogLevel, "Video download failed after \(self.receivedBytes.count) bytes: \(downloadError.domain, privacy: .public) \(downloadError.code)")
            }
        } else if acceptResponseOnFirstSight(of: task) {
            isDownloadComplete = true
            expectedByteCount = receivedBytes.count
            if let savedMediaItemID {
                PullRequestMediaDiskCache.saveVideoInBackground(receivedBytes, contentTypeIdentifier: contentTypeIdentifier, forMediaItemID: savedMediaItemID)
            }
        }
        respondToPendingLoadingRequests()
    }

    private func acceptResponseOnFirstSight(of task: URLSessionTask) -> Bool {
        if hasAcceptedResponse { return true }
        if downloadFailure != nil { return false }
        let httpStatusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatusCode == 200, let response = task.response else {
            downloadFailure = MediaDownloadRejectedError(httpStatusCode: httpStatusCode)
            Self.logger.log(level: failureLogLevel, "Video download rejected with HTTP status \(httpStatusCode)")
            task.cancel()
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
