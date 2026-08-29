import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  hkdfSync,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";

export const DIRECT_SYNC_CONTEXT = "com.jamesli.tokenremain.direct-sync-v1";
export const DIRECT_SYNC_VERSION = 1;
export const MAX_ENVELOPE_BYTES = 32 * 1024;

export function decodeBase64URL(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error("Invalid pairing code");
  }
  return Buffer.from(value, "base64url");
}

export function encodeBase64URL(value) {
  return Buffer.from(value).toString("base64url");
}

export function makePairingRequest({ secret, sourceInstanceID, deviceName, clientNonce = randomBytes(16) }) {
  const normalizedName = normalizeDeviceName(deviceName);
  const nonceText = encodeBase64URL(clientNonce);
  const canonical = pairRequestCanonical(sourceInstanceID, normalizedName, nonceText);
  return {
    request: {
      version: DIRECT_SYNC_VERSION,
      sourceInstanceID,
      deviceName: normalizedName,
      clientNonce: clientNonce.toString("base64"),
      proof: hmac(secret, canonical).toString("base64"),
    },
    clientNonce: Buffer.from(clientNonce),
  };
}

export function acceptPairingResponse({ secret, request, clientNonce, response }) {
  if (response?.version !== DIRECT_SYNC_VERSION) throw new Error("Unsupported pairing response");
  const serverNonce = Buffer.from(response.serverNonce ?? "", "base64");
  const proof = Buffer.from(response.proof ?? "", "base64");
  if (serverNonce.length !== 16 || proof.length !== 32) throw new Error("Malformed pairing response");
  const canonical = pairResponseCanonical(
    request.sourceInstanceID,
    response.serverSourceInstanceID,
    response.keyID,
    response.deviceName || "Mac",
    encodeBase64URL(clientNonce),
    encodeBase64URL(serverNonce),
  );
  const expected = hmac(secret, canonical);
  if (!timingSafeEqual(proof, expected)) throw new Error("Mac pairing proof did not match");
  const key = Buffer.from(
    hkdfSync(
      "sha256",
      secret,
      Buffer.concat([clientNonce, serverNonce]),
      Buffer.from("TokenRemain Direct Sync v1", "utf8"),
      32,
    ),
  );
  return {
    key,
    keyID: response.keyID,
    serverSourceInstanceID: response.serverSourceInstanceID,
    deviceName: response.deviceName || "Mac",
  };
}

export function sealSnapshot(snapshot, { key, keyID, nonce = randomBytes(12) }) {
  validateSnapshotHeader(snapshot);
  if (!Buffer.isBuffer(key) || key.length !== 32) throw new Error("Invalid sync key");
  const plaintext = Buffer.from(stableStringify(snapshot), "utf8");
  if (plaintext.length > 20 * 1024) throw new Error("Snapshot is too large");
  const aad = makeAAD({
    envelopeVersion: 1,
    keyID,
    sourceInstanceID: snapshot.sourceInstanceID,
    sequence: snapshot.sequence,
    generatedAt: snapshot.generatedAt,
    containerID: DIRECT_SYNC_CONTEXT,
  });
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(aad);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const combined = Buffer.concat([nonce, ciphertext, cipher.getAuthTag()]);
  return {
    envelopeVersion: 1,
    generatedAt: snapshot.generatedAt,
    keyID,
    sealedPayload: combined.toString("base64"),
    sequence: snapshot.sequence,
    sourceInstanceID: snapshot.sourceInstanceID,
  };
}

