import assert from "node:assert/strict";
import test from "node:test";
import { buildOverviewSummary, riskLevel, trackedProviderCount } from "../src/overview-model.js";

test("Overview summary selects the tightest quota and earliest future reset", () => {
  const now = 1_000_000;
  const summary = buildOverviewSummary([
    { providerID: "claude", windows: [{ usedPercent: 43, resetsAt: now + 10_000 }, { usedPercent: 18, resetsAt: now + 80_000 }] },
    { providerID: "codex", windows: [{ usedPercent: 63, resetsAt: now + 40_000 }] },
  ], now);
  assert.deepEqual(summary.tightest, { providerID: "codex", remaining: 37, resetsAt: now + 40_000 });
  assert.deepEqual(summary.nextReset, { providerID: "claude", remaining: 57, resetsAt: now + 10_000 });
  assert.equal(summary.trackedCount, 2);
  assert.equal(summary.risk, "medium");
});

test("Overview summary rejects expired resets and bounds remaining percent", () => {
  const now = 1_000_000;
  const summary = buildOverviewSummary([
    { providerID: "claude", windows: [{ usedPercent: 140, resetsAt: now - 1 }] },
  ], now);
  assert.equal(summary.tightest.remaining, 0);
  assert.equal(summary.nextReset, undefined);
  assert.equal(summary.trackedCount, 1);
  assert.equal(summary.risk, "high");
});

test("Overview helpers classify risk and count only providers with quota windows", () => {
  assert.equal(riskLevel(undefined), undefined);
  assert.equal(riskLevel(24.9), "high");
  assert.equal(riskLevel(25), "medium");
  assert.equal(riskLevel(49.9), "medium");
  assert.equal(riskLevel(50), "low");
  assert.equal(trackedProviderCount([
    { providerID: "claude", windows: [] },
    { providerID: "codex", windows: [{ usedPercent: 10 }] },
  ]), 1);
});
