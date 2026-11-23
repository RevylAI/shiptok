import SwiftUI

enum ShipTokVibe: String, CaseIterable, Hashable, Sendable, Codable {
    case good
    case bad

    var displayName: String {
        switch self {
        case .good: "Good vibes"
        case .bad: "Bad vibes"
        }
    }

    var tintColor: Color {
        switch self {
        case .good: RevylBrandColor.success
        case .bad: RevylBrandColor.danger
        }
    }

    var systemImageName: String {
        switch self {
        case .good: "hand.thumbsup"
        case .bad: "hand.thumbsdown"
        }
    }
}

struct VibeTally: Equatable {
    var goodVibeCount: Int
    var badVibeCount: Int
    var viewerVibe: ShipTokVibe?

    func count(of vibe: ShipTokVibe) -> Int {
        switch vibe {
        case .good: goodVibeCount
        case .bad: badVibeCount
        }
    }
}