export function openEnvelope(envelope, { key, expectedKeyID }) {
  validateEnvelope(envelope, expectedKeyID);
  const combined = Buffer.from(envelope.sealedPayload, "base64");
  if (combined.length < 29 || combined.length > 20 * 1024 + 28) throw new Error("Malformed encrypted payload");
  const nonce = combined.subarray(0, 12);
  const tag = combined.subarray(combined.length - 16);
  const ciphertext = combined.subarray(12, combined.length - 16);
  const aad = makeAAD({
    envelopeVersion: envelope.envelopeVersion,
    keyID: envelope.keyID,
    sourceInstanceID: envelope.sourceInstanceID,
    sequence: envelope.sequence,
    generatedAt: envelope.generatedAt,
    containerID: DIRECT_SYNC_CONTEXT,
  });
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(aad);
  decipher.setAuthTag(tag);
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  const snapshot = JSON.parse(plaintext.toString("utf8"));
  validateSnapshotHeader(snapshot);
  if (
    snapshot.sourceInstanceID.toLowerCase() !== envelope.sourceInstanceID.toLowerCase() ||
    snapshot.sequence !== envelope.sequence ||
    snapshot.generatedAt !== envelope.generatedAt
  ) {
    throw new Error("Envelope and snapshot headers do not match");
  }
  validateConsumedSnapshot(snapshot);
  return snapshot;
}

export function encodeEnvelope(envelope) {
  const data = Buffer.from(stableStringify(envelope), "utf8");
  if (data.length > MAX_ENVELOPE_BYTES) throw new Error("Envelope is too large");
  return data;
}

export function newSourceID() {
  return randomUUID().toLowerCase();
}

export function makeSnapshot({ sourceInstanceID, sequence, providers, now = Date.now() }) {
  return {
    aggregateUsage: undefined,
    curatedFeed: undefined,
    dailyUsageHistory: undefined,
    expiresAt: now + 24 * 60 * 60 * 1000,
    generatedAt: now,
    providers: providers.map((provider) => {
      const windows = provider.windows.map(windowForWire);
      const scopedCapacity = Math.max(0, 8 - windows.length);
      const scopedWindows = provider.scopedWindows?.flatMap((scoped) => {
        const scopeID = typeof scoped.scopeID === "string" ? scoped.scopeID.toLowerCase() : "";
        if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(scopeID) || sanitizePlanName(scoped.displayName) !== scoped.displayName) return [];
        return [{ scopeID, displayName: scoped.displayName, window: windowForWire(scoped.window) }];
      }).slice(0, scopedCapacity);
      return {
        capturedAt: provider.capturedAt,
        planName: sanitizePlanName(provider.planName),
        providerID: provider.providerID,
        scopedWindows: scopedWindows?.length ? scopedWindows : undefined,
        statusCode: "available",
        windows,
      };
    }),
    schemaVersion: 1,
    sequence,
    sourceInstanceID,
  };
}

export function stableStringify(value) {
  return JSON.stringify(sortValue(value));
}

function sortValue(value) {
  if (Array.isArray(value)) return value.map(sortValue);
  if (value && typeof value === "object" && !Buffer.isBuffer(value)) {
    return Object.keys(value)
      .filter((key) => value[key] !== undefined)
      .sort()
      .reduce((result, key) => {
        result[key] = sortValue(value[key]);
        return result;
      }, {});
  }
  return value;
}

function makeAAD({ envelopeVersion, keyID, sourceInstanceID, sequence, generatedAt, containerID }) {
  const values = [
    uint32(envelopeVersion),
    uuidBytes(keyID),
    uuidBytes(sourceInstanceID),
    uint64(sequence),
    int64(generatedAt),
    Buffer.from(containerID, "utf8"),
  ];
  const chunks = [Buffer.from("TRSYNC-AAD-1", "utf8")];
  for (const value of values) {
    const length = Buffer.alloc(4);
    length.writeUInt32BE(value.length);
    chunks.push(length, value);
  }
  return Buffer.concat(chunks);
}

function uint32(value) {
  const result = Buffer.alloc(4);
  result.writeUInt32BE(value);
  return result;
}

function uint64(value) {
  const result = Buffer.alloc(8);
  result.writeBigUInt64BE(BigInt(value));
  return result;
}

