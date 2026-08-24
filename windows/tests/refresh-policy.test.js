import assert from "node:assert/strict";
import test from "node:test";
import {
  nextRefreshDelayMs,
  providerRetryDelayMs,
  providerRetryState,
} from "../electron/refresh-policy.js";

test("Default cadence is five minutes", () => {
  assert.equal(nextRefreshDelayMs(), 300_000);
});

test("Each supported preference maps to its requested cadence", () => {
  for (const [minutes, expected] of [[1, 60_000], [5, 300_000], [15, 900_000], [30, 1_800_000]]) {
    assert.equal(nextRefreshDelayMs({ userIntervalMinutes: minutes, anyWindowVisible: true }), expected);
  }
});

test("Manual-only disables automatic refresh even after provider failures", () => {
  assert.equal(nextRefreshDelayMs({
    userIntervalMinutes: 0,
    providerFailureCounts: { codex: 3 },
  }), null);
});

test("A hidden app stretches a short cadence after five idle minutes", () => {
  assert.equal(nextRefreshDelayMs({ userIntervalMinutes: 1, systemIdleSeconds: 299 }), 60_000);
  assert.equal(nextRefreshDelayMs({ userIntervalMinutes: 1, systemIdleSeconds: 300 }), 300_000);
  assert.equal(nextRefreshDelayMs({ userIntervalMinutes: 15, systemIdleSeconds: 300 }), 900_000);
});

test("A visible window keeps the selected cadence regardless of system idle time", () => {
  assert.equal(nextRefreshDelayMs({
    userIntervalMinutes: 1,
    anyWindowVisible: true,
    systemIdleSeconds: 3_600,
  }), 60_000);
});

test("Provider failure backoff grows independently, caps, and resets", () => {
  assert.equal(providerRetryDelayMs(0), 0);
  assert.equal(providerRetryDelayMs(1), 60_000);
  assert.equal(providerRetryDelayMs(2), 120_000);
  assert.equal(providerRetryDelayMs(3), 240_000);
  assert.equal(providerRetryDelayMs(4), 300_000);
  assert.equal(providerRetryDelayMs(9), 300_000);

  const failed = providerRetryState(2, true, 1_000);
  assert.deepEqual(failed, { failureCount: 3, retryAfter: 241_000 });
  assert.deepEqual(providerRetryState(failed.failureCount, false, 2_000), { failureCount: 0, retryAfter: 0 });

  assert.equal(nextRefreshDelayMs({
    userIntervalMinutes: 30,
    anyWindowVisible: true,
    providerFailureCounts: { codex: 2 },
  }), 120_000);
});
