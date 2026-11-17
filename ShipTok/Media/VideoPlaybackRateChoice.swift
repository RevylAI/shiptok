import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class VideoPlaybackRateChoice {
    static let shared = VideoPlaybackRateChoice()
    static let offeredPlaybackRates: [Float] = [1, 1.5, 2]
    private static let chosenPlaybackRateDefaultsKey = "videoPlaybackRate"
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")

    private(set) var chosenPlaybackRate: Float

    var chosenPlaybackRateText: String {
        "\(chosenPlaybackRate.formatted(.number.precision(.fractionLength(0...1))))x"
    }

    private init() {
        let storedPlaybackRate = UserDefaults.standard.float(forKey: Self.chosenPlaybackRateDefaultsKey)
        chosenPlaybackRate = Self.offeredPlaybackRates.contains(storedPlaybackRate) ? storedPlaybackRate : 1
    }

    func chooseNextOfferedPlaybackRate() {
        let chosenIndex = Self.offeredPlaybackRates.firstIndex(of: chosenPlaybackRate) ?? 0
        chosenPlaybackRate = Self.offeredPlaybackRates[(chosenIndex + 1) % Self.offeredPlaybackRates.count]
        UserDefaults.standard.set(chosenPlaybackRate, forKey: Self.chosenPlaybackRateDefaultsKey)
        Self.logger.info("Chose \(self.chosenPlaybackRateText, privacy: .public) for every video")
    }
}
