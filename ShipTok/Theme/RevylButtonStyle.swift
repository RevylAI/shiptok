import SwiftUI

struct RevylButtonStyle: ButtonStyle {
    enum Prominence {
        case primary
        case secondary
        case destructive
    }

    let prominence: Prominence
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominence == .secondary ? RevylBrandColor.textPrimary : Color.white)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fillStyle))
            .overlay {
                if prominence == .secondary {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RevylBrandColor.border, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }

    private var fillStyle: AnyShapeStyle {
        switch prominence {
        case .primary: AnyShapeStyle(RevylBrandColor.brandGradient)
        case .secondary: AnyShapeStyle(RevylBrandColor.surfaceRaised)
        case .destructive: AnyShapeStyle(RevylBrandColor.danger.opacity(0.85))
        }
    }
}

extension ButtonStyle where Self == RevylButtonStyle {
    static var revylPrimary: RevylButtonStyle { RevylButtonStyle(prominence: .primary) }
    static var revylSecondary: RevylButtonStyle { RevylButtonStyle(prominence: .secondary) }
    static var revylDestructive: RevylButtonStyle { RevylButtonStyle(prominence: .destructive) }
}