function int64(value) {
  const result = Buffer.alloc(8);
  result.writeBigInt64BE(BigInt(Math.trunc(value)));
  return result;
}

function uuidBytes(value) {
  const normalized = String(value).replaceAll("-", "");
  if (!/^[0-9a-fA-F]{32}$/.test(normalized)) throw new Error("Invalid UUID");
  return Buffer.from(normalized, "hex");
}

function hmac(secret, canonical) {
  return createHmac("sha256", secret).update(canonical, "utf8").digest();
}

function pairRequestCanonical(sourceInstanceID, deviceName, clientNonce) {
  return `TR-DIRECT-PAIR-REQUEST-1\n${sourceInstanceID.toLowerCase()}\n${deviceName}\n${clientNonce}`;
}

function pairResponseCanonical(clientID, serverID, keyID, serverDeviceName, clientNonce, serverNonce) {
  return `TR-DIRECT-PAIR-RESPONSE-1\n${clientID.toLowerCase()}\n${serverID.toLowerCase()}\n${keyID.toLowerCase()}\n${serverDeviceName}\n${clientNonce}\n${serverNonce}`;
}

function normalizeDeviceName(value) {
  const name = String(value || "Windows PC").trim().replace(/[\r\n\t]/g, " ");
  if (!name || Buffer.byteLength(name) > 64) throw new Error("Device name must be 1–64 bytes");
  return name;
}

function sanitizePlanName(value) {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (!trimmed || Buffer.byteLength(trimmed) > 64 || /[@/\\:\x00-\x1f\x7f]/.test(trimmed)) return undefined;
  return trimmed;
}

function sanitizePoolName(value) {
  const sanitized = sanitizePlanName(value);
  return sanitized && Buffer.byteLength(sanitized) <= 48 ? sanitized : undefined;
}

function windowForWire(window) {
  return { ...window, poolName: sanitizePoolName(window?.poolName) };
}

function validateEnvelope(envelope, expectedKeyID) {
  if (envelope?.envelopeVersion !== 1) throw new Error("Unsupported encrypted envelope");
  if (expectedKeyID && envelope.keyID.toLowerCase() !== expectedKeyID.toLowerCase()) throw new Error("Unexpected sync key");
  if (!Number.isSafeInteger(envelope.sequence) || envelope.sequence < 1) throw new Error("Invalid sequence");
  if (!Number.isFinite(envelope.generatedAt)) throw new Error("Invalid envelope date");
}

function validateSnapshotHeader(snapshot) {
  if (snapshot?.schemaVersion !== 1) throw new Error("Unsupported snapshot version");
  uuidBytes(snapshot.sourceInstanceID);
  if (!Number.isSafeInteger(snapshot.sequence) || snapshot.sequence < 1) throw new Error("Invalid snapshot sequence");
  if (!Number.isFinite(snapshot.generatedAt) || !Number.isFinite(snapshot.expiresAt)) throw new Error("Invalid snapshot dates");
}

