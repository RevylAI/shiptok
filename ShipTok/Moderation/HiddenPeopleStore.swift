import Foundation
import Observation

// Someone the viewer hid: a post's GitHub author, by GitHub username, or a teammate who comments, by Revyl account.
struct HiddenPerson: Codable, Hashable, Identifiable, Sendable {
    enum Account: Codable, Hashable, Sendable {
        case github(lowercasedLogin: String)
        case revyl(revylUserID: String)
    }

    let account: Account
    let displayName: String

    var id: Account { account }

    init(githubUsername: String) {
        account = .github(lowercasedLogin: githubUsername.lowercased())
        displayName = "@\(githubUsername)"
    }

    init(revylPerson: ShipTokPerson) {
        account = .revyl(revylUserID: revylPerson.revylUserID)
        displayName = revylPerson.displayName
    }
}

// The people the viewer hid, kept only on this iPhone per Revyl account. Deleting the Revyl account clears them with the rest of the app's defaults (AGENTS.md, "Report And Hide").
@Observable
@MainActor
final class HiddenPeopleStore {
    private(set) var hiddenPeople: [HiddenPerson]
    private var hiddenAccounts: Set<HiddenPerson.Account>
    private let defaultsKey: String

    init(revylUserID: String) {
        let defaultsKey = "hidden-people-revyl-\(revylUserID)"
        let savedHiddenPeople = UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([HiddenPerson].self, from: $0) } ?? []
        self.defaultsKey = defaultsKey
        hiddenPeople = savedHiddenPeople
        hiddenAccounts = Set(savedHiddenPeople.map(\.account))
    }

    var hasHiddenPeople: Bool {
        !hiddenPeople.isEmpty
    }

    func isHidden(_ githubAuthor: ShipTokGitHubAuthor) -> Bool {
        guard let username = githubAuthor.username else { return false }
        return hiddenAccounts.contains(.github(lowercasedLogin: username.lowercased()))
    }

    func isHidden(_ revylPerson: ShipTokPerson) -> Bool {
        hiddenAccounts.contains(.revyl(revylUserID: revylPerson.revylUserID))
    }

    func hide(_ person: HiddenPerson) {
        guard !hiddenAccounts.contains(person.account) else { return }
        saveHiddenPeople([person] + hiddenPeople)
    }

    func unhide(_ person: HiddenPerson) {
        saveHiddenPeople(hiddenPeople.filter { $0.account != person.account })
    }

    private func saveHiddenPeople(_ updatedHiddenPeople: [HiddenPerson]) {
        hiddenPeople = updatedHiddenPeople
        hiddenAccounts = Set(updatedHiddenPeople.map(\.account))
        UserDefaults.standard.set(try? JSONEncoder().encode(updatedHiddenPeople), forKey: defaultsKey)
    }
}
