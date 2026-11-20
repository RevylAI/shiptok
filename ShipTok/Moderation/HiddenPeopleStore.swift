import Foundation
import Observation

// The people the viewer hid, by GitHub login: kept only on this iPhone per signed-in person. Deleting ShipTok data clears them with the rest of the app's defaults (AGENTS.md, "Report And Hide").
@Observable
@MainActor
final class HiddenPeopleStore {
    private(set) var hiddenGitHubLogins: [String]
    private var lowercasedHiddenGitHubLogins: Set<String>
    private let hiddenGitHubLoginsDefaultsKey: String

    init(githubUserID: Int64) {
        let hiddenGitHubLoginsDefaultsKey = "hidden-people-github-logins-github-\(githubUserID)"
        let savedHiddenGitHubLogins = UserDefaults.standard.stringArray(forKey: hiddenGitHubLoginsDefaultsKey) ?? []
        self.hiddenGitHubLoginsDefaultsKey = hiddenGitHubLoginsDefaultsKey
        hiddenGitHubLogins = savedHiddenGitHubLogins
        lowercasedHiddenGitHubLogins = Set(savedHiddenGitHubLogins.map { $0.lowercased() })
    }

    var hasHiddenPeople: Bool {
        !hiddenGitHubLogins.isEmpty
    }

    func isHidden(_ person: GitHubActor?) -> Bool {
        guard let person else { return false }
        return lowercasedHiddenGitHubLogins.contains(person.login.lowercased())
    }

    func hide(_ person: GitHubActor) {
        guard !isHidden(person) else { return }
        saveHiddenGitHubLogins([person.login] + hiddenGitHubLogins)
    }

    func unhide(githubLogin: String) {
        saveHiddenGitHubLogins(hiddenGitHubLogins.filter { $0.lowercased() != githubLogin.lowercased() })
    }

    private func saveHiddenGitHubLogins(_ updatedHiddenGitHubLogins: [String]) {
        hiddenGitHubLogins = updatedHiddenGitHubLogins
        lowercasedHiddenGitHubLogins = Set(updatedHiddenGitHubLogins.map { $0.lowercased() })
        UserDefaults.standard.set(updatedHiddenGitHubLogins, forKey: hiddenGitHubLoginsDefaultsKey)
    }
}
