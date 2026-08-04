const DEFAULT_FEED_ENDPOINT = "https://api.tokenremain.com/v1/ai-feed";
const MAX_RESPONSE_BYTES = 256 * 1024;
const MAX_ITEMS = 50;
const ALLOWED_PRIORITIES = new Set(["token_reset", "major_update", "normal"]);
const ALLOWED_TIERS = new Set(["primary", "rotating"]);

export async function fetchCuratedFeed({
  fetchImpl = fetch,
  endpoint = process.env.TOKENREMAIN_BROADCAST_BASE_URL
    ? new URL("/v1/ai-feed", normalizeBaseURL(process.env.TOKENREMAIN_BROADCAST_BASE_URL))
    : new URL(DEFAULT_FEED_ENDPOINT),
  now = Date.now(),
} = {}) {
  const response = await fetchImpl(endpoint, {
    headers: { Accept: "application/json" },
    signal: AbortSignal.timeout(20_000),
    redirect: "error",
  });
  if (!response.ok) throw new Error(`Trending feed returned ${response.status}`);
  const declaredLength = Number(response.headers?.get?.("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_RESPONSE_BYTES) {
    throw new Error("Trending feed response is too large");
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > MAX_RESPONSE_BYTES) throw new Error("Trending feed response is too large");
  let payload;
  try { payload = JSON.parse(bytes.toString("utf8")); }
  catch { throw new Error("Trending feed returned invalid JSON"); }
  return decodeCuratedFeed(payload, { now });
}

export function decodeCuratedFeed(payload, { now = Date.now() } = {}) {
  if (!Array.isArray(payload?.items) || payload.items.length > MAX_ITEMS) {
    throw new Error("Trending feed payload is malformed");
  }
  return payload.items.flatMap((item) => {
    try { return [decodeItem(item, now)]; }
    catch { return []; }
  }).slice(0, 2);
}

export function isAllowedPostURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:"
      && ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].includes(url.hostname.toLowerCase())
      && /^\/[A-Za-z0-9_]{1,15}\/status\/[0-9]+\/?$/.test(url.pathname);
  } catch {
    return false;
  }
}

function decodeItem(item, now) {
  const id = boundedText(item?.id, 64);
  const text = boundedText(item?.text, 2_000);
  const username = boundedText(item?.author?.username, 15);
  const displayName = boundedText(item?.author?.displayName, 160);
  if (!/^[A-Za-z0-9_]+$/.test(username)) throw new Error("Invalid feed username");
  const publishedAt = Date.parse(item?.publishedAt);
  if (!Number.isFinite(publishedAt) || publishedAt > now + 5 * 60_000 || publishedAt < now - 15 * 24 * 60 * 60_000) {
    throw new Error("Invalid feed date");
  }
  const url = isAllowedPostURL(item?.url) ? String(item.url) : undefined;
  if (!url) throw new Error("Invalid feed URL");
  return {
    id,
    text,
    username,
    displayName,
    publishedAt,
    url,
    priority: ALLOWED_PRIORITIES.has(item?.priority) ? item.priority : "normal",
    tier: ALLOWED_TIERS.has(item?.tier) ? item.tier : "primary",
    metrics: {
      likes: boundedMetric(item?.metrics?.likes),
      reposts: boundedMetric(item?.metrics?.reposts),
      replies: boundedMetric(item?.metrics?.replies),
    },
  };
}

function boundedText(value, maximumBytes) {
  if (typeof value !== "string") throw new Error("Missing feed text");
  const text = value.trim();
  if (!text || Buffer.byteLength(text) > maximumBytes || /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(text)) {
    throw new Error("Invalid feed text");
  }
  return text;
}

function boundedMetric(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function normalizeBaseURL(value) {
  const url = new URL(String(value).trim());
  const localHTTP = url.protocol === "http:" && ["localhost", "127.0.0.1", "::1"].includes(url.hostname);
  if (url.protocol !== "https:" && !localHTTP) throw new Error("Broadcast URL must use HTTPS");
  if (url.username || url.password || url.search || url.hash) throw new Error("Broadcast URL contains unsupported fields");
  url.pathname = "/";
  return url;
}
