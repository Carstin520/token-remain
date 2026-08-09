import assert from "node:assert/strict";
import test from "node:test";
import {
  buildPopoverModel,
  buildUsageDigest,
  popoverFeed,
  popoverQuotaCards,
  popoverRisk,
  usageEmptyState,
  POPOVER_QUOTA_CARD_LIMIT,
} from "../src/popover-model.js";

const NOW = Date.parse("2026-08-07T12:00:00Z");

function providers() {
  return [
    { providerID: "claude", capturedAt: NOW, windows: [
      { usedPercent: 43, windowMinutes: 300, resetsAt: NOW + 3 * 3_600_000 },
      { usedPercent: 18, windowMinutes: 10_080, resetsAt: NOW + 4 * 86_400_000 },
    ] },
    { providerID: "codex", capturedAt: NOW, windows: [{ usedPercent: 92, windowMinutes: 300, resetsAt: NOW + 3_600_000 }] },
    { providerID: "cursor", capturedAt: NOW, windows: [{ usedPercent: 26, windowMinutes: 44_640, resetsAt: NOW + 12 * 86_400_000 }] },
  ];
}

function history() {
  const days = Array.from({ length: 34 }, (_, index) => {
    const day = new Date(Date.parse("2026-08-07T00:00:00Z") - (33 - index) * 86_400_000).toISOString().slice(0, 10);
    return { day, claudeTokens: 1_000, claudeCost: 0.5, codexTokens: 3_000, codexCost: 1.5 };
  });
  return { sourceDay: "2026-08-07", capturedAt: NOW, days };
}

test("Quota cards follow the shortest window and the Mac's remaining/reset copy", () => {
  const cards = popoverQuotaCards({ providers: providers(), notices: {} }, undefined, { now: NOW });
  assert.deepEqual(cards.map((card) => card.id), ["claude", "codex", "cursor"]);
  const [claude, codex] = cards;
  assert.equal(claude.name, "Claude");
  assert.equal(claude.windowTitle, "5 hr window");
  assert.equal(claude.remaining, 57);
  assert.equal(claude.remainingText, "57% remaining");
  assert.equal(claude.resetText, "Resets in 3 hr 0 min");
  assert.equal(claude.level, "low");
  // Under 10% remaining is the Mac's HIGH threshold, and the card says so
  // without relying on colour alone.
  assert.equal(codex.remaining, 8);
  assert.equal(codex.level, "high");
});

test("Quota cards carry every valid window for the expanded view", () => {
  const [claude] = popoverQuotaCards({ providers: [providers()[0]], notices: {} }, undefined, { now: NOW });
  // Both Claude windows, in the snapshot's order, not just the shortest one.
  assert.equal(claude.windows.length, 2);
  const [fiveHour, weekly] = claude.windows;
  assert.equal(fiveHour.title, "5 hr window");
  assert.equal(fiveHour.name, "5 hr");
  assert.equal(fiveHour.remaining, 57);
  assert.equal(fiveHour.remainingText, "57% remaining");
  assert.equal(fiveHour.resetText, "Resets in 3 hr 0 min");
  assert.equal(fiveHour.level, "low");
  // 43% used at 40% elapsed sits outside the ±2% on-track band, so deficit.
  assert.equal(fiveHour.aheadOfPace, true);
  assert.equal(weekly.title, "7 d window");
  assert.equal(weekly.name, "7 d");
  assert.equal(weekly.remaining, 82);
  assert.equal(weekly.level, "low");
  assert.equal(weekly.aheadOfPace, false);
  // The summary read and the first-listed window quote identical copy.
  assert.equal(claude.remainingText, fiveHour.remainingText);
  assert.equal(claude.capturedText, "Updated just now");
});

test("The summary window leads the expanded list exactly once, under a stable key", () => {
  // Snapshot lists the weekly window first; the summary (shortest) window must
  // still lead without being repeated further down.
  const [card] = popoverQuotaCards({ providers: [{ providerID: "claude", capturedAt: NOW, windows: [
    { usedPercent: 18, windowMinutes: 10_080, resetsAt: NOW + 4 * 86_400_000 },
    { usedPercent: 43, windowMinutes: 300, resetsAt: NOW + 3 * 3_600_000 },
  ] }], notices: {} }, undefined, { now: NOW });
  assert.deepEqual(card.windows.map((window) => window.title), ["5 hr window", "7 d window"]);
  // Keys follow the snapshot position, so reordering for the summary keeps
  // each window's identity stable.
  assert.deepEqual(card.windows.map((window) => window.key), ["window-1", "window-0"]);
  assert.equal(card.windowTitle, "5 hr window");
  assert.equal(card.remainingText, card.windows[0].remainingText);
  // Two windows sharing a duration (and therefore a title) still get distinct
  // keys and both survive.
  const [twin] = popoverQuotaCards({ providers: [{ providerID: "codex", capturedAt: NOW, windows: [
    { usedPercent: 40, windowMinutes: 300, resetsAt: NOW + 3_600_000 },
    { usedPercent: 70, windowMinutes: 300, resetsAt: NOW + 2 * 3_600_000 },
  ] }], notices: {} }, undefined, { now: NOW });
  assert.equal(twin.windows.length, 2);
  assert.deepEqual(twin.windows.map((window) => window.key), ["window-0", "window-1"]);
});

