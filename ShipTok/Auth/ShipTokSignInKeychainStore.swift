import Foundation
import OSLog
import Security

// The person's ShipTok key and who it signed in, kept together so a launch opens on the saved account at once and checks it with Revyl after (AGENTS.md, "Revyl Sign-In").
struct StoredRevylSignIn: Codable, Sendable {
    let revylAPIKey: String
    var revylAccount: RevylAccount
}

enum ShipTokSignInKeychainError: LocalizedError {
    case readFailed(OSStatus)
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .readFailed(let status): "This iPhone's Keychain couldn't read your sign-in (error \(status))."
        case .saveFailed(let status): "This iPhone's Keychain couldn't save your sign-in (error \(status))."
        case .deleteFailed(let status): "This iPhone's Keychain couldn't remove your sign-in (error \(status))."
        }
    }
}

enum ShipTokSignInKeychainStore {
    private static let keychainService = "ai.revyl.shiptok"
    // Development points Debug builds at other backends through SHIPTOK_REVYL_BACKEND_URL, and each backend has its own Revyl keys, so a Debug build keeps its sign-in per backend origin and never hands one backend's key to another. Release builds, which ship on Revyl's production backend, keep plain names (AGENTS.md, "iOS App").
    #if DEBUG
    private static let backendOrigin: String = {
        guard let backendURL = RevylBackendConfiguration.backendURL, let scheme = backendURL.scheme, let host = backendURL.host() else { return "none" }
        return "\(scheme.lowercased())://\(host.lowercased())" + (backendURL.port.map { ":\($0)" } ?? "")
    }()
    private static let revylSignInKeychainAccount = "revyl-sign-in-test@\(backendOrigin)"
    private static let retiredGitHubSignInKeychainAccount = "github-sign-in-test@\(backendOrigin)"
    #else
    private static let revylSignInKeychainAccount = "revyl-sign-in"
    private static let retiredGitHubSignInKeychainAccount = "github-sign-in"
    #endif
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in-keychain")

    static func loadStoredRevylSignIn() throws -> StoredRevylSignIn? {
        guard let storedData = try readData(account: revylSignInKeychainAccount) else { return nil }
        do {
            return try JSONDecoder().decode(StoredRevylSignIn.self, from: storedData)
        } catch {
            logger.error("Discarding an unreadable stored Revyl sign-in")
            try deleteStoredRevylSignIn()
            return nil
        }
    }

    static func saveStoredRevylSignIn(_ storedRevylSignIn: StoredRevylSignIn) throws {
        try writeData(JSONEncoder().encode(storedRevylSignIn), account: revylSignInKeychainAccount)
    }

    static func deleteStoredRevylSignIn() throws {
        try deleteData(account: revylSignInKeychainAccount)
    }

    // Builds before the Revyl sign-in kept a GitHub sign-in that no longer does anything, so it's deleted; true when there was one, so the first screen can say why the person signs in again (AGENTS.md, "Revyl Sign-In").
    static func deleteRetiredGitHubSignIn() throws -> Bool {
        guard try readData(account: retiredGitHubSignInKeychainAccount) != nil else { return false }
        try deleteData(account: retiredGitHubSignInKeychainAccount)
        return true
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            logger.error("Reading the keychain failed with status \(status)")
            throw ShipTokSignInKeychainError.readFailed(status)
        }
        return item as? Data
    }

    // One update replaces the whole item, so a sign-in never lands half written.
    private static func writeData(_ data: Data, account: String) throws {
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery(account: account)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                logger.error("Saving to the keychain failed with status \(addStatus)")
                throw ShipTokSignInKeychainError.saveFailed(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            logger.error("Updating the keychain failed with status \(updateStatus)")
            throw ShipTokSignInKeychainError.saveFailed(updateStatus)
        }
    }

    private static func deleteData(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Deleting from the keychain failed with status \(status)")
            throw ShipTokSignInKeychainError.deleteFailed(status)
        }
    }
}
