import Foundation
import OSLog
import Security

struct StoredGitHubSignIn: Codable, Sendable {
    var tokens: GitHubUserAccessTokens
    var user: GitHubUserIdentity
}

enum GitHubSignInKeychainError: LocalizedError {
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

enum GitHubSignInKeychainStore {
    enum RotatedTokensSaveOutcome {
        case saved
        case signInEnded
    }

    private static let keychainService = "ai.revyl.shiptok"
    // Debug and Release builds sign in through different GitHub Apps, so a phone that has run both never hands one's tokens to the other.
    #if DEBUG
    private static let signInKeychainAccount = "github-sign-in-test"
    #else
    private static let signInKeychainAccount = "github-sign-in"
    #endif
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in-keychain")
    // A refresh saves from the token vault while sign-in and sign-out save from the main actor, so each check and write of the stored sign-in finishes before another starts.
    private static let storedSignInWriteLock = NSRecursiveLock()

    static func loadStoredSignIn() throws -> StoredGitHubSignIn? {
        guard let storedData = try readData(account: signInKeychainAccount) else { return nil }
        do {
            return try JSONDecoder().decode(StoredGitHubSignIn.self, from: storedData)
        } catch {
            logger.error("Discarding an unreadable stored sign-in")
            try deleteStoredSignIn()
            return nil
        }
    }

    static func saveStoredSignIn(_ storedSignIn: StoredGitHubSignIn) throws {
        try storedSignInWriteLock.withLock {
            try writeData(JSONEncoder().encode(storedSignIn), account: signInKeychainAccount)
        }
    }

    // A refresh can finish after its sign-in ended, so its tokens replace only the sign-in whose refresh token it spent, never a later sign-in, another account's included.
    static func saveRotatedTokens(_ rotatedTokens: GitHubUserAccessTokens, rotatedFromRefreshToken spentRefreshToken: String) throws -> RotatedTokensSaveOutcome {
        try storedSignInWriteLock.withLock {
            guard var storedSignIn = try loadStoredSignIn(), storedSignIn.tokens.refreshToken == spentRefreshToken else {
                logger.info("Dropped refreshed tokens whose sign-in has ended")
                return .signInEnded
            }
            storedSignIn.tokens = rotatedTokens
            try saveStoredSignIn(storedSignIn)
            return .saved
        }
    }

    static func deleteStoredSignIn() throws {
        try storedSignInWriteLock.withLock {
            try deleteData(account: signInKeychainAccount)
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
            throw GitHubSignInKeychainError.readFailed(status)
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
                throw GitHubSignInKeychainError.saveFailed(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            logger.error("Updating the keychain failed with status \(updateStatus)")
            throw GitHubSignInKeychainError.saveFailed(updateStatus)
        }
    }

    private static func deleteData(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Deleting from the keychain failed with status \(status)")
            throw GitHubSignInKeychainError.deleteFailed(status)
        }
    }
}