test("Scoped windows join the expanded card, except Fable and invalid scopes", () => {
  const [card] = popoverQuotaCards({ providers: [{ providerID: "claude", capturedAt: NOW, windows: [
    { usedPercent: 43, windowMinutes: 300, resetsAt: NOW + 3 * 3_600_000 },
  ], scopedWindows: [
    { scopeID: "opus", displayName: "Opus", window: { usedPercent: 60, windowMinutes: 10_080, resetsAt: NOW + 86_400_000 } },
    // Fable is the provider's own named quota; a scoped copy would double-count.
    { scopeID: "fable", displayName: "Fable", window: { usedPercent: 10, windowMinutes: 10_080, resetsAt: NOW + 86_400_000 } },
    { scopeID: "fable_5", displayName: "Fable 5", window: { usedPercent: 10, windowMinutes: 10_080, resetsAt: NOW + 86_400_000 } },
    // A duplicate scope keeps the latest reading in first-seen order.
    { scopeID: "opus", displayName: "Opus", window: { usedPercent: 90, windowMinutes: 10_080, resetsAt: NOW + 12 * 3_600_000 } },
    // Invalid window readings never become rows.
    { scopeID: "haiku", displayName: "Haiku", window: { windowMinutes: 10_080 } },
  ] }], notices: {} }, undefined, { now: NOW });
  assert.equal(card.scopedWindows.length, 1);
  const [scoped] = card.scopedWindows;
  assert.equal(scoped.key, "scope-opus");
  assert.equal(scoped.scopeName, "Opus");
  // Display name plus window duration, so equal-duration scopes stay readable.
  assert.equal(scoped.title, "Opus · 7 d window");
  assert.equal(scoped.remaining, 10);
  assert.equal(scoped.remainingText, "10% remaining");
  assert.equal(scoped.level, "medium");
  assert.equal(scoped.resetText, "Resets in 12 hr 0 min");
  // The account window list is untouched by scoped data.
  assert.deepEqual(card.windows.map((window) => window.key), ["window-0"]);
  // No scoped data means an empty list, not a missing field.
  const [plain] = popoverQuotaCards({ providers: [{ providerID: "codex", capturedAt: NOW, windows: [
    { usedPercent: 20, windowMinutes: 300, resetsAt: NOW + 3_600_000 },
  ] }], notices: {} }, undefined, { now: NOW });
  assert.deepEqual(plain.scopedWindows, []);
});

test("Freshness carries the Mac's 10-minute stale flag without changing wording", () => {
  const provider = (capturedAt) => ({ providerID: "claude", capturedAt, windows: [
    { usedPercent: 43, windowMinutes: 300, resetsAt: NOW + 3 * 3_600_000 },
  ] });
  const [fresh] = popoverQuotaCards({ providers: [provider(NOW - 9 * 60_000)], notices: {} }, undefined, { now: NOW });
  assert.equal(fresh.capturedText, "Updated 9 min ago");
  assert.equal(fresh.capturedStale, false);
  const [stale] = popoverQuotaCards({ providers: [provider(NOW - 10 * 60_000)], notices: {} }, undefined, { now: NOW });
  assert.equal(stale.capturedText, "Updated 10 min ago");
  assert.equal(stale.capturedStale, true);
  // No capturedAt means no freshness claim and no stale claim either.
  const [unknown] = popoverQuotaCards({ providers: [{ providerID: "claude", windows: [
    { usedPercent: 10, windowMinutes: 300, resetsAt: NOW + 3_600_000 },
  ] }], notices: {} }, undefined, { now: NOW });
  assert.equal("capturedStale" in unknown, false);
});

