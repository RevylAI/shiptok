import SwiftUI
import UIKit

struct VibeFeedbackComposer: View {
    let vibe: PullRequestVibe
    let targetTitle: String
    @Binding var feedbackText: String
    let onSend: () -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void
    @State private var feedbackTextBeforeDictation = ""
    @State private var speechDictation = SpeechDictation()
    @State private var dictationStartTask: Task<Void, Never>?
    @FocusState private var isFeedbackFieldFocused: Bool
    @Environment(\.openURL) private var openURL

    private var trimmedFeedbackText: String {
        feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(vibe.tintColor).frame(width: 8, height: 8)
                Text(vibe.displayName)
                    .font(.subheadline.bold())
                    .foregroundStyle(vibe.tintColor)
                Text("on “\(targetTitle)”")
                    .font(.footnote)
                    .foregroundStyle(RevylBrandColor.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                takeBackVibeButton
            }
            feedbackField
            dictationStatusMessage
            HStack(spacing: 12) {
                Button("Skip") { finish { onSkip() } }
                    .buttonStyle(.revylSecondary)
                Button {
                    finish(onSend)
                } label: {
                    Text("Send").frame(maxWidth: .infinity)
                }
                .buttonStyle(RevylButtonStyle(prominence: vibe == .good ? .primary : .destructive))
                .disabled(trimmedFeedbackText.isEmpty)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(RevylBrandColor.surfaceFloating))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(RevylBrandColor.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .onDisappear {
            dictationStartTask?.cancel()
            speechDictation.cancelDictating()
        }
        .onChange(of: speechDictation.transcribedText) { _, transcribedText in
            guard !isFeedbackFieldFocused else { return }
            feedbackText = [feedbackTextBeforeDictation, transcribedText].filter { !$0.isEmpty }.joined(separator: " ")
        }
        .onChange(of: isFeedbackFieldFocused) { _, isFocused in
            if isFocused { speechDictation.cancelDictating() }
        }
    }

    private var takeBackVibeButton: some View {
        Button {
            finish { onCancel() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(RevylBrandColor.textMuted)
                .frame(width: 28, height: 28)
                .background(Circle().fill(RevylBrandColor.surfaceRaised))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-8)
        .accessibilityLabel("Take back \(vibe.displayName.lowercased())")
    }

    private var feedbackField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(vibe == .good ? "What did you like? Optional" : "What felt off? Optional", text: $feedbackText, axis: .vertical)
                .lineLimit(1...6)
                .focused($isFeedbackFieldFocused)
                .foregroundStyle(RevylBrandColor.textPrimary)
                .padding(.vertical, 12)
                .padding(.leading, 12)
            Button(action: toggleDictation) {
                Group {
                    if speechDictation.status == .starting {
                        ProgressView().tint(RevylBrandColor.textMuted)
                    } else {
                        Image(systemName: speechDictation.status == .listening ? "waveform" : "mic.fill")
                            .symbolEffect(.variableColor.iterative, isActive: speechDictation.status == .listening)
                    }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(speechDictation.status == .listening ? Color.white : RevylBrandColor.textPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(speechDictation.status == .listening ? RevylBrandColor.brand : RevylBrandColor.surfaceFloating))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
            .padding(.bottom, 2)
            .accessibilityLabel(isDictationActive ? "Stop dictation" : "Dictate feedback")
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RevylBrandColor.surfaceRaised))
    }

    @ViewBuilder
    private var dictationStatusMessage: some View {
        switch speechDictation.status {
        case .listening:
            Text("Listening. Tap the waveform to stop.")
                .font(.footnote)
                .foregroundStyle(RevylBrandColor.brandText)
        case .microphonePermissionDenied:
            permissionDeniedMessage("Microphone access is off for ShipTok, so it can't hear your feedback. Turn it on in Settings, or type instead.")
        case .speechRecognitionPermissionDenied:
            permissionDeniedMessage("Speech recognition is off for ShipTok, so it can't turn your voice into text. Turn it on in Settings, or type instead.")
        case .speechRecognitionUnavailable:
            Text("Speech recognition isn't available right now. Type your feedback instead.")
                .font(.footnote)
                .foregroundStyle(RevylBrandColor.textMuted)
        case .failedToStart:
            Text("Dictation couldn't start. Tap the mic to try again, or type instead.")
                .font(.footnote)
                .foregroundStyle(RevylBrandColor.textMuted)
        case .stoppedByError:
            Text("Dictation stopped. Tap the mic to try again.")
                .font(.footnote)
                .foregroundStyle(RevylBrandColor.textMuted)
        case .heardNothing:
            Text("Didn't catch anything. Try again, or type instead.")
                .font(.footnote)
                .foregroundStyle(RevylBrandColor.textMuted)
        case .idle, .starting:
            EmptyView()
        }
    }

    private func permissionDeniedMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(RevylBrandColor.textBody)
            Button("Open Settings") {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    openURL(settingsURL)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(RevylBrandColor.brandText)
        }
    }

    private var isDictationActive: Bool {
        speechDictation.status == .listening || speechDictation.status == .starting
    }

    private func toggleDictation() {
        if isDictationActive {
            speechDictation.stopDictating()
            return
        }
        isFeedbackFieldFocused = false
        feedbackTextBeforeDictation = trimmedFeedbackText
        dictationStartTask = Task { await speechDictation.startDictating() }
    }

    private func finish(_ handOff: () -> Void) {
        speechDictation.cancelDictating()
        handOff()
    }
}
