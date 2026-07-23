import Foundation

actor BroadcastPushRegistrationService {
    enum RegistrationError: LocalizedError {
        case invalidResponse
        case api(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return L10n.text("feed.curated.invalid_response")
            case .api(let status, let message):
                return L10n.format("feed.curated.api_error", status, message)
            }
        }
    }

    private struct RegistrationPayload: Encodable {
        let installationId: String
        let registrationKey: String
        let deviceToken: String
        let platform: String
        let locale: String
        let timezone: String
        let notificationsEnabled: Bool
    }

    private struct UnregistrationPayload: Encodable {
        let registrationKey: String
    }

    private let defaults = UserDefaults.standard
    private let registrationKeyStore = KeychainSecretStore(
        service: "com.jamesli.usagedock.broadcast",
        account: "device-registration-key"
    )
    private let installationIDKey = "broadcastInstallationID"
    private let lastDeviceTokenKey = "broadcastLastDeviceToken"

    func register(deviceToken: Data, endpoint: URL) async throws {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let payload = RegistrationPayload(
            installationId: installationID(),
            registrationKey: try registrationKey(),
            deviceToken: token,
            platform: "macos",
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            notificationsEnabled: true
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(payload)
        try await perform(request)
        defaults.set(token, forKey: lastDeviceTokenKey)
    }

    func unregister(endpoint: URL) async throws {
        guard defaults.string(forKey: lastDeviceTokenKey) != nil else { return }
        let installationID = installationID()
        let deviceEndpoint = endpoint
            .deletingLastPathComponent()
            .appending(path: installationID)
        var request = URLRequest(url: deviceEndpoint)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(
            UnregistrationPayload(registrationKey: try registrationKey())
        )
        try await perform(request)
        defaults.removeObject(forKey: lastDeviceTokenKey)
    }

    private func installationID() -> String {
        if let value = defaults.string(forKey: installationIDKey), !value.isEmpty {
            return value
        }
        let value = "mac_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defaults.set(value, forKey: installationIDKey)
        return value
    }

    private func registrationKey() throws -> String {
        if let value = try registrationKeyStore.read(), !value.isEmpty {
            return value
        }
        let value = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
        try registrationKeyStore.save(value)
        return value
    }

    private func perform(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RegistrationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(Problem.self, from: data).detail)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw RegistrationError.api(status: http.statusCode, message: message)
        }
    }
}

private struct Problem: Decodable {
    let detail: String?
}
