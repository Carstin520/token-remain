const GITHUB_OWNER = "Carstin520";
const GITHUB_REPOSITORY = "token-remain";
const LATEST_RELEASE_ENDPOINT = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPOSITORY}/releases/latest`;
const MAX_RESPONSE_BYTES = 64 * 1024;
const MAX_ETAG_LENGTH = 256;
const MAX_FAILURE_COUNT = 3;
const HOUR_MS = 60 * 60_000;

const OUTCOME_INTERVALS = {
  "no-update": 6 * HOUR_MS,
  "update-available": 12 * HOUR_MS,
};
const FAILURE_INTERVALS = [1 * HOUR_MS, 3 * HOUR_MS, 6 * HOUR_MS];

export function parseVersionCore(value) {
  if (typeof value !== "string" || value.length > 128) return undefined;
  const match = /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:[-+][0-9A-Za-z.-]+)?$/.exec(value.trim());
  if (!match) return undefined;
  const core = match.slice(1, 4).map(Number);
  return core.every(Number.isSafeInteger) ? core : undefined;
}

export function compareVersionCores(left, right) {
  const leftCore = parseVersionCore(left);
  const rightCore = parseVersionCore(right);
  if (!leftCore || !rightCore) return undefined;
  for (let index = 0; index < leftCore.length; index += 1) {
    if (leftCore[index] < rightCore[index]) return -1;
    if (leftCore[index] > rightCore[index]) return 1;
  }
  return 0;
}

export function isDue({ lastCheckedAt, outcome = "no-update", failureCount = 0, now = Date.now() } = {}) {
  if (!Number.isSafeInteger(lastCheckedAt) || lastCheckedAt <= 0 || lastCheckedAt > now) return true;
  const failures = boundedFailureCount(failureCount);
  const interval = outcome === "failure"
    ? FAILURE_INTERVALS[Math.max(0, failures - 1)]
    : OUTCOME_INTERVALS[outcome];
  if (!Number.isFinite(interval)) return true;
  return now - lastCheckedAt >= interval;
}

export function isAllowedReleaseURL(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.hostname.toLowerCase() !== "github.com") return false;
    if (url.username || url.password || url.port || url.search || url.hash) return false;
    const path = url.pathname.replace(/\/$/, "");
    const prefix = `/${GITHUB_OWNER}/${GITHUB_REPOSITORY}/releases`;
    if (path.toLowerCase() === prefix.toLowerCase()) return true;
    if (path.toLowerCase() === `${prefix}/latest`.toLowerCase()) return true;
    const match = new RegExp(`^${escapeRegExp(prefix)}/tag/([0-9A-Za-z][0-9A-Za-z._+-]{0,127})$`, "i").exec(path);
    return Boolean(match);
  } catch {
    return false;
  }
}

export function validateReleasePayload(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("Latest release payload is malformed");
  }
  const tagName = boundedText(payload.tag_name, 128, "release tag");
  const core = parseVersionCore(tagName);
  if (!core) throw new Error("Latest release tag is malformed");
  const url = boundedText(payload.html_url, 512, "release URL");
  if (!isAllowedReleaseURL(url)) throw new Error("Latest release URL is not allowed");
  const parsedURL = new URL(url);
  const tagFromURL = parsedURL.pathname.split("/").filter(Boolean).at(-1);
  if (!parsedURL.pathname.toLowerCase().includes("/releases/tag/") || tagFromURL !== tagName) {
    throw new Error("Latest release URL does not match its tag");
  }
  return { version: core.join("."), tagName, url };
}

export function normalizeUpdateCheckState(value, { now = Date.now() } = {}) {
  const input = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  const lastCheckedAt = Number.isSafeInteger(input.lastCheckedAt)
    && input.lastCheckedAt > 0
    && input.lastCheckedAt <= now
    ? input.lastCheckedAt
    : undefined;
  const etag = normalizeETag(input.etag);
  const core = parseVersionCore(input.availableVersion);
  const availableVersion = core?.join(".");
  const availableURL = isAllowedReleaseURL(input.availableURL) ? String(input.availableURL) : undefined;
  return {
    ...(lastCheckedAt ? { lastCheckedAt } : {}),
    ...(etag ? { etag } : {}),
    ...(availableVersion && availableURL ? { availableVersion, availableURL } : {}),
    failureCount: boundedFailureCount(input.failureCount),
  };
}

export async function fetchLatestRelease({ fetchImpl = fetch, etag } = {}) {
  const headers = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  const normalizedETag = normalizeETag(etag);
  if (normalizedETag) headers["If-None-Match"] = normalizedETag;
  const response = await fetchImpl(LATEST_RELEASE_ENDPOINT, {
    headers,
    signal: AbortSignal.timeout(15_000),
    redirect: "error",
  });
  const responseETag = normalizeETag(response.headers?.get?.("etag")) || normalizedETag;
  if (response.status === 304) return { notModified: true, etag: responseETag };
  if (!response.ok) throw new Error(`Latest release returned ${response.status}`);
  const declaredLength = Number(response.headers?.get?.("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_RESPONSE_BYTES) {
    throw new Error("Latest release response is too large");
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > MAX_RESPONSE_BYTES) throw new Error("Latest release response is too large");
  let payload;
  try { payload = JSON.parse(new TextDecoder().decode(bytes)); }
  catch { throw new Error("Latest release returned invalid JSON"); }
  return { ...validateReleasePayload(payload), etag: responseETag };
}

function boundedFailureCount(value) {
  return Number.isSafeInteger(value) && value > 0 ? Math.min(value, MAX_FAILURE_COUNT) : 0;
}

function normalizeETag(value) {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  return text && text.length <= MAX_ETAG_LENGTH && !/[\u0000-\u001F\u007F]/.test(text) ? text : undefined;
}

function boundedText(value, maximumLength, label) {
  if (typeof value !== "string") throw new Error(`Missing ${label}`);
  const text = value.trim();
  if (!text || text.length > maximumLength || /[\u0000-\u001F\u007F]/.test(text)) throw new Error(`Invalid ${label}`);
  return text;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
