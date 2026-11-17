import SwiftUI

enum RevylBrandColor {
    static let canvas = Color(rgbHex: 0x0E0E10)
    static let surface = Color(rgbHex: 0x161618)
    static let surfaceRaised = Color(rgbHex: 0x1E1E20)
    static let surfaceFloating = Color(rgbHex: 0x222225)
    static let border = Color(rgbHex: 0x29292E)
    static let textPrimary = Color(rgbHex: 0xFAFAFA)
    static let textBody = Color(rgbHex: 0xD1D5DB)
    static let textMuted = Color(rgbHex: 0xA1A1AA)
    static let textSubtle = Color(rgbHex: 0x6B7280)
    static let brand = Color(rgbHex: 0x9D61FF)
    static let brandText = Color(rgbHex: 0xC4A1FF)
    static let brandGradientStart = Color(rgbHex: 0xA36BFF)
    static let brandGradientEnd = Color(rgbHex: 0x4E3EFF)
    static let success = Color(rgbHex: 0x34D399)
    static let danger = Color(rgbHex: 0xF87171)
    static let warning = Color(rgbHex: 0xFBBF24)

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brandGradientStart, brandGradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(rgbHex: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgbHex >> 16) & 0xFF) / 255,
            green: Double((rgbHex >> 8) & 0xFF) / 255,
            blue: Double(rgbHex & 0xFF) / 255,
            opacity: 1
        )
    }
}
