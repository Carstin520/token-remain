export const DEFAULT_REFRESH_MINUTES = 5;
export const REFRESH_MINUTE_CHOICES = Object.freeze([1, 5, 15, 30, 0]);

const REFRESH_MINUTE_SET = new Set(REFRESH_MINUTE_CHOICES);
const IDLE_THRESHOLD_SECONDS = 5 * 60;
const IDLE_INTERVAL_MS = 5 * 60_000;
const RETRY_BASE_MS = 60_000;
const RETRY_MAXIMUM_MS = 5 * 60_000;

export function isRefreshMinutes(value) {
  return Number.isInteger(value) && REFRESH_MINUTE_SET.has(value);
}

export function normalizeRefreshMinutes(value) {
  return isRefreshMinutes(value) ? value : DEFAULT_REFRESH_MINUTES;
}

export function providerRetryDelayMs(failureCount) {
  if (!Number.isFinite(failureCount) || failureCount <= 0) return 0;
  const exponent = Math.min(Math.floor(failureCount) - 1, 8);
  return Math.min(RETRY_BASE_MS * (2 ** exponent), RETRY_MAXIMUM_MS);
}

export function providerRetryState(previousFailureCount, failed, now = Date.now()) {
  if (!failed) return { failureCount: 0, retryAfter: 0 };
  const failureCount = Math.max(0, Math.floor(Number(previousFailureCount) || 0)) + 1;
  return { failureCount, retryAfter: now + providerRetryDelayMs(failureCount) };
}

export function nextRefreshDelayMs({
  userIntervalMinutes = DEFAULT_REFRESH_MINUTES,
  anyWindowVisible = false,
  systemIdleSeconds = 0,
  providerFailureCounts = {},
} = {}) {
  const refreshMinutes = normalizeRefreshMinutes(userIntervalMinutes);
  if (refreshMinutes === 0) return null;

  const baseDelay = refreshMinutes * 60_000;
  const cadenceDelay = !anyWindowVisible && systemIdleSeconds >= IDLE_THRESHOLD_SECONDS
    ? Math.max(baseDelay, IDLE_INTERVAL_MS)
    : baseDelay;
  const retryDelays = Object.values(providerFailureCounts)
    .map(providerRetryDelayMs)
    .filter((delay) => delay > 0);
  return Math.min(cadenceDelay, ...retryDelays);
}
