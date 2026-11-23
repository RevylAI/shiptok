import SwiftUI

// One switch for the whole organization: whether Revyl's GitHub App keeps a comment on GitHub that sums up each post's feedback (AGENTS.md, "Settings").
struct OrganizationSettingsSection: View {
    let store: OrganizationSettingsStore
    let organizationName: String

    var body: some View {
        Section {
            if let organizationSettings = store.organizationSettings {
                Toggle("Feedback summary on GitHub", isOn: Binding(
                    get: { organizationSettings.postsFeedbackSummaryCommentsOnGitHub },
                    set: { postsFeedbackSummaryCommentsOnGitHub in
                        Task { await store.setPostsFeedbackSummaryCommentsOnGitHub(postsFeedbackSummaryCommentsOnGitHub) }
                    }
                ))
                .disabled(!organizationSettings.viewerCanChange || store.isSaving)
            } else if let refreshFailureMessage = store.refreshFailureMessage {
                Label("Couldn't load your organization's settings: \(refreshFailureMessage)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(RevylBrandColor.warning)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text(verbatim: organizationName)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Revyl's GitHub App keeps one comment on each pull request and issue with feedback, summing up its likes, reactions, vibes and comments. Turning it off deletes those comments; turning it on posts them again.")
                if store.organizationSettings?.viewerCanChange == false {
                    Text("Only your organization's owners and admins can change it.")
                }
            }
        }
    }
}

struct HiddenPeopleSection: View {
    let hiddenPeopleStore: HiddenPeopleStore
    @Environment(\.shipTokAnalytics) private var analytics

    var body: some View {
        Section {
            if hiddenPeopleStore.hiddenPeople.isEmpty {
                Text("No one. Hide a person from a card's More menu or by pressing and holding their comment or vibe.")
                    .font(.subheadline)
                    .foregroundStyle(RevylBrandColor.textMuted)
            }
            ForEach(hiddenPeopleStore.hiddenPeople) { hiddenPerson in
                HStack {
                    Text(verbatim: hiddenPerson.displayName)
                        .foregroundStyle(RevylBrandColor.textPrimary)
                    Spacer()
                    Button("Unhide") {
                        hiddenPeopleStore.unhide(hiddenPerson)
                        analytics?.capture(.personUnhidden)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Hidden people")
        } footer: {
            Text("A hidden GitHub account's pull requests, weekly and feature videos, and a hidden teammate's comments, replies, vibes and inbox items don't show in ShipTok on this iPhone. Push notifications for what they do still arrive. They aren't told.")
        }
    }
}

struct GesturesSection: View {
    var body: some View {
        Section("Gestures") {
            ForEach(FeedSwipeDirection.allCases, id: \.self) { direction in
                Label(FeedSwipeGestureMapping.action(for: direction).legendLabel, systemImage: direction.arrowSystemImageName)
            }
            Label("Like", systemImage: "hand.tap")
                .badge("Double-tap")
            Label("2x speed", systemImage: "forward")
                .badge("Press and hold")
            Label("Scrub a video", systemImage: "arrow.left.and.right")
                .badge("Drag the progress line")
        }
    }
}

struct PrivacyAndSupportSection: View {
    var body: some View {
        Section("Privacy and support") {
            Link(destination: URL(string: "https://revyl.com/privacy/#shiptok")!) {
                Label("Privacy policy", systemImage: "hand.raised")
            }
            Link(destination: URL(string: "mailto:support@revyl.ai")!) {
                Label("Contact support", systemImage: "envelope")
            }
        }
    }
}
