import Foundation

struct CCUsageUpdateCheck: Equatable, Sendable {
    let installedVersion: String
    let latestVersion: String
    let checkedAt: Date

    var updateAvailable: Bool {
        CCUsageUpdateChecker.isNewer(latestVersion, than: installedVersion)
    }
}

enum CCUsageUpdateStatus: Equatable, Sendable {
    case checking(installedVersion: String)
    case current(installedVersion: String, checkedAt: Date)
    case updateAvailable(installedVersion: String, latestVersion: String, checkedAt: Date)
    case checkFailed(installedVersion: String)

    var installedVersion: String {
        switch self {
        case .checking(let installedVersion),
             .current(let installedVersion, _),
             .updateAvailable(let installedVersion, _, _),
             .checkFailed(let installedVersion):
            installedVersion
        }
    }

    var needsUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }
}

/// Checks only package metadata. Local usage logs remain inside the bundled
/// helper process and are never sent to npm or another pricing service.
struct CCUsageUpdateChecker {
    enum CheckError: LocalizedError {
        case invalidResponse
        case unexpectedPackage(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "ccusage 更新服务返回了无法识别的数据。"
            case .unexpectedPackage(let name):
                "ccusage 更新服务返回了意外的软件包：\(name)"
            }
        }
    }

    static let packageName = "@ccusage/ccusage-darwin-arm64"
    static let registryURL = URL(
        string: "https://registry.npmjs.org/%40ccusage%2Fccusage-darwin-arm64/latest"
    )!
    static let bundleVersionKey = "TokenRemainBundledCCUsageVersion"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func check(installedVersion: String, now: Date = .now) async throws -> CCUsageUpdateCheck {
        var request = URLRequest(
            url: Self.registryURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenRemain ccusage-version-check", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw CheckError.invalidResponse
        }
        let metadata = try Self.parseMetadata(data)
        guard metadata.name == Self.packageName else {
            throw CheckError.unexpectedPackage(metadata.name)
        }
        return CCUsageUpdateCheck(
            installedVersion: installedVersion,
            latestVersion: metadata.version,
            checkedAt: now
        )
    }

    static func bundledVersion(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: bundleVersionKey) as? String
    }

    static func parseMetadata(_ data: Data) throws -> (name: String, version: String) {
        let metadata = try JSONDecoder().decode(RegistryMetadata.self, from: data)
        guard !metadata.name.isEmpty, !metadata.version.isEmpty else {
            throw CheckError.invalidResponse
        }
        return (metadata.name, metadata.version)
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let candidateParts = versionParts(candidate)
        let installedParts = versionParts(installed)
        let count = max(candidateParts.count, installedParts.count)
        for index in 0..<count {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < installedParts.count ? installedParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }

        // A stable release supersedes an otherwise-equal prerelease.
        return candidate.split(separator: "-", maxSplits: 1).count == 1
            && installed.split(separator: "-", maxSplits: 1).count > 1
    }

    private static func versionParts(_ version: String) -> [Int] {
        version
            .split(separator: "-", maxSplits: 1)[0]
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    private struct RegistryMetadata: Decodable {
        let name: String
        let version: String
    }
}
