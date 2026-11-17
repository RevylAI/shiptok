import AVFoundation
import OSLog

// AVAudioSession calls can block, so every change runs in order on one serial queue and never on the main thread.
enum AppAudioSession {
    private static let audioSessionQueue = DispatchQueue(label: "ai.revyl.shiptok.audio-session")
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "audio-session")

    // Muted autoplay mixes so it never stops the listener's music; the deck's sound and dictation switch away and back themselves.
    static func useAmbientCategoryIfStillSystemDefault() {
        audioSessionQueue.async {
            guard AVAudioSession.sharedInstance().category == .soloAmbient else { return }
            setCategory(.ambient, mode: .default)
        }
    }

    static func usePlaybackCategoryForVideoWithSound() {
        audioSessionQueue.async {
            let audioSession = AVAudioSession.sharedInstance()
            guard audioSession.category != .playback else { return }
            setCategory(.playback, mode: .moviePlayback)
            do {
                try audioSession.setActive(true)
            } catch {
                logFailure("Activating the audio session for video with sound", error)
            }
        }
    }

    static func useRecordCategoryForSpeechDictation() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            audioSessionQueue.async {
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
                    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func returnToAmbientCategoryForMutedVideoAutoplay() {
        audioSessionQueue.async {
            let audioSession = AVAudioSession.sharedInstance()
            guard audioSession.category != .ambient else { return }
            setCategory(.ambient, mode: .default)
            do {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                logFailure("Deactivating the audio session so other apps resume", error)
            }
        }
    }

    private static func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode) {
        do {
            try AVAudioSession.sharedInstance().setCategory(category, mode: mode)
        } catch {
            logFailure("Setting the audio session category", error)
        }
    }

    private static func logFailure(_ attemptedChange: String, _ error: any Error) {
        let sessionError = error as NSError
        logger.error("\(attemptedChange, privacy: .public) failed: \(sessionError.domain, privacy: .public) \(sessionError.code)")
    }
}
