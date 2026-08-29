export const PROVIDER_ALERT_SILENCE_MS = 24 * 60 * 60_000;
export const MAX_FEED_SEEN_IDS = 200;
const MAX_PROVIDER_SILENCES = 64;
const IMPORTANT_FEED_PRIORITIES = new Set(["token_reset", "major_update"]);

export function signInRequiredError(message) {
  const error = new Error(message);
  error.requiresSignIn = true;
  return error;
}

export function noticeFromError(error) {
  const message = error instanceof Error ? error.message : String(error);
  const requiresSignIn = error?.requiresSignIn === true || requiresSignInMessage(message);
  return {
    message,
    kind: noticeKind(error, message, requiresSignIn),
    requiresSignIn,
  };
}

export function requiresSignInNotice(notice) {
  if (notice && typeof notice === "object" && typeof notice.requiresSignIn === "boolean") {
    return notice.requiresSignIn;
  }
  const message = notice && typeof notice === "object" ? notice.message : notice;
  return requiresSignInMessage(message);
}

export function decideProviderNotifications({
  notices = {},
  attemptedProviderIDs = [],
  bookkeeping,
  now = Date.now(),
} = {}) {
  const next = normalizeNotificationBookkeeping(bookkeeping);
  const silencedAt = { ...next.providerSilencedAt };
  const providerIDs = [];

  for (const providerID of uniqueStrings(attemptedProviderIDs, MAX_PROVIDER_SILENCES)) {
    const notice = notices[providerID];
    if (!notice) {
      delete silencedAt[providerID];
      continue;
    }
    if (!requiresSignInNotice(notice)) continue;
    const previous = silencedAt[providerID];
    if (!Number.isFinite(previous) || now - previous >= PROVIDER_ALERT_SILENCE_MS || now < previous) {
      providerIDs.push(providerID);
      silencedAt[providerID] = now;
    }
  }

  return {
    providerIDs,
    bookkeeping: normalizeNotificationBookkeeping({ ...next, providerSilencedAt: silencedAt }),
  };
}

export function selectFeedNotifications({ posts = [], seenIDs = [], enabled = false, limit = 3 } = {}) {
  const previous = new Set(uniqueStrings(seenIDs, MAX_FEED_SEEN_IDS));
  const validPosts = Array.isArray(posts) ? posts.filter((post) => post && typeof post.id === "string" && post.id) : [];
  const notifications = enabled
    ? validPosts.filter((post) => !previous.has(post.id) && IMPORTANT_FEED_PRIORITIES.has(post.priority)).slice(0, Math.max(0, limit))
    : [];
  return {
    posts: notifications,
    seenIDs: uniqueStrings([...validPosts.map((post) => post.id), ...previous], MAX_FEED_SEEN_IDS),
  };
}

export function truncateNotificationBody(value, limit = 180) {
  const characters = Array.from(String(value || ""));
  return characters.length <= limit ? characters.join("") : `${characters.slice(0, Math.max(0, limit - 1)).join("")}…`;
}

export function normalizeNotificationBookkeeping(value) {
  const silences = value?.providerSilencedAt && typeof value.providerSilencedAt === "object"
    ? Object.entries(value.providerSilencedAt).filter(([providerID, timestamp]) => (
      typeof providerID === "string" && providerID.length <= 64 && Number.isFinite(timestamp) && timestamp >= 0
    )).slice(0, MAX_PROVIDER_SILENCES)
    : [];
  return {
    providerSilencedAt: Object.fromEntries(silences),
    feedSeenIDs: uniqueStrings(value?.feedSeenIDs, MAX_FEED_SEEN_IDS),
  };
}

function requiresSignInMessage(value) {
  const message = String(value || "").trim().toLowerCase();
  if (!message) return false;
  return /\b(?:not signed in|not logged in|signed out|(?:please |must )?sign in(?: again| to continue|required)?|sign-in (?:has expired|is stale|was rejected)|credential(?:s)? (?:was |were )?rejected|log in again|login required)\b/.test(message)
    || /\b(?:auth\.json has no access token|credentials contain no oauth token)\b/.test(message);
}

function noticeKind(error, message, requiresSignIn) {
  if (requiresSignIn) return "signIn";
  const status = error?.status ?? error?.statusCode ?? error?.response?.status
    ?? error?.cause?.status ?? error?.cause?.statusCode ?? error?.cause?.response?.status;
  if (Number(status) === 429 || /(?:\bHTTP\s*429\b|\(429\)|\brate[ -]?limit(?:ed)?\b|\btoo many requests\b)/i.test(message)) {
    return "rateLimit";
  }

  const name = String(error?.name || error?.cause?.name || "");
  const codes = [error?.code, error?.cause?.code].map((value) => String(value || "").toUpperCase());
  if (name === "AbortError" || name === "TimeoutError"
    || codes.includes("ETIMEDOUT")
    || /(?:net::)?ERR_(?:CONNECTION_)?TIMED_OUT\b/i.test(message)
    || /\b(?:timed out|timeout)\b/i.test(message)) {
    return "timeout";
  }
  if (codes.some((code) => ["ENOTFOUND", "ECONNRESET", "ECONNREFUSED"].includes(code))
    || /net::ERR_(?:INTERNET_DISCONNECTED|NAME_NOT_RESOLVED|CONNECTION_(?:RESET|REFUSED)|PROXY_[A-Z0-9_]+)\b/i.test(message)) {
    return "network";
  }
  return "unknown";
}

function uniqueStrings(values, limit) {
  const result = [];
  const seen = new Set();
  for (const value of Array.isArray(values) ? values : []) {
    if (typeof value !== "string" || !value || value.length > 128 || seen.has(value)) continue;
    seen.add(value);
    result.push(value);
    if (result.length >= limit) break;
  }
  return result;
}
