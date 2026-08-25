export const DEFAULT_REFRESH_MINUTES = 5;
export const REFRESH_MINUTE_CHOICES = Object.freeze([1, 5, 15, 30, 0]);

const REFRESH_MINUTE_SET = new Set(REFRESH_MINUTE_CHOICES);
const IDLE_THRESHOLD_SECONDS = 5 * 60;
const IDLE_INTERVAL_MS = 5 * 60_000;
const RETRY_BASE_MS = 60_000;
const RETRY_MAXIMUM_MS = 5 * 60_000;
const ESCALATED_RETRY_MAXIMUM_MS = 30 * 60_000;
const STANDARD_RETRY_FAILURE_THRESHOLD = 4;

export function isRefreshMinutes(value) {
  return Number.isInteger(value) && REFRESH_MINUTE_SET.has(value);
}

export function normalizeRefreshMinutes(value) {
  return isRefreshMinutes(value) ? value : DEFAULT_REFRESH_MINUTES;
}

export function providerRetryDelayMs(failureCount) {
  if (!Number.isFinite(failureCount) || failureCount <= 0) return 0;
  const failures = Math.floor(failureCount);
  if (failures <= STANDARD_RETRY_FAILURE_THRESHOLD) {
    const exponent = Math.min(failures - 1, 8);
    return Math.min(RETRY_BASE_MS * (2 ** exponent), RETRY_MAXIMUM_MS);
  }
  // The normal 60/120/240/300-second curve remains cheap for intermittent
  // failures. Once a provider would otherwise be stuck retrying every five
  // minutes forever, apply the macOS escalated curve from that five-minute
  // base: 10, 20, then at most 30 minutes.
  return escalatedRetryDelayMs(RETRY_MAXIMUM_MS, failures - STANDARD_RETRY_FAILURE_THRESHOLD + 1);
}

export function escalatedRetryDelayMs(baseDelayMs, consecutiveFailures) {
  const base = Number(baseDelayMs);
  if (!Number.isFinite(base) || base <= 0) return 0;
  const failures = Math.max(0, Math.floor(Number(consecutiveFailures) || 0));
  if (failures <= 1) return base;
  const exponent = Math.min(failures - 1, 4);
  return Math.min(base * (2 ** exponent), ESCALATED_RETRY_MAXIMUM_MS);
}

export function providerRetryState(previousFailureCount, failed, now = Date.now()) {
  if (!failed) return { failureCount: 0, retryAfter: 0 };
  const failureCount = Math.min(Math.max(0, Math.floor(Number(previousFailureCount) || 0)) + 1, 9);
  return { failureCount, retryAfter: now + providerRetryDelayMs(failureCount) };
}

export function nextRefreshDelayMs({
  userIntervalMinutes = DEFAULT_REFRESH_MINUTES,
  anyWindowVisible = false,
  localSessionActive = false,
  systemIdleSeconds = 0,
  providerFailureCounts = {},
} = {}) {
  const refreshMinutes = normalizeRefreshMinutes(userIntervalMinutes);
  if (refreshMinutes === 0) return null;

  const baseDelay = refreshMinutes * 60_000;
  const cadenceDelay = anyWindowVisible || localSessionActive
    ? Math.min(baseDelay, RETRY_BASE_MS)
    : systemIdleSeconds >= IDLE_THRESHOLD_SECONDS
      ? Math.max(baseDelay, IDLE_INTERVAL_MS)
      : baseDelay;
  const retryDelays = Object.values(providerFailureCounts)
    .map(providerRetryDelayMs)
    .filter((delay) => delay > 0);
  return Math.min(cadenceDelay, ...retryDelays);
}
