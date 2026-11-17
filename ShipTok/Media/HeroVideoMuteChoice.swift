import Observation

@MainActor
@Observable
final class HeroVideoMuteChoice {
    static let shared = HeroVideoMuteChoice()
    var isMuted = true

    private init() {}
}
