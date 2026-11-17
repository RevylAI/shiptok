import CryptoKit
import Foundation

struct ProofKeyForCodeExchange: Sendable {
    let codeVerifier: String
    let codeChallenge: String

    static func generate() -> ProofKeyForCodeExchange {
        let codeVerifier = randomURLSafeString(byteCount: 48)
        let challengeDigest = SHA256.hash(data: Data(codeVerifier.utf8))
        return ProofKeyForCodeExchange(codeVerifier: codeVerifier, codeChallenge: Data(challengeDigest).base64URLEncodedString())
    }
}

func randomURLSafeString(byteCount: Int) -> String {
    var randomNumberGenerator = SystemRandomNumberGenerator()
    return Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &randomNumberGenerator) }).base64URLEncodedString()
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
