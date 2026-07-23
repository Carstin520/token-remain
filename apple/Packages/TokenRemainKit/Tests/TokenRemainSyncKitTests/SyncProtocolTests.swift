import Foundation
import Testing
@testable import TokenRemainSyncKit

private let fixedNow = Date(timeIntervalSince1970: 1_784_764_800) // 2026-07-22T00:00:00Z
private let fixedConfiguration = SyncValidationConfiguration(now: fixedNow)
private let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
private let keyID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
private let containerID = "iCloud.com.jamesli.tokenremain"

private func snapshot(
    sequence: UInt64 = 1,
    generatedAt: Date = fixedNow,
    expiresAt: Date = fixedNow + 600,
    providers: [SyncedProviderQuota]? = nil,
    aggregateUsage: AggregateUsage? = nil,
    dailyUsageHistory: SyncedDailyUsageHistory? = nil,
    curatedFeed: SyncedCuratedFeed? = nil
) -> MobileUsageSnapshot {
    MobileUsageSnapshot(
        sourceInstanceID: sourceID,
        sequence: sequence,
        generatedAt: generatedAt,
        expiresAt: expiresAt,
        providers: providers ?? [
            SyncedProviderQuota(
                providerID: SyncedProviderID.claude,
                windows: [SyncedQuotaWindow(usedPercent: 42.5, windowMinutes: 300, resetsAt: fixedNow + 9_000)],
                capturedAt: fixedNow,
                statusCode: .available
            )
        ],
        aggregateUsage: aggregateUsage,
        dailyUsageHistory: dailyUsageHistory,
        curatedFeed: curatedFeed
    )
}

@Suite("Cross-device sync protocol")
struct SyncProtocolTests {
    @Test("AES-GCM envelope round-trips a normalized allowlisted snapshot")
    func roundTrip() throws {
        let key = try SyncEncryptionKey(rawValue: Data(repeating: 7, count: 32))
        let original = snapshot(generatedAt: fixedNow + 0.9876)
        let envelope = try EncryptedSyncEnvelope.seal(
            original,
            using: key,
            keyID: keyID,
            containerID: containerID,
            configuration: fixedConfiguration
        )
        let wire = try envelope.encoded()
        let decodedEnvelope = try EncryptedSyncEnvelope.decoded(from: wire)
        let opened = try decodedEnvelope.open(
            using: key,
            containerID: containerID,
            configuration: fixedConfiguration
        )

        #expect(opened.sequence == original.sequence)
        #expect(opened.sourceInstanceID == original.sourceInstanceID)
        #expect(opened.providers == original.providers)
        #expect(opened.generatedAt == Date(timeIntervalSince1970: 1_784_764_800.987))
    }

    @Test("Daily usage history round-trips inside the encrypted allowlist")
    func dailyHistoryRoundTrip() throws {
        let history = SyncedDailyUsageHistory(
            days: [
                SyncedDailyUsageDay(
                    day: "2026-07-20",
                    claudeTokens: 12_000_000,
                    claudeCost: 21.4,
                    codexTokens: 8_000_000,
                    codexCost: 10.2
                ),
                SyncedDailyUsageDay(
                    day: "2026-07-21",
                    claudeTokens: 14_000_000,
                    claudeCost: 24.1,
                    codexTokens: 9_000_000,
                    codexCost: 11.8
                )
            ],
            capturedAt: fixedNow
        )
        let key = try SyncEncryptionKey(rawValue: Data(repeating: 8, count: 32))
        let envelope = try EncryptedSyncEnvelope.seal(
            snapshot(dailyUsageHistory: history),
            using: key,
            keyID: keyID,
            containerID: containerID,
            configuration: fixedConfiguration
        )
        let opened = try envelope.open(
            using: key,
            containerID: containerID,
            configuration: fixedConfiguration
        )

        #expect(opened.dailyUsageHistory == history)
    }

