import Foundation
import OSLog
import Security

struct StoredGitHubSignIn: Codable, Sendable {
    var tokens: GitHubUserAccessTokens
    var user: GitHubUserIdentity
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

// The sign-in's two parts, each its own Keychain item: the Revyl key from signing in to Revyl, and the GitHub sign-in that reads and writes GitHub as the person. A GitHub sign-in outlives a Revyl sign-in that ends, so the next Revyl sign-in connects it again without another trip through GitHub (AGENTS.md, "Revyl Sign-In").
enum ShipTokSignInKeychainStore {
    enum RotatedTokensSaveOutcome {
        case saved
        case signInEnded
    }

    private static let keychainService = "ai.revyl.shiptok"
    // Device tests and development point Debug builds at other backends through SHIPTOK_REVYL_BACKEND_URL, and each backend has its own GitHub App and Revyl keys, so a Debug build keeps its sign-in per backend origin and never hands one backend's sign-in to another. Release builds talk only to https://backend.revyl.ai and keep plain names, the GitHub sign-in's being exactly the one the GitHub-only release stored it under, so updating from that release keeps the sign-in (AGENTS.md, "iOS App").
    #if DEBUG
    private static let backendOrigin: String = {
        guard let backendURL = RevylBackendConfiguration.backendURL, let scheme = backendURL.scheme, let host = backendURL.host() else { return "none" }
        return "\(scheme.lowercased())://\(host.lowercased())" + (backendURL.port.map { ":\($0)" } ?? "")
    }()
    private static let githubSignInKeychainAccount = "github-sign-in-test@\(backendOrigin)"
    private static let revylSignInKeychainAccount = "revyl-sign-in-test@\(backendOrigin)"
    #else
    private static let githubSignInKeychainAccount = "github-sign-in"
    private static let revylSignInKeychainAccount = "revyl-sign-in"
    #endif
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in-keychain")
    // A refresh saves from the token vault while sign-in and sign-out save from the main actor, so each check and write of the stored sign-in finishes before another starts.
    private static let storedSignInWriteLock = NSRecursiveLock()

    static func loadStoredGitHubSignIn() throws -> StoredGitHubSignIn? {
        guard let storedData = try readData(account: githubSignInKeychainAccount) else { return nil }
        do {
            return try JSONDecoder().decode(StoredGitHubSignIn.self, from: storedData)
        } catch {
            logger.error("Discarding an unreadable stored GitHub sign-in")
            try deleteStoredGitHubSignIn()
            return nil
        }
    }

    static func saveStoredGitHubSignIn(_ storedGitHubSignIn: StoredGitHubSignIn) throws {
        try storedSignInWriteLock.withLock {
            try writeData(JSONEncoder().encode(storedGitHubSignIn), account: githubSignInKeychainAccount)
        }
    }

    // A refresh can finish after its sign-in ended, so its tokens replace only the sign-in whose refresh token it spent, never a later sign-in, another account's included.
    static func saveRotatedGitHubTokens(_ rotatedTokens: GitHubUserAccessTokens, rotatedFromRefreshToken spentRefreshToken: String) throws -> RotatedTokensSaveOutcome {
        try storedSignInWriteLock.withLock {
            guard var storedGitHubSignIn = try loadStoredGitHubSignIn(), storedGitHubSignIn.tokens.refreshToken == spentRefreshToken else {
                logger.info("Dropped refreshed tokens whose sign-in has ended")
                return .signInEnded
            }
            storedGitHubSignIn.tokens = rotatedTokens
            try saveStoredGitHubSignIn(storedGitHubSignIn)
            return .saved
        }
    }

    static func deleteStoredGitHubSignIn() throws {
        try storedSignInWriteLock.withLock {
            try deleteData(account: githubSignInKeychainAccount)
        }
    }

    static func loadRevylAPIKey() throws -> String? {
        guard let storedData = try readData(account: revylSignInKeychainAccount) else { return nil }
        guard let revylAPIKey = String(data: storedData, encoding: .utf8), !revylAPIKey.isEmpty else {
            logger.error("Discarding an unreadable stored Revyl key")
            try deleteRevylAPIKey()
            return nil
        }
        return revylAPIKey
    }

    static func saveRevylAPIKey(_ revylAPIKey: String) throws {
        try storedSignInWriteLock.withLock {
            try writeData(Data(revylAPIKey.utf8), account: revylSignInKeychainAccount)
        }
    }

    static func deleteRevylAPIKey() throws {
        try storedSignInWriteLock.withLock {
            try deleteData(account: revylSignInKeychainAccount)
        }
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

    // One update replaces the whole item, so a sign-in's tokens never land half written.
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
