import SwiftUI

// Revyl never adds anyone to an organization, so joining one goes through its owners and admins: the person asks them for Revyl's invite, or has Revyl email them. Revyl's answer is the same whether or not an organization matched, and so is the confirmation (AGENTS.md, "Revyl Sign-In").
struct JoinOrganizationView: View {
    let analytics: ShipTokAnalytics
    @State private var email = ""
    @State private var isSubmitting = false
    @State private var failureMessage: String?
    @State private var submittedEmail: String?

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                Text("Ask your organization's owner or an admin to invite you to Revyl. Accept the invite from your email, then sign in here.")
                    .foregroundStyle(RevylBrandColor.textBody)
            } header: {
                Text("Ask for an invite")
            }
            Section {
                if let submittedEmail {
                    Label {
                        Text("If your organization uses Revyl, its owners and admins will get an email asking them to invite \(submittedEmail). Accept the invite from your email, then sign in.")
                            .foregroundStyle(RevylBrandColor.textBody)
                    } icon: {
                        Image(systemName: "paperplane")
                            .foregroundStyle(RevylBrandColor.textMuted)
                    }
                } else {
                    TextField("Your work email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit { Task { await submit() } }
                        .disabled(isSubmitting)
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text("Submit")
                            if isSubmitting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSubmitting || trimmedEmail.isEmpty)
                }
            } header: {
                Text("Or have Revyl ask them")
            } footer: {
                if submittedEmail == nil {
                    if let failureMessage {
                        Text(failureMessage)
                            .foregroundStyle(RevylBrandColor.warning)
                    } else {
                        Text("Revyl emails your organization's owners and admins asking them to invite this address.")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollContentCenteredInReadableContentColumn()
        .background(RevylBrandColor.surface)
        .navigationTitle("Join existing organization")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() async {
        let submittingEmail = trimmedEmail
        guard !submittingEmail.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        failureMessage = nil
        do {
            try await RevylShipTokAPI(revylAPIKey: nil).submitOrganizationJoinRequest(email: submittingEmail)
            submittedEmail = submittingEmail
        } catch {
            let failureReason: ShipTokAnalyticsEvent.OrganizationJoinRequestFailureReason = switch error {
            case RevylShipTokAPIError.organizationJoinRequestEmailInvalid: .emailInvalid
            case RevylShipTokAPIError.rateLimited: .rateLimited
            default: .unavailable
            }
            analytics.capture(.organizationJoinRequestFailed(reason: failureReason))
            failureMessage = error.localizedDescription
        }
    }
}
