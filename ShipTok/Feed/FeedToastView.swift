import SwiftUI

struct FeedToastView: View {
    let message: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(RevylBrandColor.textPrimary)
                .lineLimit(2)
                .padding(.vertical, 8)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.footnote.bold())
                        .foregroundStyle(RevylBrandColor.brandText)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RevylBrandColor.textMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(RevylBrandColor.surfaceFloating))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RevylBrandColor.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct FeedMessageView: View {
    let systemImageName: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImageName)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(RevylBrandColor.brandText)
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(RevylBrandColor.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(RevylBrandColor.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.revylSecondary)
                    .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