function validateConsumedSnapshot(snapshot) {
  const now = Date.now();
  if (snapshot.generatedAt > now + 5 * 60 * 1000) throw new Error("Snapshot is from the future");
  if (snapshot.expiresAt < now || snapshot.expiresAt - snapshot.generatedAt > 24 * 60 * 60 * 1000) throw new Error("Snapshot expired");
  if (!Array.isArray(snapshot.providers) || snapshot.providers.length > 32) throw new Error("Invalid providers");
  for (const provider of snapshot.providers) {
    if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(provider.providerID || "")) throw new Error("Invalid provider ID");
    if (!Number.isFinite(provider.capturedAt) || provider.capturedAt > now + 5 * 60 * 1000) throw new Error("Invalid provider date");
    if (!Array.isArray(provider.windows)) throw new Error("Invalid quota windows");
    const scopedCount = provider.scopedWindows === undefined ? 0 : Array.isArray(provider.scopedWindows) ? provider.scopedWindows.length : Infinity;
    if (provider.windows.length + scopedCount > 8) throw new Error("Invalid quota windows");
    const windowMinutes = new Set();
    for (const window of provider.windows) {
      validateWindow(window, now);
      if (windowMinutes.has(window.windowMinutes)) throw new Error("Duplicate quota window");
      windowMinutes.add(window.windowMinutes);
    }
    if (provider.scopedWindows !== undefined) {
      if (!Array.isArray(provider.scopedWindows)) throw new Error("Invalid scoped quota windows");
      const scopeIDs = new Set();
      for (const scoped of provider.scopedWindows) {
        if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(scoped?.scopeID || "") || scopeIDs.has(scoped.scopeID)) throw new Error("Invalid quota scope");
        scopeIDs.add(scoped.scopeID);
        if (sanitizePlanName(scoped.displayName) !== scoped.displayName) throw new Error("Invalid quota scope name");
        validateWindow(scoped.window, now);
      }
    }
  }
  validateDailyUsageHistory(snapshot.dailyUsageHistory, now);
}

function validateWindow(window, now) {
  if (!Number.isFinite(window?.usedPercent) || window.usedPercent < 0 || window.usedPercent > 100) throw new Error("Invalid quota percent");
  if (!Number.isInteger(window.windowMinutes) || window.windowMinutes < 0 || window.windowMinutes > 525600) throw new Error("Invalid quota duration");
  if (window.resetsAt !== undefined && window.resetsAt !== null) {
    if (!Number.isFinite(window.resetsAt) || Math.abs(window.resetsAt - now) > 366 * 24 * 60 * 60 * 1000) {
      throw new Error("Invalid quota reset date");
    }
  }
  if (window.remainingBalance !== undefined && window.remainingBalance !== null) {
    const { amount, currencyCode } = window.remainingBalance;
    if (!Number.isFinite(amount) || amount < 0 || typeof currencyCode !== "string" || !/^[A-Za-z0-9]{1,12}$/.test(currencyCode)) {
      throw new Error("Invalid quota balance");
    }
  }
  if (window.poolName !== undefined && sanitizePoolName(window.poolName) !== window.poolName) {
    throw new Error("Invalid quota pool name");
  }
}

function validateDailyUsageHistory(history, now) {
  if (history === undefined || history === null) return;
  if (!Array.isArray(history.days) || history.days.length > 30) throw new Error("Invalid daily usage history");
  if (!Number.isFinite(history.capturedAt) || history.capturedAt > now + 5 * 60 * 1000) throw new Error("Invalid history date");
  const earliest = utcDayKey(now - 30 * 24 * 60 * 60 * 1000);
  const latest = utcDayKey(now + 24 * 60 * 60 * 1000);
  if (history.sourceDay !== undefined) validateDayKey(history.sourceDay, earliest, latest);
  let previous;
  for (const day of history.days) {
    validateDayKey(day?.day, earliest, latest);
    if (previous !== undefined && previous >= day.day) throw new Error("Daily usage days must be sorted and unique");
    previous = day.day;
    for (const key of ["claudeTokens", "codexTokens"]) {
      if (!Number.isSafeInteger(day[key]) || day[key] < 0 || day[key] > 1_000_000_000_000_000) throw new Error("Invalid daily token total");
    }
    for (const key of ["claudeCost", "codexCost"]) {
      if (!Number.isFinite(day[key]) || day[key] < 0 || day[key] > 1_000_000) throw new Error("Invalid daily cost total");
    }
  }
}

function validateDayKey(value, earliest, latest) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error("Invalid daily usage day");
  const parsed = Date.parse(`${value}T00:00:00.000Z`);
  if (!Number.isFinite(parsed) || utcDayKey(parsed) !== value || value < earliest || value > latest) throw new Error("Invalid daily usage day");
}

function utcDayKey(value) {
  return new Date(value).toISOString().slice(0, 10);
}
