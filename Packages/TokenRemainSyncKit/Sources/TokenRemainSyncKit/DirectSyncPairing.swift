import CryptoKit
import Foundation

public enum DirectSyncConstants {
    public static let protocolVersion = 1
    public static let defaultPort: UInt16 = 47_831
    public static let envelopeContext = "com.jamesli.tokenremain.direct-sync-v1"
    public static let pairingSecretBytes = 32
    public static let nonceBytes = 16
    public static let maximumDeviceNameBytes = 64
}

public struct DirectSyncPairingRequest: Codable, Sendable, Equatable {
    public let version: Int
    public let sourceInstanceID: UUID
    public let deviceName: String
    public let clientNonce: Data
    public let proof: Data

    public init(
        version: Int = DirectSyncConstants.protocolVersion,
        sourceInstanceID: UUID,
        deviceName: String,
        clientNonce: Data,
        proof: Data
    ) {
        self.version = version
        self.sourceInstanceID = sourceInstanceID
        self.deviceName = deviceName
        self.clientNonce = clientNonce
        self.proof = proof
    }
}

public struct DirectSyncPairingResponse: Codable, Sendable, Equatable {
    public let version: Int
    public let serverSourceInstanceID: UUID
    public let keyID: UUID
    public let deviceName: String
    public let serverNonce: Data
    public let proof: Data

    public init(
        version: Int = DirectSyncConstants.protocolVersion,
        serverSourceInstanceID: UUID,
        keyID: UUID,
        deviceName: String,
        serverNonce: Data,
        proof: Data
    ) {
        self.version = version
        self.serverSourceInstanceID = serverSourceInstanceID
        self.keyID = keyID
        self.deviceName = deviceName
        self.serverNonce = serverNonce
        self.proof = proof
    }
}

public enum DirectSyncPairingError: Error, Sendable, Equatable {
    case invalidSecret
    case unsupportedVersion
    case invalidDeviceName
    case invalidNonce
    case invalidProof
}

public enum DirectSyncPairing {
    public static func randomSecret() -> Data {
        randomData(count: DirectSyncConstants.pairingSecretBytes)
    }

    public static func displayCode(for secret: Data) throws -> String {
        guard secret.count == DirectSyncConstants.pairingSecretBytes else {
            throw DirectSyncPairingError.invalidSecret
        }
        return base64URL(secret)
    }

    public static func secret(fromDisplayCode code: String) throws -> Data {
        guard let data = decodeBase64URL(code.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == DirectSyncConstants.pairingSecretBytes else {
            throw DirectSyncPairingError.invalidSecret
        }
        return data
    }

    public static func accept(
        request: DirectSyncPairingRequest,
        secret: Data,
        serverSourceInstanceID: UUID,
        serverDeviceName: String,
        keyID: UUID = UUID(),
        serverNonce requestedServerNonce: Data? = nil
    ) throws -> (response: DirectSyncPairingResponse, key: SyncEncryptionKey) {
        let serverNonce = requestedServerNonce ?? randomData(count: DirectSyncConstants.nonceBytes)
        guard secret.count == DirectSyncConstants.pairingSecretBytes else {
            throw DirectSyncPairingError.invalidSecret
        }
        guard request.version == DirectSyncConstants.protocolVersion else {
            throw DirectSyncPairingError.unsupportedVersion
        }
        let clientName = try normalizedDeviceName(request.deviceName)
        guard clientName == request.deviceName else {
            throw DirectSyncPairingError.invalidDeviceName
        }
        guard request.clientNonce.count == DirectSyncConstants.nonceBytes,
              serverNonce.count == DirectSyncConstants.nonceBytes else {
            throw DirectSyncPairingError.invalidNonce
        }
        let requestMessage = requestCanonical(
            sourceInstanceID: request.sourceInstanceID,
            deviceName: request.deviceName,
            clientNonce: request.clientNonce
        )
        guard validHMAC(request.proof, message: requestMessage, secret: secret) else {
            throw DirectSyncPairingError.invalidProof
        }

        let normalizedServerName = try normalizedDeviceName(serverDeviceName)
        let responseMessage = responseCanonical(
            clientSourceInstanceID: request.sourceInstanceID,
            serverSourceInstanceID: serverSourceInstanceID,
            keyID: keyID,
            serverDeviceName: normalizedServerName,
            clientNonce: request.clientNonce,
            serverNonce: serverNonce
        )
        let response = DirectSyncPairingResponse(
            serverSourceInstanceID: serverSourceInstanceID,
            keyID: keyID,
            deviceName: normalizedServerName,
            serverNonce: serverNonce,
            proof: hmac(message: responseMessage, secret: secret)
        )
        return (
            response,
            try derivedKey(secret: secret, clientNonce: request.clientNonce, serverNonce: serverNonce)
        )
    }

    public static func derivedKey(
        secret: Data,
        clientNonce: Data,
        serverNonce: Data
    ) throws -> SyncEncryptionKey {
        guard secret.count == DirectSyncConstants.pairingSecretBytes else {
            throw DirectSyncPairingError.invalidSecret
        }
        guard clientNonce.count == DirectSyncConstants.nonceBytes,
              serverNonce.count == DirectSyncConstants.nonceBytes else {
            throw DirectSyncPairingError.invalidNonce
        }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: clientNonce + serverNonce,
            info: Data("TokenRemain Direct Sync v1".utf8),
            outputByteCount: SyncEncryptionKey.byteCount
        )
        let bytes = key.withUnsafeBytes { Data($0) }
        return try SyncEncryptionKey(rawValue: bytes)
    }

    private static func requestCanonical(
        sourceInstanceID: UUID,
        deviceName: String,
        clientNonce: Data
    ) -> Data {
        Data(
            "TR-DIRECT-PAIR-REQUEST-1\n\(sourceInstanceID.uuidString.lowercased())\n\(deviceName)\n\(base64URL(clientNonce))".utf8
        )
    }

    private static func responseCanonical(
        clientSourceInstanceID: UUID,
        serverSourceInstanceID: UUID,
        keyID: UUID,
        serverDeviceName: String,
        clientNonce: Data,
        serverNonce: Data
    ) -> Data {
        Data(
            "TR-DIRECT-PAIR-RESPONSE-1\n\(clientSourceInstanceID.uuidString.lowercased())\n\(serverSourceInstanceID.uuidString.lowercased())\n\(keyID.uuidString.lowercased())\n\(serverDeviceName)\n\(base64URL(clientNonce))\n\(base64URL(serverNonce))".utf8
        )
    }

    private static func hmac(message: Data, secret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }

    private static func validHMAC(_ proof: Data, message: Data, secret: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: message,
            using: SymmetricKey(data: secret)
        )
    }

    private static func normalizedDeviceName(_ value: String) throws -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard !normalized.isEmpty,
              normalized.utf8.count <= DirectSyncConstants.maximumDeviceNameBytes else {
            throw DirectSyncPairingError.invalidDeviceName
        }
        return normalized
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
