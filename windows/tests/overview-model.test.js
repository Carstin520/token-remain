import assert from "node:assert/strict";
import test from "node:test";
import {
  buildOverviewSummary,
  buildRiskNotes,
  buildTodayUsage,
  riskLevel,
  trackedProviderCount,
  usagePace,
} from "../src/overview-model.js";

test("Overview summary selects the tightest quota and earliest future reset", () => {
  const now = 1_000_000;
  const summary = buildOverviewSummary([
    { providerID: "claude", windows: [{ usedPercent: 43, windowMinutes: 300, resetsAt: now + 10_000 }, { usedPercent: 18, windowMinutes: 10_080, resetsAt: now + 80_000 }] },
    { providerID: "codex", windows: [{ usedPercent: 63, windowMinutes: 300, resetsAt: now + 40_000 }] },
  ], now);
  assert.equal(summary.tightest.providerID, "codex");
  assert.equal(summary.tightest.remaining, 37);
  assert.equal(summary.nextReset.providerID, "claude");
  assert.equal(summary.nextReset.resetsAt, now + 10_000);
  assert.equal(summary.trackedCount, 2);
  assert.equal(summary.risk, "low");
});

test("Overview summary rejects expired resets and bounds remaining percent", () => {
  const now = 1_000_000;
  const summary = buildOverviewSummary([
    { providerID: "claude", windows: [{ usedPercent: 140, windowMinutes: 300, resetsAt: now - 1 }] },
  ], now);
  assert.equal(summary.tightest.remaining, 0);
  assert.equal(summary.nextReset, undefined);
  assert.equal(summary.trackedCount, 1);
  assert.equal(summary.risk, "high");
});

test("Risk thresholds match macOS and projected depletion escalates to medium", () => {
  assert.equal(riskLevel(undefined), undefined);
  assert.equal(riskLevel(9.9), "high");
  assert.equal(riskLevel(10), "medium");
  assert.equal(riskLevel(29.9), "medium");
  assert.equal(riskLevel(30), "low");
  assert.equal(riskLevel(80, true), "medium");
  assert.equal(trackedProviderCount([
    { providerID: "claude", windows: [] },
    { providerID: "codex", windows: [{ usedPercent: 10 }] },
  ]), 1);
});

test("Usage pace ports the Swift window projection without reintroducing an in prefix", () => {
  const now = 2_000_000_000;
  const pace = usagePace({ usedPercent: 63, windowMinutes: 300, resetsAt: now + 3 * 60 * 60_000 }, now);
  assert.equal(pace.status, "deficit");
  assert.equal(pace.willLastUntilReset, false);
  assert.ok(pace.estimatedRunOutAt > now);
  assert.equal(usagePace({ usedPercent: 1, windowMinutes: 300, resetsAt: now + 4.9 * 60 * 60_000 }, now), undefined);
  assert.equal(usagePace({ usedPercent: 50, windowMinutes: 0, resetsAt: now + 1_000 }, now), undefined);
  const notes = buildRiskNotes([{ providerID: "codex", windows: [{ usedPercent: 63, windowMinutes: 300, resetsAt: now + 3 * 60 * 60_000 }] }], now);
  assert.equal(notes.level, "medium");
  assert.match(notes.summary, /run out after /);
  assert.doesNotMatch(notes.summary, /run out in /);
  const summary = buildOverviewSummary([
    { providerID: "claude", windows: [{ usedPercent: 63, windowMinutes: 300, resetsAt: now + 3 * 60 * 60_000 }] },
    { providerID: "codex", windows: [{ usedPercent: 80, windowMinutes: 300 }] },
  ], now);
  assert.equal(summary.tightest.providerID, "codex");
  assert.equal(summary.riskNotes.window.providerID, "claude");
});

test("Today usage selects the source Mac day and does not claim zero cost as free", () => {
  const history = {
    sourceDay: "2026-08-03",
    capturedAt: Date.parse("2026-08-04T07:00:00Z"),
    days: [
      { day: "2026-08-03", claudeTokens: 10, claudeCost: 0, codexTokens: 30, codexCost: 2.5 },
      { day: "2026-08-04", claudeTokens: 99, claudeCost: 9, codexTokens: 99, codexCost: 9 },
    ],
  };
  const today = buildTodayUsage(history, Date.parse("2026-08-04T07:00:00Z"));
  assert.equal(today.dayKey, "2026-08-03");
  assert.equal(today.totalTokens, 40);
  assert.equal(today.totalCost, undefined);
  assert.equal(buildTodayUsage({ ...history, sourceDay: "2026-08-02" }).entries.length, 0);
});
