import Foundation
import Observation

// The people the viewer hid, by GitHub login: kept only on this iPhone per signed-in person, and only in memory for a demo visit. Deleting ShipTok data clears them with the rest of the app's defaults (shiptok/AGENTS.md, "Report And Hide").
@Observable
@MainActor
final class HiddenPeopleStore {
    private(set) var hiddenGitHubLogins: [String]
    private var lowercasedHiddenGitHubLogins: Set<String>
    private let hiddenGitHubLoginsDefaultsKey: String?

    convenience init(githubUserID: Int64) {
        self.init(hiddenGitHubLoginsDefaultsKey: "hidden-people-github-logins-github-\(githubUserID)")
    }

    static func forDemoVisit() -> HiddenPeopleStore {
        HiddenPeopleStore(hiddenGitHubLoginsDefaultsKey: nil)
    }

    private init(hiddenGitHubLoginsDefaultsKey: String?) {
        let savedHiddenGitHubLogins = hiddenGitHubLoginsDefaultsKey.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? []
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
        if let hiddenGitHubLoginsDefaultsKey {
            UserDefaults.standard.set(updatedHiddenGitHubLogins, forKey: hiddenGitHubLoginsDefaultsKey)
        }
    }
}
