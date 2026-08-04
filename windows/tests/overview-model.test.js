import assert from "node:assert/strict";
import test from "node:test";
import { buildOverviewSummary } from "../src/overview-model.js";

test("Overview summary selects the tightest quota and earliest future reset", () => {
  const now = 1_000_000;
  const summary = buildOverviewSummary([
    { providerID: "claude", windows: [{ usedPercent: 43, resetsAt: now + 10_000 }, { usedPercent: 18, resetsAt: now + 80_000 }] },
    { providerID: "codex", windows: [{ usedPercent: 63, resetsAt: now + 40_000 }] },
  ], now);
  assert.deepEqual(summary.tightest, { providerID: "codex", remaining: 37, resetsAt: now + 40_000 });
  assert.deepEqual(summary.nextReset, { providerID: "claude", remaining: 57, resetsAt: now + 10_000 });
});

test("Overview summary rejects expired resets and bounds remaining percent", () => {
  const now = 1_000_000;
  const summary = buildOverviewSummary([
    { providerID: "claude", windows: [{ usedPercent: 140, resetsAt: now - 1 }] },
  ], now);
  assert.equal(summary.tightest.remaining, 0);
  assert.equal(summary.nextReset, undefined);
});
