import Foundation
import OSLog
import Security

struct StoredGitHubSignIn: Codable, Sendable {
    var tokens: GitHubUserAccessTokens
    var user: GitHubUserIdentity
}

enum GitHubSignInKeychainStore {
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

    static func loadStoredSignIn() -> StoredGitHubSignIn? {
        guard let storedData = readData(account: signInKeychainAccount) else { return nil }
        do {
            return try JSONDecoder().decode(StoredGitHubSignIn.self, from: storedData)
        } catch {
            logger.error("Discarding an unreadable stored sign-in")
            deleteStoredSignIn()
            return nil
        }
    }

    static func saveStoredSignIn(_ storedSignIn: StoredGitHubSignIn) {
        storedSignInWriteLock.withLock {
            do {
                writeData(try JSONEncoder().encode(storedSignIn), account: signInKeychainAccount)
            } catch {
                logger.error("Encoding the sign-in for the keychain failed")
            }
        }
    }

    // A refresh can finish after its sign-in ended, so its tokens replace only the sign-in whose refresh token it spent, never a later sign-in, another account's included.
    static func saveRotatedTokens(_ rotatedTokens: GitHubUserAccessTokens, rotatedFromRefreshToken spentRefreshToken: String) {
        storedSignInWriteLock.withLock {
            guard var storedSignIn = loadStoredSignIn(), storedSignIn.tokens.refreshToken == spentRefreshToken else {
                logger.info("Dropped refreshed tokens whose sign-in has ended")
                return
            }
            storedSignIn.tokens = rotatedTokens
            saveStoredSignIn(storedSignIn)
        }
    }

    static func deleteStoredSignIn() {
        storedSignInWriteLock.withLock {
            deleteData(account: signInKeychainAccount)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("Reading the keychain failed with status \(status)")
        }
        return status == errSecSuccess ? item as? Data : nil
    }

    // One update replaces the whole item, so a sign-in's tokens never land half written.
    private static func writeData(_ data: Data, account: String) {
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery(account: account)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Saving to the keychain failed with status \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            logger.error("Updating the keychain failed with status \(updateStatus)")
        }
    }

    private static func deleteData(account: String) {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("Deleting from the keychain failed with status \(status)")
        }
    }
}
