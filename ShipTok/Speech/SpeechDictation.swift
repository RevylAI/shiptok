import AVFoundation
import Observation
import OSLog
import Speech

@MainActor
@Observable
final class SpeechDictation {
    enum Status: Equatable {
        case idle
        case starting
        case listening
        case microphonePermissionDenied
        case speechRecognitionPermissionDenied
        case speechRecognitionUnavailable
        case failedToStart
        case stoppedByError
        case heardNothing
    }

    private(set) var status: Status = .idle
    private(set) var transcribedText = ""
    private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let speechRecognizer = SFSpeechRecognizer()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var dictationAttemptID = UUID()
    private static var isOnDeviceRecognizerUnusable = false
    private static let onDeviceRecognizerErrorDomain = "kLSRErrorDomain"
    private static let onDeviceRecognizerInitializationFailedCode = 300
    private static let noSpeechTimeout: Duration = .seconds(10)
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "speech-dictation")

    func startDictating() async {
        guard status != .listening, status != .starting else { return }
        let attemptID = beginDictationAttempt()
        status = .starting
        let isMicrophoneAllowed = await AVAudioApplication.requestRecordPermission()
        guard isCurrentDictationAttempt(attemptID) else { return }
        let speechRecognitionAuthorization = await Self.requestSpeechRecognitionAuthorization()
        guard isCurrentDictationAttempt(attemptID) else { return }
        guard isMicrophoneAllowed else {
            status = .microphonePermissionDenied
            return
        }
        guard speechRecognitionAuthorization == .authorized else {
            status = .speechRecognitionPermissionDenied
            return
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            status = .speechRecognitionUnavailable
            return
        }
        await startListening(with: speechRecognizer, attemptID: attemptID)
    }

    func stopDictating() {
        guard status == .listening || status == .starting else { return }
        let didHearNothing = status == .listening && transcribedText.isEmpty
        endDictationAttempt()
        status = didHearNothing ? .heardNothing : .idle
    }

    func cancelDictating() {
        guard status == .listening || status == .starting else { return }
        endDictationAttempt()
        status = .idle
    }

    private func beginDictationAttempt() -> UUID {
        let attemptID = UUID()
        dictationAttemptID = attemptID
        return attemptID
    }

    private func isCurrentDictationAttempt(_ attemptID: UUID) -> Bool {
        guard attemptID == dictationAttemptID else { return false }
        guard !Task.isCancelled else {
            endDictationAttempt()
            status = .idle
            return false
        }
        return true
    }

    private func startListening(with speechRecognizer: SFSpeechRecognizer, attemptID: UUID) async {
        do {
            try await AppAudioSession.useRecordCategoryForSpeechDictation()
        } catch {
            AppAudioSession.returnToAmbientCategoryForMutedVideoAutoplay()
            guard attemptID == dictationAttemptID else { return }
            Self.logStartFailure(error)
            status = .failedToStart
            return
        }
        guard isCurrentDictationAttempt(attemptID) else {
            AppAudioSession.returnToAmbientCategoryForMutedVideoAutoplay()
            return
        }
        do {
            try beginListening(with: speechRecognizer, attemptID: attemptID)
        } catch {
            Self.logStartFailure(error)
            endDictationAttempt()
            status = .failedToStart
        }
    }

    private func beginListening(with speechRecognizer: SFSpeechRecognizer, attemptID: UUID) throws {
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true
        recognitionRequest.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition && !Self.isOnDeviceRecognizerUnusable
        self.recognitionRequest = recognitionRequest
        let microphoneInputNode = audioEngine.inputNode
        let microphoneFormat = microphoneInputNode.outputFormat(forBus: 0)
        guard microphoneFormat.sampleRate > 0, microphoneFormat.channelCount > 0 else {
            throw CocoaError(.featureUnsupported)
        }
        microphoneInputNode.installTap(onBus: 0, bufferSize: 1024, format: microphoneFormat, block: Self.makeMicrophoneTap(appendingTo: recognitionRequest))
        audioEngine.prepare()
        try audioEngine.start()
        transcribedText = ""
        recognitionTask = speechRecognizer.recognitionTask(
            with: recognitionRequest,
            resultHandler: Self.makeRecognitionResultHandler(reportingTo: self, attemptID: attemptID)
        )
        status = .listening
        Self.logger.info("Dictation listening, on-device recognition required: \(recognitionRequest.requiresOnDeviceRecognition, privacy: .public)")
        Task { [weak self] in await self?.stopIfNothingHeard(attemptID: attemptID) }
    }

    // Silent input can leave the server recognizer waiting with no result or error, so a quiet attempt ends here.
    private func stopIfNothingHeard(attemptID: UUID) async {
        try? await Task.sleep(for: Self.noSpeechTimeout)
        guard attemptID == dictationAttemptID, status == .listening, transcribedText.isEmpty else { return }
        Self.logger.info("Dictation heard nothing before the no-speech timeout")
        stopDictating()
    }

    private func endDictationAttempt() {
        dictationAttemptID = UUID()
        guard let recognitionRequest else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest.endAudio()
        recognitionTask?.finish()
        self.recognitionRequest = nil
        recognitionTask = nil
        AppAudioSession.returnToAmbientCategoryForMutedVideoAutoplay()
    }

    private func applyRecognitionUpdate(attemptID: UUID, transcription: String?, isFinal: Bool, recognitionError: (any Error)?) {
        guard attemptID == dictationAttemptID else { return }
        if let transcription {
            transcribedText = transcription
        }
        guard status == .listening, isFinal || recognitionError != nil else { return }
        let didRequireOnDeviceRecognition = recognitionRequest?.requiresOnDeviceRecognition == true
        endDictationAttempt()
        guard let recognitionError else {
            status = transcribedText.isEmpty ? .heardNothing : .idle
            return
        }
        let speechError = recognitionError as NSError
        // Missing on-device speech assets fail this way, so dictation carries on with the standard recognizer.
        if didRequireOnDeviceRecognition,
           speechError.domain == Self.onDeviceRecognizerErrorDomain,
           speechError.code == Self.onDeviceRecognizerInitializationFailedCode,
           let speechRecognizer {
            Self.isOnDeviceRecognizerUnusable = true
            guard speechRecognizer.isAvailable else {
                Self.logger.error("Dictation stopped: on-device recognition failed with \(speechError.domain, privacy: .public) \(speechError.code) and the standard recognizer is unavailable")
                status = .speechRecognitionUnavailable
                return
            }
            Self.logger.info("On-device recognition failed with \(speechError.domain, privacy: .public) \(speechError.code), retrying dictation with the standard recognizer")
            let retryAttemptID = beginDictationAttempt()
            Task { await startListening(with: speechRecognizer, attemptID: retryAttemptID) }
            return
        }
        Self.logger.error("Dictation stopped on error: \(speechError.domain, privacy: .public) \(speechError.code)")
        status = transcribedText.isEmpty ? .heardNothing : .stoppedByError
    }

    private static func logStartFailure(_ error: any Error) {
        let startError = error as NSError
        logger.error("Starting dictation failed: \(startError.domain, privacy: .public) \(startError.code)")
    }

    private nonisolated static func requestSpeechRecognitionAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                continuation.resume(returning: authorizationStatus)
            }
        }
    }

    private nonisolated static func makeMicrophoneTap(appendingTo recognitionRequest: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { microphoneBuffer, _ in
            recognitionRequest.append(microphoneBuffer)
        }
    }

    private nonisolated static func makeRecognitionResultHandler(
        reportingTo speechDictation: SpeechDictation,
        attemptID: UUID
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak speechDictation] recognitionResult, recognitionError in
            let transcription = recognitionResult?.bestTranscription.formattedString
            let isFinal = recognitionResult?.isFinal ?? false
            Task { @MainActor [speechDictation] in
                speechDictation?.applyRecognitionUpdate(attemptID: attemptID, transcription: transcription, isFinal: isFinal, recognitionError: recognitionError)
            }
        }
    }
}
