import assert from "node:assert/strict";
import test from "node:test";
import {
  buildOverviewSummary,
  buildRiskNotes,
  buildTodayUsage,
  rankOfficialQuotaProviders,
  riskLevel,
  summaryWindow,
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

test("Usage pace ports the Swift window projection and keeps the Mac's risk copy", () => {
  const now = 2_000_000_000;
  const pace = usagePace({ usedPercent: 63, windowMinutes: 300, resetsAt: now + 3 * 60 * 60_000 }, now);
  assert.equal(pace.status, "deficit");
  assert.equal(pace.willLastUntilReset, false);
  assert.ok(pace.estimatedRunOutAt > now);
  assert.equal(usagePace({ usedPercent: 1, windowMinutes: 300, resetsAt: now + 4.9 * 60 * 60_000 }, now), undefined);
  assert.equal(usagePace({ usedPercent: 50, windowMinutes: 0, resetsAt: now + 1_000 }, now), undefined);
  const notes = buildRiskNotes([{ providerID: "codex", windows: [{ usedPercent: 63, windowMinutes: 300, resetsAt: now + 3 * 60 * 60_000 }] }], now);
  assert.equal(notes.level, "medium");
  assert.equal(notes.projectedDepletion, "1 hr 10 min");
  assert.doesNotMatch(notes.projectedDepletion, /^in\b/);
  // macOS risk.summary.projected_runout: "… is projected to run out in %@, before the official reset."
  assert.match(notes.summary, /is projected to run out in .*, before the official reset/);
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

test("Summary window follows the Mac's shortest-window strategy", () => {
  assert.equal(summaryWindow(undefined), undefined);
  assert.equal(summaryWindow({ windows: [] }), undefined);
  const shortest = summaryWindow({ windows: [
    { usedPercent: 18, windowMinutes: 10_080 },
    { usedPercent: 43, windowMinutes: 300 },
  ] });
  assert.equal(shortest.windowMinutes, 300);
  // The 0-minute total sentinel only wins when nothing rolls.
  const balance = summaryWindow({ windows: [{ usedPercent: 12, windowMinutes: 0 }] });
  assert.equal(balance.windowMinutes, 0);
  const mixed = summaryWindow({ windows: [
    { usedPercent: 12, windowMinutes: 0 },
    { usedPercent: 26, windowMinutes: 44_640 },
  ] });
  assert.equal(mixed.windowMinutes, 44_640);
});

test("Official Quota ranks today's most-used providers and skips empty snapshots", () => {
  const providers = [
    { providerID: "claude", windows: [{ usedPercent: 43, windowMinutes: 300 }] },
    { providerID: "codex", windows: [{ usedPercent: 63, windowMinutes: 300 }] },
    { providerID: "cursor", windows: [{ usedPercent: 2, windowMinutes: 44_640 }] },
  ];
  // No usage ranking → Claude then Codex, the Mac fallback order.
  assert.deepEqual(rankOfficialQuotaProviders(providers), ["claude", "codex"]);
  // Codex leads today's tokens → it takes the first row.
  const today = { entries: [{ id: "codex", tokens: 30 }, { id: "claude", tokens: 10 }] };
  assert.deepEqual(rankOfficialQuotaProviders(providers, today), ["codex", "claude"]);
  // A ranked provider without any quota snapshot is skipped, not shown empty.
  const missing = rankOfficialQuotaProviders(
    [{ providerID: "codex", windows: [{ usedPercent: 63, windowMinutes: 300 }] }],
    { entries: [{ id: "claude", tokens: 99 }, { id: "codex", tokens: 1 }] },
  );
  assert.deepEqual(missing, ["codex"]);
});
