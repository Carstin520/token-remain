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
