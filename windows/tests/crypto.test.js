import assert from "node:assert/strict";
import test from "node:test";
import { acceptPairingResponse, makePairingRequest, makeSnapshot, openEnvelope, sealSnapshot, stableStringify } from "../electron/sync/crypto.js";
import { validateRemoteSnapshot } from "../electron/sync/client.js";

const key = Buffer.from("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "hex");
const keyID = "11111111-2222-4333-8444-555555555555";
const sourceInstanceID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";

test("AES-GCM direct-sync envelope round trips and binds its header", () => {
  const now = Date.now();
  const snapshot = makeSnapshot({
    sourceInstanceID,
    sequence: 7,
    now,
    providers: [{
      providerID: "codex",
      capturedAt: now,
      planName: "Pro 5x",
      windows: [{ usedPercent: 37, windowMinutes: 300, resetsAt: now + 3_600_000 }],
    }],
  });
  const envelope = sealSnapshot(snapshot, { key, keyID, nonce: Buffer.alloc(12, 0xa5) });
  assert.equal(
    stableStringify(openEnvelope(envelope, { key, expectedKeyID: keyID })),
    stableStringify(snapshot),
  );

  assert.throws(
    () => openEnvelope({ ...envelope, sequence: 8 }, { key, expectedKeyID: keyID }),
    /authenticate|Unsupported state/i,
  );
});

test("Stable JSON matches Swift sorted-key omission semantics", () => {
  assert.equal(stableStringify({ z: 1, b: undefined, a: { y: 2, x: 1 } }), '{"a":{"x":1,"y":2},"z":1}');
});

test("Windows verifies the canonical Swift pairing response", () => {
  const secret = Buffer.from([...Array(32).keys()]);
  const clientNonce = Buffer.alloc(16, 0x11);
  const { request } = makePairingRequest({ secret, sourceInstanceID, deviceName: "Windows PC", clientNonce });
  const result = acceptPairingResponse({
    secret,
    request,
    clientNonce,
    response: {
      version: 1,
      serverSourceInstanceID: "12345678-1234-4234-8234-123456789abc",
      keyID,
      deviceName: "Mac Studio",
      serverNonce: Buffer.alloc(16, 0x22).toString("base64"),
      proof: "3dbHr8VENveVkIpRg1DbGGjeuQNl0SLA+JhjP/UYF+k=",
    },
  });
  assert.equal(result.key.toString("hex"), "664784ab1a8c55e8756e19abbb2b9f18dd7a4a1b6556a3bef1a8ce8805dd9cac");
  assert.equal(result.deviceName, "Mac Studio");
});

test("Snapshot redaction drops unsafe presentation-only plan labels", () => {
  const snapshot = makeSnapshot({
    sourceInstanceID,
    sequence: 1,
    providers: [{ providerID: "claude", capturedAt: Date.now(), planName: "me@example.com", windows: [{ usedPercent: 1, windowMinutes: 300 }] }],
  });
  assert.equal(snapshot.providers[0].planName, undefined);
});

test("Direct Sync omits Windows-only provider detail fields", () => {
  const snapshot = makeSnapshot({
    sourceInstanceID,
    sequence: 2,
    providers: [{
      providerID: "claude",
      capturedAt: Date.now(),
      windows: [{ usedPercent: 1, windowMinutes: 300 }],
      extraUsage: { spentUSD: 12.5, monthlyLimitUSD: 50 },
      codexResetCredits: { availableCount: 2 },
    }],
  });
  assert.equal(snapshot.providers[0].extraUsage, undefined);
  assert.equal(snapshot.providers[0].codexResetCredits, undefined);
});

test("Direct Sync keeps retained local model breakdowns off the wire", () => {
  const snapshot = makeSnapshot({
    sourceInstanceID,
    sequence: 3,
    providers: [],
    dailyUsageHistory: {
      sourceDay: "2026-08-25",
      capturedAt: Date.now(),
      days: [{
        day: "2026-08-25",
        agents: [{ id: "codex", models: [{ id: "gpt-5.3-codex", inputTokens: 10 }] }],
      }],
    },
  });
  assert.equal(snapshot.dailyUsageHistory, undefined);
  assert.doesNotMatch(stableStringify(snapshot), /models|gpt-5\.3-codex/);
});

test("Mac responses bind the paired source and reject replayed sequences", () => {
  const snapshot = makeSnapshot({
    sourceInstanceID: "12345678-1234-4234-8234-123456789abc",
    sequence: 9,
    providers: [],
  });
  assert.equal(validateRemoteSnapshot(snapshot, {
    expectedSourceInstanceID: snapshot.sourceInstanceID,
    lastRemoteSequence: 8,
  }), snapshot);
  assert.throws(() => validateRemoteSnapshot(snapshot, {
    expectedSourceInstanceID: snapshot.sourceInstanceID,
    lastRemoteSequence: 9,
  }), /replay/i);
  assert.throws(() => validateRemoteSnapshot(snapshot, {
    expectedSourceInstanceID: sourceInstanceID,
    lastRemoteSequence: 0,
  }), /unexpected source/i);
});

test("Authenticated history round trips and rejects unsafe aggregate fields", () => {
  const now = Date.now();
  const day = new Date(now).toISOString().slice(0, 10);
  const base = makeSnapshot({ sourceInstanceID, sequence: 11, providers: [], now });
  const snapshot = {
    ...base,
    dailyUsageHistory: {
      sourceDay: day,
      capturedAt: now,
      days: [{ day, claudeTokens: 12, claudeCost: 0.5, codexTokens: 34, codexCost: 1.25 }],
    },
  };
  const envelope = sealSnapshot(snapshot, { key, keyID, nonce: Buffer.alloc(12, 0xb4) });
  assert.deepEqual(openEnvelope(envelope, { key, expectedKeyID: keyID }).dailyUsageHistory, snapshot.dailyUsageHistory);

  const invalid = {
    ...snapshot,
    sequence: 12,
    dailyUsageHistory: {
      ...snapshot.dailyUsageHistory,
      days: [{ ...snapshot.dailyUsageHistory.days[0], claudeCost: Infinity }],
    },
  };
  const invalidEnvelope = sealSnapshot(invalid, { key, keyID, nonce: Buffer.alloc(12, 0xc5) });
  assert.throws(() => openEnvelope(invalidEnvelope, { key, expectedKeyID: keyID }), /cost/i);
});

test("Synced provider balances use the same bounded wire shape as macOS", () => {
  const now = Date.now();
  const base = makeSnapshot({ sourceInstanceID, sequence: 15, providers: [], now });
  const valid = {
    ...base,
    providers: [{
      providerID: "openrouter",
      capturedAt: now,
      windows: [{ usedPercent: 20, windowMinutes: 0, remainingBalance: { amount: 42.75, currencyCode: "USD" } }],
    }],
  };
  const validEnvelope = sealSnapshot(valid, { key, keyID, nonce: Buffer.alloc(12, 0xd5) });
  assert.equal(openEnvelope(validEnvelope, { key, expectedKeyID: keyID }).providers[0].windows[0].remainingBalance.amount, 42.75);

  const invalid = {
    ...valid,
    sequence: 16,
    providers: [{ ...valid.providers[0], windows: [{ ...valid.providers[0].windows[0], remainingBalance: { amount: 42.75, currencyCode: "USD<script>" } }] }],
  };
  const invalidEnvelope = sealSnapshot(invalid, { key, keyID, nonce: Buffer.alloc(12, 0xe5) });
  assert.throws(() => openEnvelope(invalidEnvelope, { key, expectedKeyID: keyID }), /balance/i);
});

test("Named primary pools and same-duration scoped siblings round trip on schema v1", () => {
  const now = Date.now();
  const snapshot = makeSnapshot({
    sourceInstanceID,
    sequence: 17,
    now,
    providers: [{
      providerID: "cursor",
      capturedAt: now,
      windows: [{ usedPercent: 91, windowMinutes: 43_200, poolName: "Other Models" }],
      scopedWindows: [{
        scopeID: "cursor_auto",
        displayName: "Cursor Models",
        window: { usedPercent: 2, windowMinutes: 43_200 },
        observedAt: now,
      }],
    }],
  });
  assert.equal(snapshot.schemaVersion, 1);
  assert.equal(snapshot.providers[0].windows[0].poolName, "Other Models");
  assert.equal(snapshot.providers[0].scopedWindows[0].observedAt, undefined);
  const envelope = sealSnapshot(snapshot, { key, keyID, nonce: Buffer.alloc(12, 0xf5) });
  const decoded = openEnvelope(envelope, { key, expectedKeyID: keyID });
  assert.equal(decoded.providers[0].windows[0].poolName, "Other Models");
  assert.equal(decoded.providers[0].scopedWindows[0].window.windowMinutes, 43_200);
});

test("Pool names sanitize on send and validate on receive", () => {
  const now = Date.now();
  const sanitized = makeSnapshot({
    sourceInstanceID,
    sequence: 18,
    now,
    providers: [{ providerID: "cursor", capturedAt: now, windows: [{ usedPercent: 40, windowMinutes: 43_200, poolName: "user@example.com" }] }],
  });
  assert.equal(sanitized.providers[0].windows[0].poolName, undefined);

  const invalid = {
    ...sanitized,
    sequence: 19,
    providers: [{ ...sanitized.providers[0], windows: [{ ...sanitized.providers[0].windows[0], poolName: "user@example.com" }] }],
  };
  const invalidEnvelope = sealSnapshot(invalid, { key, keyID, nonce: Buffer.alloc(12, 0xa6) });
  assert.throws(() => openEnvelope(invalidEnvelope, { key, expectedKeyID: keyID }), /pool name/i);
});

test("General windows still reject duplicate durations while scoped siblings remain compatible", () => {
  const now = Date.now();
  const base = makeSnapshot({ sourceInstanceID, sequence: 20, providers: [], now });
  const invalid = {
    ...base,
    providers: [{
      providerID: "copilot",
      capturedAt: now,
      windows: [
        { usedPercent: 80, windowMinutes: 43_200, poolName: "Chat" },
        { usedPercent: 25, windowMinutes: 43_200, poolName: "Completions" },
      ],
    }],
  };
  const envelope = sealSnapshot(invalid, { key, keyID, nonce: Buffer.alloc(12, 0xb6) });
  assert.throws(() => openEnvelope(envelope, { key, expectedKeyID: keyID }), /duplicate/i);
});

test("Direct Sync applies macOS's shared eight-window transport budget", () => {
  const now = Date.now();
  const snapshot = makeSnapshot({
    sourceInstanceID,
    sequence: 21,
    now,
    providers: [{
      providerID: "codex",
      capturedAt: now,
      windows: [
        { usedPercent: 10, windowMinutes: 300 },
        { usedPercent: 20, windowMinutes: 10_080 },
      ],
      scopedWindows: Array.from({ length: 8 }, (_, index) => ({
        scopeID: `model_${index}`,
        displayName: `Model ${index}`,
        window: { usedPercent: index, windowMinutes: index % 2 ? 10_080 : 300 },
        observedAt: now,
      })),
    }],
  });
  assert.equal(snapshot.providers[0].windows.length, 2);
  assert.equal(snapshot.providers[0].scopedWindows.length, 6);
  const envelope = sealSnapshot(snapshot, { key, keyID, nonce: Buffer.alloc(12, 0xc6) });
  assert.equal(openEnvelope(envelope, { key, expectedKeyID: keyID }).providers[0].scopedWindows.length, 6);
});

test("History validation rejects duplicate days and more than thirty entries", () => {
  const now = Date.now();
  const day = new Date(now).toISOString().slice(0, 10);
  const base = makeSnapshot({ sourceInstanceID, sequence: 13, providers: [], now });
  const row = { day, claudeTokens: 1, claudeCost: 1, codexTokens: 1, codexCost: 1 };
  for (const [sequence, days, message] of [
    [13, [row, row], /sorted|unique/i],
    [14, Array.from({ length: 31 }, () => row), /history/i],
  ]) {
    const snapshot = { ...base, sequence, dailyUsageHistory: { sourceDay: day, capturedAt: now, days } };
    const envelope = sealSnapshot(snapshot, { key, keyID, nonce: Buffer.alloc(12, sequence) });
    assert.throws(() => openEnvelope(envelope, { key, expectedKeyID: keyID }), message);
  }
});
