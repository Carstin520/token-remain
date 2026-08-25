import assert from "node:assert/strict";
import test from "node:test";
import {
  compactAxisValue,
  linePoints,
  niceCeiling,
  quotaTrendRows,
  stepPinnedDay,
  togglePinnedDay,
  trendDayModelBreakdown,
  unpinDay,
  usageTrendModel,
} from "../src/trends-model.js";

test("daily trend switches range and metric while keeping a single nice axis", () => {
  const days = Array.from({ length: 30 }, (_, index) => ({
    day: `2026-07-${String(index + 1).padStart(2, "0")}`,
    claudeTokens: index * 10,
    codexTokens: index * 20,
    claudeCost: index,
    codexCost: index * 2,
  }));
  const tokens = usageTrendModel({ days }, { range: 7, metric: "tokens" });
  assert.equal(tokens.days.length, 7);
  assert.equal(tokens.days.at(-1).total, 29 * 30);
  assert.equal(tokens.maximum, 1_000);

  const cost = usageTrendModel({ days }, { range: 14, metric: "cost" });
  assert.equal(cost.days.length, 14);
  assert.equal(cost.days.at(-1).total, 87);
});

test("daily trend reads dynamic ccusage agents instead of fixed Claude and Codex fields", () => {
  const history = { days: [{
    day: "2026-08-10",
    agents: [
      { id: "gemini", tokens: 75, cost: 0.25 },
      { id: "openclaw", tokens: 25, cost: 0.1 },
    ],
  }] };
  const model = usageTrendModel(history, { range: 7, metric: "tokens", providerIDs: ["gemini", "openclaw"] });
  assert.deepEqual(model.days[0].values, { gemini: 75, openclaw: 25 });
  assert.equal(model.days[0].total, 100);
});

test("axis and sparkline helpers follow the compact Mac presentation", () => {
  assert.equal(niceCeiling(438_500_000), 500_000_000);
  assert.equal(compactAxisValue(500_000_000), "500M");
  assert.equal(compactAxisValue(22.5, "cost"), "$22.5");
  assert.equal(linePoints([0, 10, 5]), "0.00,20.00 50.00,0.00 100.00,10.00");
});

test("quota rows respect provider order, range, and percentage geometry", () => {
  const now = Date.parse("2026-08-09T10:00:00Z");
  const old = now - 8 * 24 * 60 * 60_000;
  const recent = now - 60 * 60_000;
  const history = { samples: [
    { providerID: "codex", usedPercent: 10, windowMinutes: 300, capturedAt: old },
    { providerID: "codex", usedPercent: 25, windowMinutes: 300, capturedAt: recent },
    { providerID: "claude", usedPercent: 40, windowMinutes: 300, capturedAt: recent },
  ] };
  const rows = quotaTrendRows(history, [{ providerID: "claude" }, { providerID: "codex" }], 7, now);
  assert.deepEqual(rows.map((row) => row.providerID), ["claude", "codex"]);
  assert.equal(rows[1].samples.length, 1);
  assert.match(rows[0].points, /,/);
});

test("day pinning toggles, steps within bounds, and unpins", () => {
  const days = ["2026-08-23", "2026-08-24", "2026-08-25"];
  assert.equal(togglePinnedDay(undefined, days[1]), days[1]);
  assert.equal(togglePinnedDay(days[1], days[1]), undefined);
  assert.equal(stepPinnedDay(days, undefined, "left"), days[1]);
  assert.equal(stepPinnedDay(days, days[0], "left"), days[0]);
  assert.equal(stepPinnedDay(days, days[1], "right"), days[2]);
  assert.equal(stepPinnedDay(days, days[2], "right"), days[2]);
  assert.equal(stepPinnedDay([], days[1], "right"), undefined);
  assert.equal(unpinDay(), undefined);
});

test("model breakdown keeps five named rows, rolls the tail into Other, and marks missing prices", () => {
  const models = Array.from({ length: 8 }, (_, index) => ({
    id: `model-${index + 1}`,
    inputTokens: (8 - index) * 100,
    outputTokens: (8 - index) * 10,
    cacheTokens: index,
    cost: 8 - index,
    constituentCount: 1,
  }));
  const breakdown = trendDayModelBreakdown({
    day: "2026-08-25",
    agents: [{ id: "codex", tokens: 4_000, cost: 36, unpricedModels: ["model-8"], models }],
  }, ["codex"], "tokens");
  assert.equal(breakdown.groups.length, 1);
  assert.equal(breakdown.groups[0].displayName, "Codex");
  assert.deepEqual(breakdown.groups[0].rows.slice(0, 5).map((row) => row.id), [
    "model-1", "model-2", "model-3", "model-4", "model-5",
  ]);
  const other = breakdown.groups[0].rows[5];
  assert.equal(other.id, "other");
  assert.equal(other.constituentCount, 3);
  assert.equal(other.inputTokens, 600);
  assert.equal(other.outputTokens, 60);
  assert.equal(other.cacheTokens, 18);
  assert.equal(other.cost, 6);
  assert.equal(other.isUnpriced, true);
  assert.equal(breakdown.groups[0].rows.reduce((total, row) => total + row.share, 0), 1);
});

test("old persisted days without models produce the panel's unavailable state", () => {
  const breakdown = trendDayModelBreakdown({
    day: "2026-08-25",
    agents: [{ id: "codex", tokens: 200, cost: 1, unpricedModels: [] }],
  }, ["codex"], "cost");
  assert.deepEqual(breakdown, { day: "2026-08-25", groups: [] });
});
