import CommonCrypto
import Foundation

/// Cursor 3.27+ seals its `cursorAuth/*` tokens at rest (setting
/// `cursor.storage.authTokenEncryptionAtRest`, on by default) as
/// `cursor-safe-storage:v1:` + base64 of Electron safeStorage output. On macOS
/// that output is Chromium OSCrypt: the `v10` marker, then AES-128-CBC with a
/// key derived by PBKDF2-HMAC-SHA1 from the Keychain item "Cursor Safe
/// Storage" (salt `saltysalt`, 1003 rounds, 16 bytes), IV of 16 spaces and
/// PKCS#7 padding.
///
/// That Keychain password unlocks every value Cursor seals, so TokenRemain
/// reads it only through `KeychainRead` (silent in background refresh, one
/// macOS prompt after an explicit user action), decrypts nothing but the
/// access token, never writes it back, and keeps only the derived key in
/// memory for the life of the process.
enum CursorSafeStorage {
    static let prefix = "cursor-safe-storage:v1:"
    static let keychainService = "Cursor Safe Storage"

    private static let marker = Data("v10".utf8)
    private static let salt = Data("saltysalt".utf8)
    private static let rounds: UInt32 = 1003
    private static let keyLength = kCCKeySizeAES128
    private static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    static func isSealed(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    static func derivedKey(password: String) -> Data? {
        let passwordBytes = Array(password.utf8)
        guard !passwordBytes.isEmpty else { return nil }
        var key = Data(count: keyLength)
        let status = key.withUnsafeMutableBytes { keyBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.map { CChar(bitPattern: $0) },
                    passwordBytes.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    rounds,
                    keyBuffer.bindMemory(to: UInt8.self).baseAddress,
                    keyLength
                )
            }
        }
        return status == kCCSuccess ? key : nil
    }

    /// The sealed access token in clear, or nil when the value is not sealed,
    /// the key is wrong, or the plaintext is not a JWT. A wrong key almost
    /// always fails the padding check; the JWT test catches the rest.
    static func decrypt(_ value: String, key: Data) -> String? {
        guard isSealed(value),
              let blob = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              blob.count > marker.count,
              blob.prefix(marker.count) == marker else {
            return nil
        }
        let ciphertext = blob.dropFirst(marker.count)
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0,
              let plaintext = crypt(CCOperation(kCCDecrypt), Data(ciphertext), key: key),
              let token = CursorAuthReader.normalized(String(data: plaintext, encoding: .utf8)),
              JWT.payload(token) != nil else {
            return nil
        }
        return token
    }

    /// Test seam for building sealed fixtures with the same scheme.
    static func seal(_ token: String, key: Data) -> String? {
        guard let ciphertext = crypt(CCOperation(kCCEncrypt), Data(token.utf8), key: key) else { return nil }
        return prefix + (marker + ciphertext).base64EncodedString()
    }

    private static func crypt(_ operation: CCOperation, _ input: Data, key: Data) -> Data? {
        guard key.count == keyLength else { return nil }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress,
                            keyLength,
                            ivBuffer.baseAddress,
                            inputBuffer.baseAddress,
                            input.count,
                            outputBuffer.baseAddress,
                            outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(moved)
    }

    /// Derived key kept for the process lifetime, so one approved read keeps
    /// background refreshes working even when the user chose "Allow" rather
    /// than "Always Allow". Never persisted.
    final class KeyCache: @unchecked Sendable {
        static let shared = KeyCache()

        private let lock = NSLock()
        private var stored: Data?

        var key: Data? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func store(_ key: Data?) {
            lock.lock()
            stored = key
            lock.unlock()
        }
    }
}
