import Foundation
import TokenRemainSyncKit

struct MobileSyncDelivery: Sendable, Equatable {
    let snapshot: MobileUsageSnapshot
    let macUploadedAt: Date?
    let phoneReceivedAt: Date
}

/// Main-app-only operational telemetry. The file contains provider slugs and
/// timestamps only; it is never copied into the App Group or uploaded.
struct MobileSyncLatencyStore: Sendable {
    static let maximumObservations = 240
    static let shared = MobileSyncLatencyStore()

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = base.appendingPathComponent("TokenRemain", isDirectory: true)
        }
    }

    private var fileURL: URL {
        directory.appendingPathComponent("sync-latency-v1.json")
    }

    func observations() -> [SyncLatencyObservation] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.latency.decode(
                [SyncLatencyObservation].self,
                from: data
              ) else {
            return []
        }
        return decoded.filter {
            SyncedProviderID.isWellFormed($0.providerID) && $0.endToEndSeconds != nil
        }
    }

    @discardableResult
    func record(
        _ delivery: MobileSyncDelivery,
        phoneRenderedAt: Date
    ) -> SyncLatencySummary? {
        guard let macUploadedAt = delivery.macUploadedAt else {
            return summary()
        }
        let newValues = delivery.snapshot.providers.compactMap { provider in
            SyncLatencyObservation(
                providerID: provider.providerID,
                providerCapturedAt: provider.capturedAt,
                macUploadedAt: macUploadedAt,
                phoneReceivedAt: delivery.phoneReceivedAt,
                phoneRenderedAt: phoneRenderedAt
            )
        }
        guard !newValues.isEmpty else { return summary() }

        let retained = Array((observations() + newValues).suffix(Self.maximumObservations))
        guard let data = try? JSONEncoder.latency.encode(retained) else {
            return SyncLatencySummary.calculate(from: retained)
        }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        return SyncLatencySummary.calculate(from: retained)
    }

    func summary() -> SyncLatencySummary? {
        SyncLatencySummary.calculate(from: observations())
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private extension JSONEncoder {
    static var latency: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var latency: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
