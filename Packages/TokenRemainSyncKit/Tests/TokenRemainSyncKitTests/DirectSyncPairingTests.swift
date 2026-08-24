import Foundation
import Testing
@testable import TokenRemainSyncKit

@Suite("Direct sync pairing")
struct DirectSyncPairingTests {
    private let clientID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private let serverID = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
    private let keyID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let secret = Data((0..<32).map(UInt8.init))
    private let clientNonce = Data(repeating: 0x11, count: 16)
    private let serverNonce = Data(repeating: 0x22, count: 16)

    @Test("Swift accepts the canonical Windows proof and derives the same key")
    func windowsVector() throws {
        let request = DirectSyncPairingRequest(
            sourceInstanceID: clientID,
            deviceName: "Windows PC",
            clientNonce: clientNonce,
            proof: try #require(Data(base64Encoded: "rZe/S2joQ3V2Gjxk3I3pCS8BcWv8bY8epfpMmrN2EPk="))
        )
        let accepted = try DirectSyncPairing.accept(
            request: request,
            secret: secret,
            serverSourceInstanceID: serverID,
            serverDeviceName: "Mac Studio",
            keyID: keyID,
            serverNonce: serverNonce
        )

        #expect(accepted.key.rawValue.hex == "664784ab1a8c55e8756e19abbb2b9f18dd7a4a1b6556a3bef1a8ce8805dd9cac")
        #expect(accepted.response.proof.base64EncodedString() == "3dbHr8VENveVkIpRg1DbGGjeuQNl0SLA+JhjP/UYF+k=")
        #expect(accepted.response.keyID == keyID)
    }

    @Test("A modified device name invalidates the proof")
    func modifiedRequestRejected() throws {
        let request = DirectSyncPairingRequest(
            sourceInstanceID: clientID,
            deviceName: "Other PC",
            clientNonce: clientNonce,
            proof: try #require(Data(base64Encoded: "rZe/S2joQ3V2Gjxk3I3pCS8BcWv8bY8epfpMmrN2EPk="))
        )
        #expect(throws: DirectSyncPairingError.invalidProof) {
            try DirectSyncPairing.accept(
                request: request,
                secret: secret,
                serverSourceInstanceID: serverID,
                serverDeviceName: "Mac",
                keyID: keyID,
                serverNonce: serverNonce
            )
        }
    }

    @Test("Display code is URL-safe and round-trips")
    func displayCodeRoundTrip() throws {
        let code = try DirectSyncPairing.displayCode(for: secret)
        #expect(!code.contains("="))
        #expect(try DirectSyncPairing.secret(fromDisplayCode: code) == secret)
    }

    @Test("Swift opens the deterministic Windows AES-GCM envelope")
    func windowsEnvelopeVector() throws {
        let encoded = Data(#"{"envelopeVersion":1,"generatedAt":1785664800000,"keyID":"11111111-2222-4333-8444-555555555555","sealedPayload":"paWlpaWlpaWlpaWlWmX52EL1Wuxb7dfAkhJAHbgtgmbRYXFxdmerW0Minf6E3iDcrkfcquz+DGYZdQxTnWJZV+19A0LhoCSKkd/dV918AaeOhj6BvyU5dUDiyZLd0Bbejjt5x3lkPW3uWe9h92QxZok+EnQbBgzXcVb0QGed9byHmraDOqT4yDr1gGV/yWA5y1lqEazJHffqiqILhi8cnO2SnoI1PimhmRbQlkdfjnG8gSqPi90preHhnBc8/mI5OSKiB7JJ/23KcUbm0O5eIXxbDsMkTmPZW2B0Aqyp2t6FVl6RqeuCO7VFKlGo5ueaqPCfnW8l3CDjzJ9lztkhO784SHxnGfwjcEeltLRaJBxkdDjJ6JhbQsD1UJlPCO+ABf9WNuRoLf/Pg9YmK0tukd62tX70M/klCRfSFVgB/OGjhuva3w4GYi9+3mHtclk9pn8TfpuRLjMOiFezAOegtdySL6Ez","sequence":7,"sourceInstanceID":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}"#.utf8)
        let envelope = try EncryptedSyncEnvelope.decoded(from: encoded)
        let key = try SyncEncryptionKey(rawValue: try #require(Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")))
        let now = Date(timeIntervalSince1970: 1_785_664_800)
        let snapshot = try envelope.open(
            using: key,
            containerID: DirectSyncConstants.envelopeContext,
            configuration: .current(now: now)
        )

        #expect(snapshot.sourceInstanceID == clientID)
        #expect(snapshot.sequence == 7)
        #expect(snapshot.providers.first?.providerID == SyncedProviderID.codex)
        #expect(snapshot.providers.first?.windows.first?.usedPercent == 37)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
