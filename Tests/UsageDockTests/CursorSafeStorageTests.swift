import Foundation
import Security
import Testing
@testable import UsageDock

@Suite("Cursor sealed login")
struct CursorSafeStorageTests {
    /// Synthetic vector built independently with Python `hashlib.pbkdf2_hmac`
    /// and `openssl enc -aes-128-cbc` (salt `saltysalt`, 1003 rounds, IV of
    /// spaces, `v10` marker) — the Chromium OSCrypt scheme Cursor uses.
    static let password = "fixture-safe-storage-password"
    static let keyHex = "ae1a2f63e3bb06fc8c04a1290801ac5d"
    static let token = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhdXRoMHxmaXh0dXJlIiwiZXhwIjoxNzg0MDAzNjAwfQ.fixture"
    static let sealed = "cursor-safe-storage:v1:djEwehPp7VV6EBr9ZtcTDzuzD4V/hwt+sAT0VuJkWd1zdPK8AnpR2ydbjdeqAuD5BIyIVUxF8KkzJEgpURUup0r7WBohwytGSHbLqJ9mPoe08n0QDnWEO2BFsGds8QBs6uQ2"
    /// Before the fixture token's `exp`.
    static let now = Date(timeIntervalSince1970: 1_784_000_000)

    @Test("Key derivation and decryption match an independent implementation")
    func knownAnswer() throws {
        let key = try #require(CursorSafeStorage.derivedKey(password: Self.password))
        #expect(key.map { String(format: "%02x", $0) }.joined() == Self.keyHex)
        #expect(CursorSafeStorage.decrypt(Self.sealed, key: key) == Self.token)
    }

    @Test("Sealing round-trips, and wrong keys or malformed values never yield a token")
    func rejectsBadInput() throws {
        let key = try #require(CursorSafeStorage.derivedKey(password: Self.password))
        let resealed = try #require(CursorSafeStorage.seal(Self.token, key: key))
        #expect(CursorSafeStorage.decrypt(resealed, key: key) == Self.token)

        let wrongKey = try #require(CursorSafeStorage.derivedKey(password: "another-password"))
        #expect(CursorSafeStorage.decrypt(Self.sealed, key: wrongKey) == nil)
        #expect(CursorSafeStorage.decrypt(Self.token, key: key) == nil)
        #expect(CursorSafeStorage.decrypt("cursor-safe-storage:v1:not base64!", key: key) == nil)
        let noMarker = CursorSafeStorage.prefix + Data(repeating: 1, count: 32).base64EncodedString()
        #expect(CursorSafeStorage.decrypt(noMarker, key: key) == nil)
        // A sealed value whose plaintext is not a JWT is not a token either.
        let notJWT = try #require(CursorSafeStorage.seal("plain-text-secret", key: key))
        #expect(CursorSafeStorage.decrypt(notJWT, key: key) == nil)
        #expect(CursorSafeStorage.derivedKey(password: "") == nil)
    }