test("Window details use the honest balance wording and skip invalid windows", () => {
  const [card] = popoverQuotaCards({ providers: [{ providerID: "codex", capturedAt: NOW - 5 * 60_000, windows: [
    { usedPercent: 92, windowMinutes: 300, resetsAt: NOW + 3_600_000, remainingBalance: { amount: 4.2, currencyCode: "USD" } },
    { usedPercent: Number.NaN, windowMinutes: 10_080 },
    { windowMinutes: 1_440, resetsAt: NOW + 86_400_000 },
  ] }], notices: {} }, undefined, { now: NOW });
  // remainingBalance wins over the percent wording, matching the summary rule.
  assert.equal(card.windows.length, 1);
  assert.equal(card.windows[0].remainingText, "$4.20 remaining");
  assert.equal(card.windows[0].level, "high");
  assert.equal(card.capturedText, "Updated 5 min ago");
  // No finite capturedAt means no freshness claim at all.
  const [stale] = popoverQuotaCards({ providers: [{ providerID: "claude", windows: [
    { usedPercent: 10, windowMinutes: 300, resetsAt: NOW + 3_600_000 },
  ] }], notices: {} }, undefined, { now: NOW });
  assert.equal("capturedText" in stale, false);
});

test("Quota cards honour the saved Limits order instead of a second layout format", () => {
  const state = { providers: providers(), notices: {} };
  const reordered = popoverQuotaCards(state, undefined, { now: NOW, storedOrder: ["cursor", "codex", "claude"] });
  assert.deepEqual(reordered.map((card) => card.id), ["cursor", "codex", "claude"]);
  // A stale saved order still resolves against what actually has a snapshot.
  const stale = popoverQuotaCards(state, undefined, { now: NOW, storedOrder: ["grok", "cursor", "removed"] });
  assert.deepEqual(stale.map((card) => card.id), ["cursor", "claude", "codex"]);
  // Without a saved order the Overview's most-used ranking decides.
  const ranked = popoverQuotaCards(state, { entries: [{ id: "codex", tokens: 90 }, { id: "claude", tokens: 10 }] }, { now: NOW });
  assert.deepEqual(ranked.map((card) => card.id), ["codex", "claude", "cursor"]);
});

test("Quota cards are capped and skip providers with no snapshot", () => {
  const many = [...providers(), { providerID: "grok", capturedAt: NOW, windows: [{ usedPercent: 5, windowMinutes: 10_080 }] }];
  const cards = popoverQuotaCards({ providers: many, notices: {} }, undefined, { now: NOW });
  assert.equal(cards.length, POPOVER_QUOTA_CARD_LIMIT);
  assert.deepEqual(popoverQuotaCards({ providers: [{ providerID: "claude", windows: [] }] }, undefined, { now: NOW }), []);
  const [card] = popoverQuotaCards(
    { providers: [providers()[0]], notices: { claude: "Login not detected" } },
    undefined,
    { now: NOW },
  );
  assert.equal(card.notice, "Login not detected");
});

test("Risk strip reports the tightest window and a projected run-out separately", () => {
  const risk = popoverRisk(providers(), NOW);
  assert.equal(risk.level, "high");
  assert.equal(risk.badge, "HIGH");
  // A predicted early run-out replaces the level headline, exactly like the Mac.
  assert.equal(risk.headline, "Current pace may run out early");
  assert.equal(risk.detail, "Codex 8% remaining");
  assert.equal(risk.windowLabel, "Codex · 5 hr");
  assert.match(risk.projection, /^Codex 5 hr runs out in /);
  const calm = popoverRisk([
    { providerID: "claude", windows: [{ usedPercent: 20, windowMinutes: 300, resetsAt: NOW + 3_600_000 }] },
  ], NOW);
  assert.equal(calm.level, "low");
  assert.equal(calm.headline, "Usage pace is healthy");
  assert.equal(calm.projection, undefined);
  const paced = popoverRisk([
    { providerID: "codex", windows: [{ usedPercent: 63, windowMinutes: 300, resetsAt: NOW + 3 * 3_600_000 }] },
  ], NOW);
  assert.equal(paced.level, "medium");
  assert.equal(paced.headline, "Current pace may run out early");
  assert.match(paced.projection, /^Codex 5 hr runs out in /);
  const empty = popoverRisk([], NOW);
  assert.equal(empty.badge, "UNKNOWN");
  assert.equal(empty.headline, "Waiting for official quota");
  assert.equal(empty.detail, undefined);
});

test("Usage digest fills Today, Yesterday, and Last 30 Days from the synced aggregate", () => {
  const digest = buildUsageDigest(history(), NOW);
  assert.equal(digest.dayKey, "2026-08-07");
  assert.equal(digest.today.tokens, 4_000);
  assert.equal(digest.today.label, "$2.00 · 4.0K tokens");
  assert.equal(digest.yesterday.tokens, 4_000);
  // Exactly 30 days ending today, not the whole 34-day history.
  assert.equal(digest.last30Days.tokens, 120_000);
  assert.equal(digest.last30Days.label, "$60.00 · 120.0K tokens");
  assert.equal(digest.trend.length, 30);
  assert.equal(digest.trend.at(-1).day, "2026-08-07");
  assert.equal(digest.trend[0].day, "2026-07-09");
  assert.deepEqual(digest.entries.map((entry) => entry.displayName), ["Codex", "Claude"]);
  assert.equal(digest.entries[0].tokenShare, 75);
  assert.equal(digest.entries[0].color, "#6687C5");
});