    @Test("Curated public X posts round-trip without credentials")
    func curatedFeedRoundTrip() throws {
        let feed = SyncedCuratedFeed(
            posts: [
                SyncedCuratedPost(
                    id: "1234567890123456789",
                    username: "OpenAI",
                    displayName: "OpenAI",
                    text: "A public product update.",
                    createdAt: fixedNow - 60,
                    url: URL(string: "https://x.com/OpenAI/status/1234567890123456789")!,
                    priority: .majorUpdate
                )
            ],
            capturedAt: fixedNow
        )
        let key = try SyncEncryptionKey(rawValue: Data(repeating: 9, count: 32))
        let envelope = try EncryptedSyncEnvelope.seal(
            snapshot(curatedFeed: feed),
            using: key,
            keyID: keyID,
            containerID: containerID,
            configuration: fixedConfiguration
        )
        let opened = try envelope.open(
            using: key,
            containerID: containerID,
            configuration: fixedConfiguration
        )

        #expect(opened.curatedFeed == feed)
        let payload = try opened.encodedPayload()
        let text = try #require(String(data: payload, encoding: .utf8))
        #expect(!text.lowercased().contains("bearer"))
        #expect(!text.lowercased().contains("token"))
    }

    @Test("Curated feed rejects non-X links, duplicates, stale posts, and oversized sets")
    func curatedFeedValidation() {
        func post(
            id: String = "1234567890123456789",
            createdAt: Date = fixedNow - 60,
            url: String = "https://x.com/OpenAI/status/1234567890123456789"
        ) -> SyncedCuratedPost {
            SyncedCuratedPost(
                id: id,
                username: "OpenAI",
                displayName: "OpenAI",
                text: "Public update",
                createdAt: createdAt,
                url: URL(string: url)!,
                priority: .normal
            )
        }
        func feed(_ posts: [SyncedCuratedPost]) -> SyncedCuratedFeed {
            SyncedCuratedFeed(posts: posts, capturedAt: fixedNow)
        }

        #expect(throws: SyncValidationError.invalidCuratedFeed) {
            try snapshot(curatedFeed: feed([
                post(url: "https://example.com/OpenAI/status/1234567890123456789")
            ])).validatedForTransport(configuration: fixedConfiguration)
        }
        #expect(throws: SyncValidationError.invalidCuratedFeed) {
            try snapshot(curatedFeed: feed([post(), post()]))
                .validatedForTransport(configuration: fixedConfiguration)
        }
        #expect(throws: SyncValidationError.invalidCuratedFeed) {
            try snapshot(curatedFeed: feed([
                post(createdAt: fixedNow - SyncedCuratedFeed.maximumPostAge - 1)
            ])).validatedForTransport(configuration: fixedConfiguration)
        }
        let tooMany = (0...SyncedCuratedFeed.maximumPosts).map { index in
            let id = "12345678901234567\(index)"
            return post(id: id, url: "https://x.com/OpenAI/status/\(id)")
        }
        #expect(throws: SyncValidationError.invalidCuratedFeed) {
            try snapshot(curatedFeed: feed(tooMany))
                .validatedForTransport(configuration: fixedConfiguration)
        }
    }

    @Test("Daily history rejects duplicates, stale dates, negative values, and oversized retention")
    func dailyHistoryValidation() {
        func history(_ days: [SyncedDailyUsageDay]) -> SyncedDailyUsageHistory {
            SyncedDailyUsageHistory(days: days, capturedAt: fixedNow)
        }
        let valid = SyncedDailyUsageDay(
            day: "2026-07-21",
            claudeTokens: 1,
            claudeCost: 1,
            codexTokens: 1,
            codexCost: 1
        )
        let duplicate = history([valid, valid])
        #expect(throws: SyncValidationError.invalidDailyUsageHistory) {
            try snapshot(dailyUsageHistory: duplicate)
                .validatedForTransport(configuration: fixedConfiguration)
        }

        let stale = history([SyncedDailyUsageDay(
            day: "2026-01-01",
            claudeTokens: 1,
            claudeCost: 1,
            codexTokens: 1,
            codexCost: 1
        )])
        #expect(throws: SyncValidationError.invalidDailyUsageHistory) {
            try snapshot(dailyUsageHistory: stale)
                .validatedForTransport(configuration: fixedConfiguration)
        }

        let negative = history([SyncedDailyUsageDay(
            day: "2026-07-21",
            claudeTokens: -1,
            claudeCost: 1,
            codexTokens: 1,
            codexCost: 1
        )])
        #expect(throws: SyncValidationError.invalidDailyUsageHistory) {
            try snapshot(dailyUsageHistory: negative)
                .validatedForTransport(configuration: fixedConfiguration)
        }

        let tooMany = history((0...SyncedDailyUsageHistory.maximumDays).map { index in
            SyncedDailyUsageDay(
                day: String(format: "2026-06-%02d", index + 1),
                claudeTokens: 1,
                claudeCost: 1,
                codexTokens: 1,
                codexCost: 1
            )
        })
        #expect(throws: SyncValidationError.invalidDailyUsageHistory) {
            try snapshot(dailyUsageHistory: tooMany)
                .validatedForTransport(configuration: fixedConfiguration)
        }
    }

    @Test("Ciphertext and authenticated headers reject tampering")
    func tamperRejection() throws {
        let key = try SyncEncryptionKey(rawValue: Data(repeating: 1, count: 32))
        let envelope = try EncryptedSyncEnvelope.seal(
            snapshot(), using: key, keyID: keyID, containerID: containerID, configuration: fixedConfiguration
        )

        var modifiedCiphertext = envelope.sealedPayload
        modifiedCiphertext[modifiedCiphertext.startIndex] ^= 0x01
        let alteredCiphertext = try EncryptedSyncEnvelope(
            keyID: envelope.keyID,
            sourceInstanceID: envelope.sourceInstanceID,
            sequence: envelope.sequence,
            generatedAt: envelope.generatedAt,
            sealedPayload: modifiedCiphertext
        )
        #expect(throws: SyncProtocolError.authenticationFailed) {
            try alteredCiphertext.open(using: key, containerID: containerID, configuration: fixedConfiguration)
        }

        let alteredHeader = try EncryptedSyncEnvelope(
            keyID: envelope.keyID,
            sourceInstanceID: envelope.sourceInstanceID,
            sequence: envelope.sequence + 1,
            generatedAt: envelope.generatedAt,
            sealedPayload: envelope.sealedPayload
        )
        #expect(throws: SyncProtocolError.authenticationFailed) {
            try alteredHeader.open(using: key, containerID: containerID, configuration: fixedConfiguration)
        }
    }

    @Test("A different 256-bit key cannot decrypt a snapshot")
    func wrongKey() throws {
        let key = try SyncEncryptionKey(rawValue: Data(repeating: 2, count: 32))
        let otherKey = try SyncEncryptionKey(rawValue: Data(repeating: 3, count: 32))
        let envelope = try EncryptedSyncEnvelope.seal(
            snapshot(), using: key, keyID: keyID, containerID: containerID, configuration: fixedConfiguration
        )
        #expect(throws: SyncProtocolError.authenticationFailed) {
            try envelope.open(using: otherKey, containerID: containerID, configuration: fixedConfiguration)
        }
    }

    @Test("Container identity is authenticated and every seal uses a fresh nonce")
    func containerBindingAndNonceUniqueness() throws {
        let key = try SyncEncryptionKey(rawValue: Data(repeating: 6, count: 32))
        let first = try EncryptedSyncEnvelope.seal(
            snapshot(), using: key, keyID: keyID, containerID: containerID, configuration: fixedConfiguration
        )
        let second = try EncryptedSyncEnvelope.seal(
            snapshot(), using: key, keyID: keyID, containerID: containerID, configuration: fixedConfiguration
        )

        #expect(first.sealedPayload != second.sealedPayload)
        #expect(throws: SyncProtocolError.authenticationFailed) {
            try first.open(
                using: key,
                containerID: "iCloud.com.jamesli.not-tokenremain",
                configuration: fixedConfiguration
            )
        }
    }

    @Test("Payload and encoded-envelope size limits are enforced")
    func oversize() throws {
        let key = try SyncEncryptionKey(rawValue: Data(repeating: 4, count: 32))
        let hugeProvider = SyncedProviderQuota(
            providerID: String(repeating: "a", count: 64),
            windows: Array(repeating: SyncedQuotaWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil), count: 8),
            capturedAt: fixedNow,
            statusCode: .available
        )
        let payload = snapshot(providers: Array(repeating: hugeProvider, count: 33))
        #expect(throws: SyncValidationError.tooManyProviders) {
            try payload.validatedForTransport(configuration: fixedConfiguration)
        }

        let oversizedWire = Data(repeating: 0, count: EncryptedSyncEnvelope.maximumEncodedEnvelopeBytes + 1)
        #expect(throws: SyncProtocolError.envelopeTooLarge(EncryptedSyncEnvelope.maximumEncodedEnvelopeBytes + 1)) {
            try EncryptedSyncEnvelope.decoded(from: oversizedWire)
        }

        let largestValidSnapshot = snapshot(providers: (0..<32).map { providerIndex in
            let prefix = "p\(providerIndex)-"
            let providerID = prefix + String(repeating: "x", count: 64 - prefix.count)
            return SyncedProviderQuota(
                providerID: providerID,
                windows: (0..<8).map { windowIndex in
                    SyncedQuotaWindow(
                        usedPercent: 99.99,
                        windowMinutes: 525_600 - windowIndex,
                        resetsAt: fixedNow + 9_000
                    )
                },
                capturedAt: fixedNow,
                statusCode: .available
            )
        })
        let baseline = try largestValidSnapshot.encodedPayload()
        #expect(baseline.count > EncryptedSyncEnvelope.maximumPlaintextBytes)
        #expect(throws: SyncProtocolError.payloadTooLarge(baseline.count)) {
            try EncryptedSyncEnvelope.seal(
                largestValidSnapshot,
                using: key,
                keyID: keyID,
                containerID: containerID,
                configuration: fixedConfiguration
            )
        }
    }

    @Test("Invalid bounds, duplicate windows, future data, and expiry fail closed")
    func validationBounds() throws {
        let accountLikePlan = snapshot(providers: [
            SyncedProviderQuota(
                providerID: SyncedProviderID.cursor,
                windows: [SyncedQuotaWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil)],
                capturedAt: fixedNow,
                statusCode: .available,
                planName: "user@example.com"
            )
        ])
        #expect(throws: SyncValidationError.invalidPlanName(SyncedProviderID.cursor)) {
            try accountLikePlan.validatedForTransport(configuration: fixedConfiguration)
        }

        let badPercent = snapshot(providers: [
            SyncedProviderQuota(
                providerID: SyncedProviderID.claude,
                windows: [SyncedQuotaWindow(usedPercent: 100.01, windowMinutes: 300, resetsAt: nil)],
                capturedAt: fixedNow,
                statusCode: .available
            )
        ])
        #expect(throws: SyncValidationError.invalidPercent(SyncedProviderID.claude)) {
            try badPercent.validatedForTransport(configuration: fixedConfiguration)
        }

        let duplicateWindows = snapshot(providers: [
            SyncedProviderQuota(
                providerID: SyncedProviderID.claude,
                windows: [
                    SyncedQuotaWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil),
                    SyncedQuotaWindow(usedPercent: 2, windowMinutes: 300, resetsAt: nil)
                ],
                capturedAt: fixedNow,
                statusCode: .available
            )
        ])
        #expect(throws: SyncValidationError.duplicateWindow(SyncedProviderID.claude, 300)) {
            try duplicateWindows.validatedForTransport(configuration: fixedConfiguration)
        }

        #expect(throws: SyncValidationError.dateTooFarInFuture(.generatedAt)) {
            try snapshot(generatedAt: fixedNow + 301, expiresAt: fixedNow + 901)
                .validatedForTransport(configuration: fixedConfiguration)
        }
        #expect(throws: SyncValidationError.snapshotExpired) {
            try snapshot(generatedAt: fixedNow - 1_200, expiresAt: fixedNow - 1)
                .validatedForTransport(configuration: fixedConfiguration)
        }
    }

    @Test("Unknown providers are filtered without discarding known provider data")
    func unknownProviderTolerance() throws {
        let unknown = SyncedProviderQuota(
            providerID: "future-provider",
            windows: [SyncedQuotaWindow(usedPercent: 12, windowMinutes: 60, resetsAt: nil)],
            capturedAt: fixedNow,
            statusCode: .available
        )
        let received = try snapshot(providers: [snapshot().providers[0], unknown])
            .validatedForConsumption(configuration: fixedConfiguration)
        #expect(received.providers.map(\.providerID) == [SyncedProviderID.claude])
    }

    @Test("Replay helper accepts forward progress and rejects rollbacks")
    func replayOrdering() throws {
        var replay = SyncReplayGuard()
        #expect(try replay.evaluate(snapshot(sequence: 2), configuration: fixedConfiguration) == .accepted)
        #expect(try replay.evaluate(snapshot(sequence: 1), configuration: fixedConfiguration) == .replayedOlderSequence)
        #expect(try replay.evaluate(snapshot(sequence: 2), configuration: fixedConfiguration) == .duplicate)

        let conflicting = snapshot(sequence: 2, generatedAt: fixedNow - 1, expiresAt: fixedNow + 600)
        #expect(try replay.evaluate(conflicting, configuration: fixedConfiguration) == .conflictingSequence)

        let newSource = MobileUsageSnapshot(
            sourceInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            sequence: 1,
            generatedAt: fixedNow,
            expiresAt: fixedNow + 600,
            providers: snapshot().providers
        )
        #expect(try replay.evaluate(newSource, configuration: fixedConfiguration) == .sourceChangeRequiresConfirmation)
        let wrongConfirmation = SyncReplayMarker(
            sourceInstanceID: UUID(),
            sequence: newSource.sequence,
            generatedAt: newSource.generatedAt
        )
        #expect(try replay.evaluate(
            newSource,
            confirmedSourceChange: wrongConfirmation,
            configuration: fixedConfiguration
        ) == .sourceChangeRequiresConfirmation)
        let exactConfirmation = SyncReplayMarker(
            sourceInstanceID: newSource.sourceInstanceID,
            sequence: newSource.sequence,
            generatedAt: newSource.generatedAt
        )
        #expect(try replay.evaluate(
            newSource,
            confirmedSourceChange: exactConfirmation,
            configuration: fixedConfiguration
        ) == .accepted)
    }

    @Test("Credential canaries never enter the DTO JSON or encrypted payload plaintext")
    func credentialCanary() throws {
        let canaries = [
            "sk-live-top-secret-should-never-cross-devices",
            "refresh_token=very-secret",
            "Cookie: session=very-secret",
            "Authorization: Bearer very-secret",
            "/Users/alice/private/project"
        ]
        let sourceOnlyMetadata = [
            "accessToken": canaries[0],
            "rawError": canaries[1],
            "cookie": canaries[2],
            "authorization": canaries[3],
            "localPath": canaries[4]
        ]
        #expect(sourceOnlyMetadata.count == canaries.count)

        let cleanSnapshot = snapshot()
        let payload = try cleanSnapshot.encodedPayload()
        let payloadText = try #require(String(data: payload, encoding: .utf8))
        for canary in canaries {
            #expect(!payloadText.contains(canary))
        }
        for deniedField in sourceOnlyMetadata.keys {
            #expect(!payloadText.contains(deniedField))
        }

        let key = try SyncEncryptionKey(rawValue: Data(repeating: 9, count: 32))
        let envelope = try EncryptedSyncEnvelope.seal(
            cleanSnapshot, using: key, keyID: keyID, containerID: containerID, configuration: fixedConfiguration
        )
        let decrypted = try envelope.open(using: key, containerID: containerID, configuration: fixedConfiguration)
        let decryptedText = try #require(String(data: decrypted.encodedPayload(), encoding: .utf8))
        for canary in canaries {
            #expect(!decryptedText.contains(canary))
        }
    }
}
