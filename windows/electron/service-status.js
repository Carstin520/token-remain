export const PROVIDER_STATUS_ENDPOINTS = Object.freeze({
  claude: "https://status.claude.com/api/v2/summary.json",
  codex: "https://status.openai.com/api/v2/summary.json",
});

export const SERVICE_STATUS_REFRESH_INTERVAL_MS = 300_000;
export const SERVICE_STATUS_STALE_AFTER_MS = 15 * 60_000;

const MAXIMUM_RESPONSE_BYTES = 256 * 1024;
const MAXIMUM_DESCRIPTION_BYTES = 512;
const ALLOWED_INDICATORS = new Set(["none", "minor", "major", "critical"]);

export class ServiceStatusService {
  constructor({
    fetchImpl = fetch,
    refreshIntervalMs = SERVICE_STATUS_REFRESH_INTERVAL_MS,
    staleAfterMs = SERVICE_STATUS_STALE_AFTER_MS,
  } = {}) {
    this.fetchImpl = fetchImpl;
    this.refreshIntervalMs = refreshIntervalMs;
    this.staleAfterMs = staleAfterMs;
    this.statuses = new Map();
    this.lastAttemptAt = new Map();
  }

  async refreshIfNeeded(now = Date.now()) {
    const due = Object.entries(PROVIDER_STATUS_ENDPOINTS).filter(([provider]) => {
      const attemptedAt = this.lastAttemptAt.get(provider);
      return !Number.isFinite(attemptedAt) || now - attemptedAt >= this.refreshIntervalMs;
    });
    if (!due.length) return false;

    await Promise.all(due.map(async ([provider, endpoint]) => {
      this.lastAttemptAt.set(provider, now);
      try {
        const status = await fetchProviderStatus({ fetchImpl: this.fetchImpl, endpoint });
        this.statuses.set(provider, { ...status, capturedAt: now });
      } catch {
        // Keep the last validated status through brief status-page or network
        // failures. getStatuses() stops exposing it once it is too old.
      }
    }));
    return true;
  }

  getStatuses(now = Date.now()) {
    return Object.fromEntries([...this.statuses].filter(([, status]) => (
      Number.isFinite(status?.capturedAt)
      && now >= status.capturedAt
      && now - status.capturedAt < this.staleAfterMs
    )));
  }
}

export function normalizeProviderStatusPayload(payload) {
  if (!payload || Array.isArray(payload) || typeof payload !== "object") {
    throw new Error("Provider status payload is malformed");
  }
  const status = payload.status;
  if (!status || Array.isArray(status) || typeof status !== "object") {
    throw new Error("Provider status payload is malformed");
  }
  if (typeof status.indicator !== "string" || !ALLOWED_INDICATORS.has(status.indicator)) {
    throw new Error("Provider status indicator is invalid");
  }
  if (typeof status.description !== "string") throw new Error("Provider status description is invalid");
  const description = status.description.trim();
  if (!description
    || Buffer.byteLength(description, "utf8") > MAXIMUM_DESCRIPTION_BYTES
    || /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(description)) {
    throw new Error("Provider status description is invalid");
  }
  return { indicator: status.indicator, description };
}

export function isAbnormalServiceStatus(value) {
  const indicator = typeof value === "string" ? value : value?.indicator;
  return indicator === "minor" || indicator === "major" || indicator === "critical";
}

async function fetchProviderStatus({ fetchImpl, endpoint }) {
  const response = await fetchImpl(endpoint, {
    method: "GET",
    headers: { Accept: "application/json", "User-Agent": "TokenRemain/1" },
    signal: AbortSignal.timeout(15_000),
    redirect: "error",
  });
  if (!Number.isInteger(response?.status) || response.status < 200 || response.status >= 300) {
    throw new Error(`Provider status returned HTTP ${response?.status || "unknown"}`);
  }
  const declaredLength = Number(response.headers?.get?.("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAXIMUM_RESPONSE_BYTES) {
    throw new Error("Provider status response is too large");
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > MAXIMUM_RESPONSE_BYTES) throw new Error("Provider status response is too large");
  let payload;
  try { payload = JSON.parse(bytes.toString("utf8")); }
  catch { throw new Error("Provider status returned invalid JSON"); }
  return normalizeProviderStatusPayload(payload);
}
