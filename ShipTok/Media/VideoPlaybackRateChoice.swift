import Foundation
import Observation
import OSLog

// The speed every video plays at, saved on the device.
@MainActor
@Observable
final class VideoPlaybackRateChoice {
    static let offeredPlaybackRates: [Float] = [1, 1.5, 2]
    private static let chosenPlaybackRateDefaultsKey = "video-playback-rate"
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")

    private(set) var chosenPlaybackRate: Float

    var chosenPlaybackRateText: String {
        "\(chosenPlaybackRate.formatted(.number.precision(.fractionLength(0...1))))x"
    }

    static func savedOnDevice() -> VideoPlaybackRateChoice {
        let storedPlaybackRate = UserDefaults.standard.float(forKey: chosenPlaybackRateDefaultsKey)
        return VideoPlaybackRateChoice(chosenPlaybackRate: offeredPlaybackRates.contains(storedPlaybackRate) ? storedPlaybackRate : 1)
    }

    private init(chosenPlaybackRate: Float) {
        self.chosenPlaybackRate = chosenPlaybackRate
    }

    func chooseNextOfferedPlaybackRate() {
        let chosenIndex = Self.offeredPlaybackRates.firstIndex(of: chosenPlaybackRate) ?? 0
        chosenPlaybackRate = Self.offeredPlaybackRates[(chosenIndex + 1) % Self.offeredPlaybackRates.count]
        UserDefaults.standard.set(chosenPlaybackRate, forKey: Self.chosenPlaybackRateDefaultsKey)
        Self.logger.info("Chose \(self.chosenPlaybackRateText, privacy: .public) for every video")
    }
}
