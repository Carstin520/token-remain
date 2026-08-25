import Foundation
import Testing
@testable import TokenRemainSyncKit

private let fixedNow = Date(timeIntervalSince1970: 1_784_764_800) // 2026-07-22T00:00:00Z
private let fixedConfiguration = SyncValidationConfiguration(now: fixedNow)
private let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
private let keyID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
private let containerID = "iCloud.com.jamesli.tokenremain"

private func snapshot(
    sourceInstanceID: UUID = sourceID,
    sequence: UInt64 = 1,
    generatedAt: Date = fixedNow,
    expiresAt: Date = fixedNow + 600,
    providers: [SyncedProviderQuota]? = nil,
    aggregateUsage: AggregateUsage? = nil,
    dailyUsageHistory: SyncedDailyUsageHistory? = nil,
    curatedFeed: SyncedCuratedFeed? = nil
) -> MobileUsageSnapshot {
    MobileUsageSnapshot(
        sourceInstanceID: sourceInstanceID,
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
    @Test("Per-window monetary balances round-trip and preserve the percentage meter")
    func monetaryBalanceRoundTrip() throws {
        let provider = SyncedProviderQuota(
            providerID: SyncedProviderID.openrouter,
            windows: [SyncedQuotaWindow(
                usedPercent: 37.5,
                windowMinutes: 0,
                resetsAt: nil,
                remainingBalance: SyncedQuotaBalance(amount: 62.5, currencyCode: "USD")
            )],
            capturedAt: fixedNow,
            statusCode: .available
        )
        let decoded = try MobileUsageSnapshot.decodedPayload(
            from: snapshot(providers: [provider]).encodedPayload()
        )
        #expect(decoded.providers.first?.windows.first?.usedPercent == 37.5)
        #expect(decoded.providers.first?.windows.first?.remainingBalance == SyncedQuotaBalance(
            amount: 62.5,
            currencyCode: "USD"
        ))

        let invalid = SyncedProviderQuota(
            providerID: SyncedProviderID.openrouter,
            windows: [SyncedQuotaWindow(
                usedPercent: 37.5,
                windowMinutes: 0,
                resetsAt: nil,
                remainingBalance: SyncedQuotaBalance(amount: 62.5, currencyCode: "USD $")
            )],
            capturedAt: fixedNow,
            statusCode: .available
        )
        #expect(throws: SyncValidationError.invalidBalance(SyncedProviderID.openrouter)) {
            try snapshot(providers: [invalid]).validatedForTransport(configuration: fixedConfiguration)
        }
    }

    @Test("Named scoped quota windows round-trip without changing legacy windows")
    func scopedQuotaRoundTrip() throws {
        let provider = SyncedProviderQuota(
            providerID: SyncedProviderID.claude,
            windows: [SyncedQuotaWindow(usedPercent: 12, windowMinutes: 300, resetsAt: fixedNow + 300)],
            capturedAt: fixedNow,
            statusCode: .available,
            scopedWindows: [
                SyncedScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: SyncedQuotaWindow(usedPercent: 67, windowMinutes: 10_080, resetsAt: fixedNow + 600)
                )
            ]
        )
        let original = snapshot(providers: [provider])
        let decoded = try MobileUsageSnapshot.decodedPayload(from: original.encodedPayload())

        #expect(decoded.providers.first?.windows.count == 1)
        #expect(decoded.providers.first?.scopedWindows?.first?.scopeID == "fable")
        #expect(decoded.providers.first?.scopedWindows?.first?.window.usedPercent == 67)
    }

    @Test("Pool names round-trip; payloads without them decode as nil")
    func poolNameRoundTrip() throws {
        let provider = SyncedProviderQuota(
            providerID: SyncedProviderID.cursor,
            windows: [
                SyncedQuotaWindow(
                    usedPercent: 41,
                    windowMinutes: 43_200,
                    resetsAt: fixedNow + 600,
                    poolName: "Cursor Models"
                ),
                SyncedQuotaWindow(usedPercent: 12, windowMinutes: 300, resetsAt: fixedNow + 300)
            ],
            capturedAt: fixedNow,
            statusCode: .available
        )
        let original = snapshot(providers: [provider])
        let payload = try original.encodedPayload()
        let decoded = try MobileUsageSnapshot.decodedPayload(from: payload)

        #expect(decoded.providers.first?.windows.first?.poolName == "Cursor Models")
        #expect(decoded.providers.first?.windows.last?.poolName == nil)
        #expect(throws: Never.self) {
            try original.validatedForTransport(configuration: fixedConfiguration)
        }

        // A pool-less window omits the key entirely, so this payload is
        // byte-shaped exactly like one from a pre-poolName build; decoding it
        // proves an older Mac's payload still decodes, with poolName == nil.
        let legacyShaped = try MobileUsageSnapshot.decodedPayload(
            from: snapshot().encodedPayload()
        )
        let legacyText = try #require(String(data: try snapshot().encodedPayload(), encoding: .utf8))
        #expect(!legacyText.contains("poolName"))
        #expect(legacyShaped.providers.first?.windows.first?.poolName == nil)
    }

    @Test("An unsanitized pool name is rejected at the transport boundary")
    func invalidPoolNameIsRejected() throws {
        func provider(poolName: String) -> SyncedProviderQuota {
            SyncedProviderQuota(
                providerID: SyncedProviderID.cursor,
                windows: [SyncedQuotaWindow(
                    usedPercent: 41,
                    windowMinutes: 43_200,
                    resetsAt: fixedNow + 600,
                    poolName: poolName
                )],
                capturedAt: fixedNow,
                statusCode: .available
            )
        }

        // Account-like and over-long labels both fail; the redactor drops them
        // to nil before packaging, so only bypassing senders can hit this.
        #expect(throws: SyncValidationError.invalidPoolName(SyncedProviderID.cursor)) {
            try snapshot(providers: [provider(poolName: "user@example.com")])
                .validatedForTransport(configuration: fixedConfiguration)
        }
        #expect(throws: SyncValidationError.invalidPoolName(SyncedProviderID.cursor)) {
            try snapshot(providers: [provider(poolName: String(repeating: "a", count: 49))])
                .validatedForTransport(configuration: fixedConfiguration)
        }
        #expect(SyncedQuotaWindow.sanitizedPoolName(String(repeating: "a", count: 48))
            == String(repeating: "a", count: 48))
        #expect(SyncedQuotaWindow.sanitizedPoolName(nil) == nil)
    }

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

    @Test("Optional source day survives history round trip and stays bounded")
    func historySourceDayRoundTrip() throws {
        let history = SyncedDailyUsageHistory(
            days: [SyncedDailyUsageDay(
                day: "2026-07-22",
                claudeTokens: 12,
                claudeCost: 0.5,
                codexTokens: 34,
                codexCost: 1.25
            )],
            capturedAt: fixedNow,
            sourceDay: "2026-07-22"
        )
        let decoded = try MobileUsageSnapshot.decodedPayload(
            from: snapshot(dailyUsageHistory: history).encodedPayload()
        )
        #expect(decoded.dailyUsageHistory?.sourceDay == "2026-07-22")
        #expect(throws: SyncValidationError.invalidDailyUsageHistory) {
            try snapshot(dailyUsageHistory: SyncedDailyUsageHistory(
                days: history.days,
                capturedAt: fixedNow,
                sourceDay: "2050-01-01"
            )).validatedForTransport(configuration: fixedConfiguration)
        }
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

    @Test("Per-source replay registry keeps independent Mac LWW state")
    func perSourceReplayOrdering() throws {
        let secondSource = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        var replay = SyncReplayRegistry()

        #expect(try replay.evaluate(
            snapshot(sourceInstanceID: sourceID, sequence: 4),
            configuration: fixedConfiguration
        ) == .accepted)
        #expect(try replay.evaluate(
            snapshot(sourceInstanceID: secondSource, sequence: 1),
            configuration: fixedConfiguration
        ) == .accepted)
        #expect(replay.count == 2)
        #expect(replay.marker(for: sourceID)?.sequence == 4)
        #expect(replay.marker(for: secondSource)?.sequence == 1)

        #expect(try replay.evaluate(
            snapshot(sourceInstanceID: sourceID, sequence: 3),
            configuration: fixedConfiguration
        ) == .replayedOlderSequence)
        #expect(try replay.evaluate(
            snapshot(sourceInstanceID: secondSource, sequence: 2),
            configuration: fixedConfiguration
        ) == .accepted)
        #expect(replay.marker(for: sourceID)?.sequence == 4)
        #expect(replay.marker(for: secondSource)?.sequence == 2)
    }

    @Test("Same source and sequence with altered payload is a conflict")
    func replayPayloadConflict() throws {
        var replay = SyncReplayRegistry()
        let original = snapshot(sequence: 7)
        let alteredProvider = SyncedProviderQuota(
            providerID: SyncedProviderID.claude,
            windows: [SyncedQuotaWindow(usedPercent: 91, windowMinutes: 300, resetsAt: fixedNow + 9_000)],
            capturedAt: fixedNow,
            statusCode: .available
        )
        let altered = snapshot(sequence: 7, providers: [alteredProvider])

        #expect(try replay.evaluate(original, configuration: fixedConfiguration) == .accepted)
        #expect(try replay.evaluate(original, configuration: fixedConfiguration) == .duplicate)
        #expect(try replay.evaluate(altered, configuration: fixedConfiguration) == .conflictingSequence)
    }

    @Test("Per-source replay registry persists deterministic authenticated markers")
    func replayRegistryPersistence() throws {
        let secondSource = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        var replay = SyncReplayRegistry()
        _ = try replay.evaluate(snapshot(sequence: 2), configuration: fixedConfiguration)
        _ = try replay.evaluate(
            snapshot(sourceInstanceID: secondSource, sequence: 9),
            configuration: fixedConfiguration
        )

        let data = try JSONEncoder().encode(replay)
        let decoded = try JSONDecoder().decode(SyncReplayRegistry.self, from: data)

        #expect(decoded == replay)
        #expect(decoded.markers.allSatisfy { $0.payloadDigest?.count == 64 })
    }

    @Test("Legacy replay markers decode without a payload digest")
    func legacyReplayMarkerCompatibility() throws {
        struct LegacyReplayMarker: Codable {
            let sourceInstanceID: UUID
            let sequence: UInt64
            let generatedAt: Date
        }

        let data = try JSONEncoder().encode(LegacyReplayMarker(
            sourceInstanceID: sourceID,
            sequence: 5,
            generatedAt: fixedNow
        ))
        let marker = try JSONDecoder().decode(SyncReplayMarker.self, from: data)
        var replay = try SyncReplayRegistry(validating: [marker])

        #expect(marker.payloadDigest == nil)
        #expect(try replay.evaluate(
            snapshot(sequence: 5),
            configuration: fixedConfiguration
        ) == .duplicate)
        #expect(try replay.evaluate(
            snapshot(sequence: 6),
            configuration: fixedConfiguration
        ) == .accepted)
        #expect(replay.marker(for: sourceID)?.payloadDigest?.count == 64)
    }

    @Test("Per-source replay registry enforces its device budget")
    func replayRegistrySourceLimit() throws {
        let markers = (0..<SyncReplayRegistry.maximumSourceCount).map { index in
            SyncReplayMarker(
                sourceInstanceID: UUID(uuidString: String(
                    format: "00000000-0000-4000-8000-%012x",
                    index + 1
                ))!,
                sequence: 1,
                generatedAt: fixedNow
            )
        }
        var replay = try SyncReplayRegistry(validating: markers)
        let overflowSource = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!

        #expect(throws: SyncReplayRegistryError.tooManySources) {
            try replay.evaluate(
                snapshot(sourceInstanceID: overflowSource),
                configuration: fixedConfiguration
            )
        }
    }

    @Test("Multi-Mac aggregation selects fresh quotas and sums opt-in daily usage")
    func multiMacAggregation() throws {
        let secondSource = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let firstHistory = SyncedDailyUsageHistory(
            days: [SyncedDailyUsageDay(
                day: "2026-07-21",
                claudeTokens: 10,
                claudeCost: 1.5,
                codexTokens: 20,
                codexCost: 2.5
            )],
            capturedAt: fixedNow
        )
        let secondHistory = SyncedDailyUsageHistory(
            days: [SyncedDailyUsageDay(
                day: "2026-07-21",
                claudeTokens: 30,
                claudeCost: 3.5,
                codexTokens: 40,
                codexCost: 4.5
            )],
            capturedAt: fixedNow + 1
        )
        let staleClaude = SyncedProviderQuota(
            providerID: SyncedProviderID.claude,
            windows: [SyncedQuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil)],
            capturedAt: fixedNow - 60,
            statusCode: .available
        )
        let freshClaude = SyncedProviderQuota(
            providerID: SyncedProviderID.claude,
            windows: [SyncedQuotaWindow(usedPercent: 75, windowMinutes: 300, resetsAt: nil)],
            capturedAt: fixedNow,
            statusCode: .available
        )
        let codex = SyncedProviderQuota(
            providerID: SyncedProviderID.codex,
            windows: [SyncedQuotaWindow(usedPercent: 35, windowMinutes: 10_080, resetsAt: nil)],
            capturedAt: fixedNow,
            statusCode: .available
        )

        let aggregated = try MobileUsageSnapshotAggregator.aggregate([
            snapshot(providers: [staleClaude], dailyUsageHistory: firstHistory),
            snapshot(
                sourceInstanceID: secondSource,
                sequence: 2,
                generatedAt: fixedNow + 1,
                expiresAt: fixedNow + 300,
                providers: [freshClaude, codex],
                dailyUsageHistory: secondHistory
            ),
        ], now: fixedNow)
        let aggregate = try #require(aggregated)

        #expect(aggregate.sourceInstanceID == MobileUsageSnapshotAggregator.aggregateSourceInstanceID)
        #expect(aggregate.generatedAt == fixedNow)
        #expect(aggregate.expiresAt == fixedNow + 300)
        #expect(aggregate.providers.map(\.providerID) == [SyncedProviderID.claude, SyncedProviderID.codex])
        #expect(aggregate.providers[0].windows[0].usedPercent == 75)
        let day = try #require(aggregate.dailyUsageHistory?.days.first)
        #expect(day.claudeTokens == 40)
        #expect(day.claudeCost == 5)
        #expect(day.codexTokens == 60)
        #expect(day.codexCost == 7)
    }

    @Test("Multi-Mac aggregation rejects duplicate source identities")
    func multiMacAggregationRejectsDuplicateSources() {
        #expect(throws: MobileUsageAggregationError.duplicateSource) {
            try MobileUsageSnapshotAggregator.aggregate(
                [snapshot(sequence: 1), snapshot(sequence: 2)],
                now: fixedNow
            )
        }
    }

    @Test("Multi-Mac aggregation enforces its authenticated source budget")
    func multiMacAggregationRejectsTooManySources() {
        let sources = (0...SyncReplayRegistry.maximumSourceCount).map { index in
            snapshot(sourceInstanceID: UUID(uuidString: String(
                format: "00000000-0000-4000-8000-%012x",
                index + 1
            ))!)
        }

        #expect(throws: MobileUsageAggregationError.tooManySources) {
            try MobileUsageSnapshotAggregator.aggregate(sources, now: fixedNow)
        }
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
