import Foundation
import Observation
import OSLog

// The speed every video plays at. The choice of a viewer who connected GitHub is saved on the device; a demo visit's lasts only as long as the visit (AGENTS.md, "Demo Mode").
@MainActor
@Observable
final class VideoPlaybackRateChoice {
    static let offeredPlaybackRates: [Float] = [1, 1.5, 2]
    private static let chosenPlaybackRateDefaultsKey = "video-playback-rate"
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")

    private(set) var chosenPlaybackRate: Float
    private let savesChoice: Bool

    var chosenPlaybackRateText: String {
        "\(chosenPlaybackRate.formatted(.number.precision(.fractionLength(0...1))))x"
    }

    static func savedOnDevice() -> VideoPlaybackRateChoice {
        let storedPlaybackRate = UserDefaults.standard.float(forKey: chosenPlaybackRateDefaultsKey)
        return VideoPlaybackRateChoice(chosenPlaybackRate: offeredPlaybackRates.contains(storedPlaybackRate) ? storedPlaybackRate : 1, savesChoice: true)
    }

    static func forDemoVisit() -> VideoPlaybackRateChoice {
        VideoPlaybackRateChoice(chosenPlaybackRate: 1, savesChoice: false)
    }

    private init(chosenPlaybackRate: Float, savesChoice: Bool) {
        self.chosenPlaybackRate = chosenPlaybackRate
        self.savesChoice = savesChoice
    }

    func chooseNextOfferedPlaybackRate() {
        let chosenIndex = Self.offeredPlaybackRates.firstIndex(of: chosenPlaybackRate) ?? 0
        chosenPlaybackRate = Self.offeredPlaybackRates[(chosenIndex + 1) % Self.offeredPlaybackRates.count]
        if savesChoice {
            UserDefaults.standard.set(chosenPlaybackRate, forKey: Self.chosenPlaybackRateDefaultsKey)
        }
        Self.logger.info("Chose \(self.chosenPlaybackRateText, privacy: .public) for every video")
    }
}
