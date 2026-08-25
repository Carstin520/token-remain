import assert from "node:assert/strict";
import test from "node:test";
import {
  compactNumber,
  compactUSD,
  durationUntil,
  formatPercent,
  freshnessDescription,
  isStaleCapture,
  relativeAge,
  resetDescription,
  windowName,
  windowTitle,
} from "../src/format.js";

const now = Date.parse("2026-08-04T08:00:00Z");

test("Percent formatting matches the Mac: whole numbers plain, otherwise one decimal", () => {
  assert.equal(formatPercent(57), "57%");
  assert.equal(formatPercent(98.5), "98.5%");
  assert.equal(formatPercent(30.24), "30.2%");
  assert.equal(formatPercent(undefined), "—");
});

test("Compact numbers and USD use the Mac's precision tiers", () => {
  assert.equal(compactNumber(229_520_000), "229.52M");
  assert.equal(compactNumber(12_300), "12.3K");
  assert.equal(compactNumber(1_234_567_890), "1.23B");
  assert.equal(compactNumber(999), "999");
  assert.equal(compactUSD(184.4), "$184.40");
  assert.equal(compactUSD(2_500), "$2.5K");
});

test("Reset labels follow the Mac windows: countdown, weekday, resetting, waiting", () => {
  assert.equal(resetDescription(undefined, now), "Waiting for the official reset time");
  assert.equal(resetDescription(now - 1, now), "Resetting");
  assert.equal(resetDescription(now + (2 * 60 + 52) * 60_000, now), "Resets in 2 hr 52 min");
  assert.equal(resetDescription(now + 12 * 60_000, now), "Resets in 12 min");
  const weekday = resetDescription(now + 3 * 86_400_000, now);
  assert.match(weekday, /^Resets /);
  assert.doesNotMatch(weekday, /Resets in/);
  const far = resetDescription(now + 12 * 86_400_000, now);
  assert.match(far, /^Resets /);
  assert.doesNotMatch(far, /Resets in/);
});

test("Durations and freshness use the Mac's units and staleness threshold", () => {
  assert.equal(durationUntil(now + (2 * 24 * 60 + 17 * 60) * 60_000, now), "2 d 17 hr");
  assert.equal(durationUntil(now + 169 * 60_000, now), "2 hr 49 min");
  assert.equal(durationUntil(now + 30_000, now), "Less than 1 min");
  assert.equal(freshnessDescription(now - 30_000, now), "Updated just now");
  assert.equal(freshnessDescription(now - 5 * 60_000, now), "Updated 5 min ago");
  assert.equal(freshnessDescription(now - 5 * 86_400_000, now), "Updated 5 d ago");
  assert.equal(isStaleCapture(now - 9 * 60_000, now), false);
  assert.equal(isStaleCapture(now - 10 * 60_000, now), true);
});

test("Window names collapse to the Mac's day/hour/minute buckets", () => {
  assert.equal(windowName(300), "5 hr");
  assert.equal(windowName(10_080), "7 d");
  assert.equal(windowName(44_640), "31 d");
  assert.equal(windowName(45), "45 min");
  assert.equal(windowName(0), "Total");
  assert.equal(windowTitle(300), "5 hr window");
});

test("Feed ages read like the Mac's relative style", () => {
  assert.equal(relativeAge(now - 30_000, now), "now");
  assert.equal(relativeAge(now - 45 * 60_000, now), "45 min");
  assert.equal(relativeAge(now - (6 * 60 + 34) * 60_000, now), "6 hr, 34 min");
  assert.equal(relativeAge(now - 50 * 3_600_000, now), "2 d, 2 hr");
});
