import assert from "node:assert/strict";
import test from "node:test";
import {
  compactAxisValue,
  linePoints,
  niceCeiling,
  quotaTrendRows,
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
