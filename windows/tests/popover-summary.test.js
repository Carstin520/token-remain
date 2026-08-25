import assert from "node:assert/strict";
import test from "node:test";
import { feedSummaryText, providerSummaryText, usageSummaryText } from "../src/popover-summary.js";

test("provider summary lists every window with pace, freshness, and notice", () => {
  const text = providerSummaryText({
    name: "Claude",
    windowTitle: "5 hr window",
    remainingText: "57% remaining",
    resetText: "Resets in 3 hr 0 min",
    capturedText: "Updated just now",
    notice: "Login not detected",
    windows: [
      { title: "5 hr window", remainingText: "57% remaining", resetText: "Resets in 3 hr 0 min", aheadOfPace: true },
      { title: "7 d window", remainingText: "82% remaining", resetText: "Resets in 4 d", aheadOfPace: false },
    ],
  });
  assert.deepEqual(text.split("\n"), [
    "Claude — official quota",
    "5 hr window: 57% remaining · Resets in 3 hr 0 min · ahead of pace",
    "7 d window: 82% remaining · Resets in 4 d",
    "Updated just now",
    "Notice: Login not detected",
  ]);
});

test("provider summary lists scoped windows after account windows, each exactly once", () => {
  const text = providerSummaryText({
    name: "Claude",
    windowTitle: "5 hr window",
    remainingText: "57% remaining",
    resetText: "Resets in 3 hr 0 min",
    capturedText: "Updated just now",
    windows: [
      { key: "window-0", title: "5 hr window", remainingText: "57% remaining", resetText: "Resets in 3 hr 0 min", aheadOfPace: false },
      { key: "window-1", title: "7 d window", remainingText: "82% remaining", resetText: "Resets in 4 d", aheadOfPace: false },
    ],
    scopedWindows: [
      { key: "scope-opus", title: "Opus · 7 d window", remainingText: "40% remaining", resetText: "Resets in 4 d", aheadOfPace: true },
    ],
  });
  assert.deepEqual(text.split("\n"), [
    "Claude — official quota",
    "5 hr window: 57% remaining · Resets in 3 hr 0 min",
    "7 d window: 82% remaining · Resets in 4 d",
    "Opus · 7 d window: 40% remaining · Resets in 4 d · ahead of pace",
    "Updated just now",
  ]);
});

test("provider summary falls back to the card summary when no windows exist", () => {
  const text = providerSummaryText({
    name: "Codex",
    windowTitle: "5 hr window",
    remainingText: "$4.20 remaining",
    resetText: "Resets in 1 hr 0 min",
    windows: [],
  });
  assert.deepEqual(text.split("\n"), [
    "Codex — official quota",
    "5 hr window: $4.20 remaining · Resets in 1 hr 0 min",
  ]);
});

test("usage summary copies the three visible buckets, or the honest empty reason", () => {
  const text = usageSummaryText({
    today: { label: "$2.00 · 4.0K tokens" },
    yesterday: { label: "—" },
    last30Days: { label: "$60.00 · 120.0K tokens" },
  });
  assert.deepEqual(text.split("\n"), [
    "Today's Local Usage",
    "Today: $2.00 · 4.0K tokens",
    "Yesterday: —",
    "Last 30 Days: $60.00 · 120.0K tokens",
  ]);
  assert.equal(
    usageSummaryText(undefined, { title: "Pair your Mac to see today's usage" }),
    "Today's Local Usage — Pair your Mac to see today's usage",
  );
});

test("feed summary copies the visible stories with their public URLs", () => {
  const text = feedSummaryText({ items: [
    { source: "Anthropic", age: "2 hr, 0 min", title: "Usage limit update", url: "https://x.com/a/1" },
  ] });
  assert.deepEqual(text.split("\n"), [
    "AI Feed — important updates",
    "Anthropic · 2 hr, 0 min: Usage limit update (https://x.com/a/1)",
  ]);
  assert.equal(feedSummaryText({ items: [] }), "AI Feed — no important updates right now");
  assert.equal(feedSummaryText({ items: [], error: "503" }), "AI Feed — temporarily unavailable");
});
