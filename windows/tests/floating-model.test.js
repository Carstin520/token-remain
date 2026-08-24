import assert from "node:assert/strict";
import test from "node:test";
import {
  FLOATING_RING_GEOMETRY,
  enabledQuotaProviders,
  floatingLabel,
  floatingProviderSummary,
  floatingRings,
  rankFloatingProviders,
  ringArc,
} from "../src/floating-model.js";
import { providerMeta } from "../src/provider-meta.js";

const NOW = Date.UTC(2026, 7, 21, 12, 0, 0);
const DAY = new Date(NOW).toISOString().slice(0, 10);

function usage(agents) {
  return { sourceDay: DAY, capturedAt: NOW, days: [{ day: DAY, agents }] };
}

function quota(providerID, usedPercent, windowMinutes = 300) {
  return { providerID, windows: [{ usedPercent, windowMinutes, resetsAt: NOW + 60_000 }] };
}

test("Floating rings rank the providers with the most local usage today", () => {
  const state = {
    enabledProviders: ["claude", "codex", "cursor"],
    providers: [quota("claude", 20), quota("codex", 45), quota("cursor", 70)],
    dailyUsageHistory: usage([
      { id: "cursor", tokens: 900_000, cost: 1.2 },
      { id: "codex", tokens: 400_000, cost: 0.6 },
      { id: "claude", tokens: 10_000, cost: 0.02 },
    ]),
  };
  assert.deepEqual(rankFloatingProviders(state, NOW), ["cursor", "codex"]);
  const { rings, lowest } = floatingRings(state, NOW);
  assert.deepEqual(rings.map((ring) => ring.providerID), ["cursor", "codex"]);
  assert.deepEqual(rings.map((ring) => ring.remaining), [30, 55]);
  assert.equal(lowest, 30);
});

test("Floating rings fall back to quota-only ranking when nothing was used today", () => {
  const state = {
    enabledProviders: ["cursor", "codex", "claude"],
    providers: [quota("cursor", 70), quota("codex", 45), quota("claude", 20)],
  };
  // No usage digest at all: Claude and Codex lead, exactly like the Dashboard's
  // Official Quota block, rather than following the snapshot array order.
  assert.deepEqual(rankFloatingProviders(state, NOW), ["claude", "codex"]);
  const empty = { ...state, dailyUsageHistory: usage([]) };
  assert.deepEqual(rankFloatingProviders(empty, NOW), ["claude", "codex"]);
});

test("Floating rings draw a single ring when only one provider qualifies", () => {
  const state = {
    enabledProviders: ["codex"],
    providers: [quota("codex", 38)],
    dailyUsageHistory: usage([{ id: "codex", tokens: 500_000, cost: 0.7 }]),
  };
  const { rings, lowest } = floatingRings(state, NOW);
  assert.equal(rings.length, 1);
  assert.equal(rings[0].providerID, "codex");
  assert.equal(rings[0].remaining, 62);
  // The lone ring takes the outer track; there is no inner placeholder.
  assert.equal(rings[0].radius, FLOATING_RING_GEOMETRY[0].radius);
  assert.equal(lowest, 62);
});

test("Floating rings report nothing when no provider has a snapshot", () => {
  assert.deepEqual(floatingRings(undefined, NOW), { rings: [], lowest: undefined });
  assert.deepEqual(floatingRings({ enabledProviders: [], providers: [] }, NOW), { rings: [], lowest: undefined });
  // A provider that is enabled but has not reported a window yet stays off.
  const pending = floatingRings({ enabledProviders: ["codex"], providers: [{ providerID: "codex", windows: [] }] }, NOW);
  assert.deepEqual(pending, { rings: [], lowest: undefined });
  assert.equal(floatingLabel(pending.lowest), "—");
});

test("Floating rings exclude providers the user disabled", () => {
  const state = {
    enabledProviders: ["codex"],
    providers: [quota("claude", 10), quota("codex", 38)],
    dailyUsageHistory: usage([{ id: "claude", tokens: 900_000, cost: 1 }, { id: "codex", tokens: 100_000, cost: 0.2 }]),
  };
  assert.deepEqual(enabledQuotaProviders(state).map((provider) => provider.providerID), ["codex"]);
  const { rings, lowest } = floatingRings(state, NOW);
  assert.deepEqual(rings.map((ring) => ring.providerID), ["codex"]);
  assert.equal(lowest, 62);
});

