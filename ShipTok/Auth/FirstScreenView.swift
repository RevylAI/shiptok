import AuthenticationServices
import SwiftUI

// Nothing in ShipTok works without a Revyl sign-in, so the first screen offers exactly two ways on, and neither creates a Revyl account (AGENTS.md, "Revyl Sign-In").
struct FirstScreenView: View {
    let signInSession: ShipTokSignInSession
    let firstScreenVisit: FirstScreenVisit
    @State private var showsJoinOrganization: Bool
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    init(signInSession: ShipTokSignInSession, firstScreenVisit: FirstScreenVisit) {
        self.signInSession = signInSession
        self.firstScreenVisit = firstScreenVisit
        _showsJoinOrganization = State(initialValue: firstScreenVisit.opensJoinOrganization)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 16) {
                    Image("RevylMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    VStack(spacing: 10) {
                        Text(verbatim: "ShipTok")
                            .font(.largeTitle.weight(.heavy))
                            .foregroundStyle(RevylBrandColor.textPrimary)
                        Text("Every open and merged pull request with a video or screenshot, one swipe at a time. Swipe right for good vibes, left for bad, and like, react and comment, all on GitHub.")
                            .font(.body)
                            .foregroundStyle(RevylBrandColor.textMuted)
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer()
                VStack(spacing: 12) {
                    if let message = firstScreenVisit.message {
                        firstScreenNote(message)
                    }
                    Button {
                        Task { await signInSession.signInToRevyl(using: webAuthenticationSession) }
                    } label: {
                        HStack(spacing: 10) {
                            if signInSession.isSigningInToRevyl {
                                ProgressView().tint(.white)
                            } else {
                                Image("RevylMark")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 22, height: 22)
                                    .accessibilityHidden(true)
                            }
                            Text("Sign in to Revyl")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.revylPrimary)
                    .disabled(signInSession.isSigningInToRevyl)
                    Button {
                        firstScreenVisit.analytics.capture(.joinOrganizationShown(reason: .chosenOnFirstScreen))
                        showsJoinOrganization = true
                    } label: {
                        Text("Join existing organization")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.revylSecondary)
                    .disabled(signInSession.isSigningInToRevyl)
                    Text("ShipTok is for teams that use Revyl. Sign in with your Revyl account, then connect GitHub to see your team's repositories. New to your team's Revyl? Join it through an invite from its owner or an admin.")
                        .font(.caption)
                        .foregroundStyle(RevylBrandColor.textSubtle)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 440)
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RevylBrandColor.canvas.ignoresSafeArea())
            .animation(.default, value: firstScreenVisit.message)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showsJoinOrganization) {
                JoinOrganizationView(analytics: firstScreenVisit.analytics)
            }
        }
    }

    // The same message says the data is deleted, why a sign-in ended, or that ShipTok now signs in with Revyl, so it reads as a note rather than a warning.
    private func firstScreenNote(_ message: String) -> some View {
        Label {
            Text(message)
                .foregroundStyle(RevylBrandColor.textBody)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(RevylBrandColor.textMuted)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RevylBrandColor.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RevylBrandColor.border, lineWidth: 1))
        .transition(.opacity)
    }
}
