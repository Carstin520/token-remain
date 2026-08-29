import assert from "node:assert/strict";
import test from "node:test";
import { usageCostText, usageRingSegmentAtPoint, usageRingStops, usageShareText } from "../src/popover-usage.js";

const ENTRIES = [
  { id: "codex", tokens: 75, color: "#6687c5" },
  { id: "claude", tokens: 25, color: "#bf8471" },
];

test("usage ring stops follow provider token share from the top clockwise", () => {
  assert.equal(
    usageRingStops(ENTRIES),
    "#6687c5 0%, #6687c5 75%, #bf8471 75%, #bf8471 100%",
  );
});

test("usage ring dims only non-highlighted segments", () => {
  const stops = usageRingStops(ENTRIES, "claude");
  assert.match(stops, /color-mix\(in srgb, #6687c5 32%, transparent\) 0%/);
  assert.match(stops, /#bf8471 75%, #bf8471 100%/);
});

test("usage ring hit testing shares the rendered segment boundaries", () => {
  assert.equal(usageRingSegmentAtPoint(ENTRIES, { x: 26, y: 1 }, 52), "codex");
  assert.equal(usageRingSegmentAtPoint(ENTRIES, { x: 1, y: 26 }, 52), "claude");
});

test("Provider shares read to one decimal, like the Mac's percent formatter", () => {
  assert.equal(usageShareText(64.2384), "64.2%");
  // A whole share drops the decimal instead of padding it to "75.0%".
  assert.equal(usageShareText(75), "75%");
  assert.equal(usageShareText(99.96), "100%");
  assert.equal(usageShareText(undefined), "—");
});

test("Provider cost quotes the recorded dollars and never invents $0.00", () => {
  assert.equal(usageCostText({ cost: 23.5712, hasCompletePricing: true }), "$23.57");
  assert.equal(usageCostText({ cost: 0, hasCompletePricing: false }), "Price unavailable");
  assert.equal(usageCostText(undefined), "Price unavailable");
});

test("usage ring ignores its centre, outside points, and empty data", () => {
  assert.equal(usageRingSegmentAtPoint(ENTRIES, { x: 26, y: 26 }, 52), undefined);
  assert.equal(usageRingSegmentAtPoint(ENTRIES, { x: 60, y: 26 }, 52), undefined);
  assert.equal(usageRingSegmentAtPoint([], { x: 26, y: 1 }, 52), undefined);
  assert.equal(usageRingStops([]), "var(--track) 0% 100%");
});