test("Floating rings honour the summary-window strategy", () => {
  const provider = {
    providerID: "claude",
    windows: [
      { usedPercent: 20, windowMinutes: 300, resetsAt: NOW + 60_000 },
      { usedPercent: 85, windowMinutes: 10_080, resetsAt: NOW + 600_000 },
    ],
  };
  const state = { enabledProviders: ["claude"], providers: [provider] };
  assert.equal(floatingRings(state, NOW).rings[0].remaining, 80);
  assert.equal(floatingRings({ ...state, summaryStrategy: "lowestRemaining" }, NOW).rings[0].remaining, 15);
});

test("Floating rings carry each provider's own muted identity colour", () => {
  const state = {
    enabledProviders: ["cursor", "copilot"],
    providers: [quota("cursor", 38), quota("copilot", 62)],
    dailyUsageHistory: usage([{ id: "cursor", tokens: 640_000, cost: 1 }, { id: "copilot", tokens: 220_000, cost: 0.3 }]),
  };
  const { rings } = floatingRings(state, NOW);
  assert.deepEqual(rings.map((ring) => ring.color), [providerMeta("cursor").color, providerMeta("copilot").color]);
  assert.deepEqual(rings.map((ring) => ring.name), ["Cursor", "Copilot"]);
  assert.deepEqual(rings.map((ring) => ring.remaining), [62, 38]);
  assert.notEqual(rings[0].color, providerMeta("claude").color);
});

test("Floating ring order is stable across repeated builds", () => {
  const state = {
    enabledProviders: ["claude", "codex"],
    providers: [quota("claude", 50), quota("codex", 50)],
    dailyUsageHistory: usage([{ id: "codex", tokens: 100, cost: 0 }, { id: "claude", tokens: 100, cost: 0 }]),
  };
  const first = floatingRings(state, NOW).rings.map((ring) => ring.providerID);
  assert.deepEqual(floatingRings(state, NOW).rings.map((ring) => ring.providerID), first);
  assert.deepEqual(floatingRings({ ...state, providers: [...state.providers].reverse() }, NOW)
    .rings.map((ring) => ring.providerID), first);
});

test("Ring arcs map remaining percent onto the stroke dash", () => {
  const radius = FLOATING_RING_GEOMETRY[0].radius;
  const circumference = 2 * Math.PI * radius;
  const full = ringArc(100, radius);
  assert.equal(full.gap, circumference);
  assert.ok(Math.abs(full.dash - 0.988 * circumference) < 1e-9);
  const partial = ringArc(60, radius);
  assert.ok(Math.abs(partial.dash - 0.588 * circumference) < 1e-9);
  // A 60% arc must be visibly shorter than a full circle — the bug this fixes.
  assert.ok(partial.dash < full.dash * 0.62);
  assert.equal(ringArc(0, radius).dash, 0);
  assert.equal(ringArc(undefined, radius).dash, 0);
  assert.equal(ringArc(-40, radius).dash, 0);
  assert.ok(Math.abs(ringArc(400, radius).dash - full.dash) < 1e-9);
  assert.ok(full.offset < 0);
});

test("Accessible summary lists only the providers on screen", () => {
  const rings = [{ providerID: "cursor", name: "Cursor", remaining: 62 }, { providerID: "copilot", name: "Copilot", remaining: 38 }];
  assert.equal(floatingProviderSummary(rings), "Cursor 62%, Copilot 38%");
  assert.equal(floatingProviderSummary(rings, "、"), "Cursor 62%、Copilot 38%");
  assert.equal(floatingProviderSummary([rings[0]]), "Cursor 62%");
  assert.equal(floatingProviderSummary([]), "");
});

test("Centre label shows the lowest remaining percent or an em dash", () => {
  assert.equal(floatingLabel(0), "0%");
  assert.equal(floatingLabel(62), "62%");
  assert.equal(floatingLabel(undefined), "—");
  assert.equal(floatingLabel(Number.NaN), "—");
});