    private static func stateDB(accessToken: String) async throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-cursor-sealed-\(UUID().uuidString).vscdb").path
        _ = try await ProcessRunner.run("/usr/bin/sqlite3", arguments: [
            path,
            """
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);
            INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(accessToken)');
            INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType', 'pro');
            """
        ])
        return path
    }

    private static func reader(
        path: String,
        cache: CursorSafeStorage.KeyCache,
        key: @escaping @Sendable (KeychainRead.Interaction) -> KeychainRead.Outcome
    ) -> CursorAuthReader {
        var reader = CursorAuthReader()
        reader.stateDBURL = URL(fileURLWithPath: path)
        reader.keyCache = cache
        reader.safeStorageKey = key
        reader.keychainPayload = { nil }
        return reader
    }

    @Test("An approved Safe Storage key unseals the IDE token")
    func unsealsWithApprovedKey() async throws {
        let path = try await Self.stateDB(accessToken: Self.sealed)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let interactions = InteractionLog()
        let reader = Self.reader(path: path, cache: CursorSafeStorage.KeyCache()) { interaction in
            interactions.record(interaction)
            return KeychainRead.Outcome(payload: Self.password, status: errSecSuccess)
        }

        guard case .token(let auth) = await reader.resolve(now: Self.now, interaction: .allowed) else {
            Issue.record("expected the unsealed token")
            return
        }
        #expect(auth.accessToken == Self.token)
        #expect(auth.membershipType == "pro")
        #expect(interactions.values == [.allowed])
    }

    @Test("Without approval the sealed value is reported, never sent as a token")
    func needsApproval() async throws {
        let path = try await Self.stateDB(accessToken: Self.sealed)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var reader = Self.reader(path: path, cache: CursorSafeStorage.KeyCache()) { _ in
            KeychainRead.Outcome(payload: nil, status: errSecInteractionNotAllowed)
        }
        // A fresh CLI token cannot be matched to the sealed account, so it is not used.
        reader.keychainPayload = { "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhdXRoMHxvdGhlciJ9.cli" }

        guard case .sealed(.authorizationRequired) = await reader.resolve(now: Self.now, interaction: .disallowed) else {
            Issue.record("expected authorizationRequired")
            return
        }
        #expect(await reader.load(now: Self.now) == nil)
    }

    @Test("A missing or wrong Safe Storage key reports an unreadable login")
    func unreadable() async throws {
        let path = try await Self.stateDB(accessToken: Self.sealed)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let missing = Self.reader(path: path, cache: CursorSafeStorage.KeyCache()) { _ in
            KeychainRead.Outcome(payload: nil, status: errSecItemNotFound)
        }
        guard case .sealed(.unreadable) = await missing.resolve(now: Self.now, interaction: .disallowed) else {
            Issue.record("expected unreadable for a missing key")
            return
        }
        let wrong = Self.reader(path: path, cache: CursorSafeStorage.KeyCache()) { _ in
            KeychainRead.Outcome(payload: "another-password", status: errSecSuccess)
        }
        guard case .sealed(.unreadable) = await wrong.resolve(now: Self.now, interaction: .disallowed) else {
            Issue.record("expected unreadable for a wrong key")
            return
        }
    }

    @Test("One approved read keeps background refreshes working for the session")
    func keyCacheServesBackgroundReads() async throws {
        let path = try await Self.stateDB(accessToken: Self.sealed)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cache = CursorSafeStorage.KeyCache()
        let approved = Self.reader(path: path, cache: cache) { _ in
            KeychainRead.Outcome(payload: Self.password, status: errSecSuccess)
        }
        _ = await approved.resolve(now: Self.now, interaction: .allowed)

        let interactions = InteractionLog()
        let background = Self.reader(path: path, cache: cache) { interaction in
            interactions.record(interaction)
            return KeychainRead.Outcome(payload: nil, status: errSecInteractionNotAllowed)
        }
        #expect(await background.load(now: Self.now)?.accessToken == Self.token)
        #expect(interactions.values.isEmpty)

        // A key that no longer decrypts is dropped and re-read silently.
        cache.store(try #require(CursorSafeStorage.derivedKey(password: "rotated")))
        guard case .sealed(.authorizationRequired) = await background.resolve(now: Self.now, interaction: .disallowed) else {
            Issue.record("expected a fresh silent read after the stale key")
            return
        }
        #expect(interactions.values == [.disallowed])
        #expect(cache.key == nil)
    }

    @Test("Only the approval-needed error asks for the inline authorization")
    func errorClassification() {
        #expect(UsageStore.requiresKeychainAuthorization(CursorUsageService.ServiceError.encryptedLoginNeedsAuthorization))
        #expect(!UsageStore.requiresKeychainAuthorization(CursorUsageService.ServiceError.encryptedLoginUnreadable))
        #expect(!UsageStore.requiresKeychainAuthorization(CursorUsageService.ServiceError.staleLogin))
        #expect(CursorUsageService.ServiceError.encryptedLoginNeedsAuthorization.errorDescription?.isEmpty == false)
        #expect(CursorUsageService.ServiceError.encryptedLoginUnreadable.errorDescription?.isEmpty == false)
    }
}

private final class InteractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [KeychainRead.Interaction] = []

    var values: [KeychainRead.Interaction] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ interaction: KeychainRead.Interaction) {
        lock.lock()
        stored.append(interaction)
        lock.unlock()
    }
}
