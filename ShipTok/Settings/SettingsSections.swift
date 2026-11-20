import SwiftUI

struct HiddenPeopleSection: View {
    let hiddenPeopleStore: HiddenPeopleStore
    @Environment(\.shipTokAnalytics) private var analytics

    var body: some View {
        Section {
            if hiddenPeopleStore.hiddenGitHubLogins.isEmpty {
                Text("No one. Hide a person from a card's More menu or by pressing and holding their comment.")
                    .font(.subheadline)
                    .foregroundStyle(RevylBrandColor.textMuted)
            }
            ForEach(hiddenPeopleStore.hiddenGitHubLogins, id: \.self) { hiddenGitHubLogin in
                HStack {
                    Text(verbatim: "@\(hiddenGitHubLogin)")
                        .foregroundStyle(RevylBrandColor.textPrimary)
                    Spacer()
                    Button("Unhide") {
                        hiddenPeopleStore.unhide(githubLogin: hiddenGitHubLogin)
                        analytics?.capture(.personUnhidden)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Hidden people")
        } footer: {
            Text("Their pull requests, weekly videos, comments, vibes and media don't show in ShipTok on this iPhone. They aren't told, and nothing changes on GitHub.")
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
