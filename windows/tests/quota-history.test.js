import assert from "node:assert/strict";
import test from "node:test";
import {
  QUOTA_HISTORY_BUCKET_MS,
  QUOTA_HISTORY_RETENTION_MS,
  normalizeQuotaUsageHistory,
  recordQuotaUsageHistory,
} from "../electron/quota-history.js";

const NOW = Date.parse("2026-08-09T10:00:00Z");

function provider(capturedAt, usedPercent, windows = undefined) {
  return {
    providerID: "codex",
    capturedAt,
    windows: windows || [{ usedPercent, windowMinutes: 300, resetsAt: capturedAt + 60_000 }],
  };
}

test("quota history records the shortest rolling window once per fifteen-minute bucket", () => {
  const first = recordQuotaUsageHistory(undefined, [provider(NOW, 20, [
    { usedPercent: 40, windowMinutes: 10_080 },
    { usedPercent: 20, windowMinutes: 300 },
  ])], NOW);
  assert.deepEqual(first.samples.map(({ usedPercent, windowMinutes }) => ({ usedPercent, windowMinutes })), [
    { usedPercent: 20, windowMinutes: 300 },
  ]);

  const replaced = recordQuotaUsageHistory(first, [provider(NOW + 5 * 60_000, 24)], NOW + 5 * 60_000);
  assert.equal(replaced.samples.length, 1);
  assert.equal(replaced.samples[0].usedPercent, 24);

  const appended = recordQuotaUsageHistory(replaced, [provider(NOW + QUOTA_HISTORY_BUCKET_MS, 31)], NOW + QUOTA_HISTORY_BUCKET_MS);
  assert.equal(appended.samples.length, 2);
});

test("quota history drops expired and malformed samples while bounding percentages", () => {
  const history = normalizeQuotaUsageHistory({ samples: [
    { providerID: "claude", usedPercent: 110, windowMinutes: 300, capturedAt: NOW },
    { providerID: "claude", usedPercent: 10, windowMinutes: 300, capturedAt: NOW - QUOTA_HISTORY_RETENTION_MS - 1 },
    { providerID: "bad provider", usedPercent: 10, windowMinutes: 300, capturedAt: NOW },
  ] }, NOW);
  assert.equal(history.samples.length, 1);
  assert.equal(history.samples[0].usedPercent, 100);
});