test("Missing days report no data instead of a fabricated zero", () => {
  const digest = buildUsageDigest({ sourceDay: "2026-08-07", capturedAt: NOW, days: [
    { day: "2026-08-07", claudeTokens: 10, claudeCost: 0.1, codexTokens: 0, codexCost: 0 },
  ] }, NOW);
  assert.equal(digest.yesterday.hasData, false);
  assert.equal(digest.yesterday.tokens, undefined);
  assert.equal(digest.yesterday.label, "—");
  assert.equal(digest.today.hasData, true);
  // A day ccusage never reported is a zero-height bar in its own slot, so the
  // trend keeps one bar per calendar day instead of sliding usage earlier.
  assert.equal(digest.trend.length, 30);
  assert.equal(digest.trend.at(-1).tokens, 10);
  assert.ok(digest.trend.slice(0, -1).every((point) => point.tokens === 0));
  assert.deepEqual(digest.trend.slice(-3).map((point) => point.day), ["2026-08-05", "2026-08-06", "2026-08-07"]);
  assert.equal(buildUsageDigest(undefined, NOW), undefined);
  // Tokens recorded with no price never claim "$0.00".
  const unpriced = buildUsageDigest({ sourceDay: "2026-08-07", capturedAt: NOW, days: [
    { day: "2026-08-07", claudeTokens: 500, claudeCost: 0, codexTokens: 0, codexCost: 0 },
  ] }, NOW);
  assert.equal(unpriced.today.cost, undefined);
  assert.equal(unpriced.today.label, "Price unavailable · 500 tokens");
});

test("Empty local usage explains the actual reason it is empty", () => {
  assert.match(usageEmptyState({ sync: { paired: false } }).title, /Pair your Mac/);
  assert.match(usageEmptyState({ sync: { paired: true } }).title, /No usage history from your Mac yet/);
  assert.match(usageEmptyState({ sync: { paired: true }, dailyUsageHistory: history() }).title, /No local usage yet today/);
});

test("Feed keeps at most two stories and marks a failed refresh as cached", () => {
  const post = (id, overrides) => ({
    id,
    text: `Claude usage limit update ${id}`,
    username: "AnthropicAI",
    displayName: "Anthropic",
    publishedAt: NOW - 2 * 3_600_000,
    url: `https://x.com/AnthropicAI/status/${id}`,
    priority: "token_reset",
    tier: "primary",
    metrics: { likes: 10, reposts: 2, replies: 1 },
    ...overrides,
  });
  const trending = [post("1"), post("2"), post("3")];
  const live = popoverFeed({ trending }, NOW);
  assert.equal(live.items.length, 2);
  assert.equal(live.items[0].source, "Anthropic");
  assert.equal(live.items[0].age, "2 hr, 0 min");
  assert.equal(live.items[0].priorityLabel, "Quota / Token");
  assert.equal(live.status, undefined);

  const degraded = popoverFeed({ trending, feedError: "Trending feed returned 503" }, NOW);
  assert.equal(degraded.items.length, 2);
  assert.equal(degraded.cached, true);
  assert.equal(degraded.status, "Cached");

  const broken = popoverFeed({ trending: [], feedError: "Trending feed returned 503" }, NOW);
  assert.equal(broken.status, "Unavailable");
  assert.equal(popoverFeed({ trending: [], feedLoading: true }, NOW).status, "Updating");
});

test("The popover model composes one snapshot of every section", () => {
  const model = buildPopoverModel({
    providers: providers(),
    notices: {},
    lastUpdatedAt: NOW - 120_000,
    isRefreshing: true,
    dailyUsageHistory: history(),
    trending: [],
    sync: { paired: true },
  }, { now: NOW, storedOrder: ["codex", "claude", "cursor"] });
  assert.equal(model.updatedLabel, "Updated 2 min ago");
  assert.equal(model.isRefreshing, true);
  assert.equal(model.risk.level, "high");
  assert.deepEqual(model.quota.map((card) => card.id), ["codex", "claude", "cursor"]);
  assert.equal(model.quotaNotice, undefined);
  assert.equal(model.usage.today.tokens, 4_000);
  assert.equal(model.usageEmpty, undefined);
  assert.deepEqual(model.feed.items, []);

  const cold = buildPopoverModel({ providers: [], sync: { paired: false } }, { now: NOW });
  assert.equal(cold.updatedLabel, "Loading data…");
  assert.equal(cold.quotaNotice, "Reading official quota…");
  assert.equal(cold.usage, undefined);
  assert.match(cold.usageEmpty.title, /Pair your Mac/);
});
