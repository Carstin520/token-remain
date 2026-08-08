// Presentation model for the tray popover.
//
// The popover is a compact read of the same state the Dashboard renders, so all
// quota, risk, formatting, and feed-curation rules are imported rather than
// restated here. What this module adds is popover-specific selection: which
// three provider cards fit, the Today / Yesterday / Last 30 Days digest, and
// honest empty states when Mac Direct Sync has nothing to show.

import { priorityTitle, topStories } from "./feed-model.js";
import {
  compactNumber,
  durationUntil,
  formatBalance,
  formatMoney,
  formatPercent,
  freshnessDescription,
  relativeAge,
  resetDescription,
  windowName,
  windowTitle,
} from "./format.js";
import { normalizeOrder } from "./layout.js";
import {
  buildRiskNotes,
  buildTodayUsage,
  rankOfficialQuotaProviders,
  riskLevel,
  summaryWindow,
  usagePace,
} from "./overview-model.js";
import { providerMeta } from "./provider-meta.js";

export const POPOVER_QUOTA_CARD_LIMIT = 3;
export const POPOVER_FEED_LIMIT = 2;
/// Same window the Mac popover's MiniBarChart draws, so the two trends can be
/// compared bar for bar.
export const POPOVER_TREND_DAYS = 30;

const DAY_MS = 86_400_000;
const LAST_30_DAYS = 30;

/// Provider cards, ordered by whatever arrangement the user already saved for
/// the Limits page, and otherwise by the Overview's most-used ranking. Only
/// providers with an actual quota snapshot get a card.
export function popoverQuotaCards(state, today, options = {}) {
  const { limit = POPOVER_QUOTA_CARD_LIMIT, storedOrder, now = Date.now() } = options;
  const providers = state?.providers || [];
  const withData = providers.filter((provider) => summaryWindow(provider));
  const availableIDs = withData.map((provider) => provider.providerID);
  if (!availableIDs.length) return [];
  const ranked = rankOfficialQuotaProviders(providers, today);
  const ordered = Array.isArray(storedOrder) && storedOrder.length
    ? normalizeOrder(storedOrder, availableIDs)
    : [...ranked, ...availableIDs.filter((id) => !ranked.includes(id))];
  return ordered.slice(0, limit).map((id) => quotaCard(
    withData.find((provider) => provider.providerID === id),
    state?.notices?.[id],
    now,
  ));
}

function quotaCard(provider, notice, now) {
  const meta = providerMeta(provider.providerID);
  const window = summaryWindow(provider);
  const remaining = Math.min(100, Math.max(0, 100 - window.usedPercent));
  const pace = usagePace(window, now);
  return {
    id: provider.providerID,
    name: meta.name,
    color: meta.color,
    iconFile: meta.icon,
    windowTitle: windowTitle(window.windowMinutes),
    remaining,
    remainingText: window.remainingBalance
      ? `${formatBalance(window.remainingBalance)} remaining`
      : `${formatPercent(remaining)} remaining`,
    resetText: resetDescription(window.resetsAt, now),
    level: riskLevel(remaining),
    aheadOfPace: pace?.status === "deficit",
    notice,
  };
}

/// Risk strip: the level badge, the Mac's headline, the tightest window's
/// remaining share, and the projected run-out when one is predicted.
export function popoverRisk(providers = [], now = Date.now()) {
  const notes = buildRiskNotes(providers, now);
  const tightest = notes.tightest;
  return {
    level: notes.level,
    badge: notes.level ? notes.level.toUpperCase() : "UNKNOWN",
    headline: notes.headline,
    detail: tightest
      ? `${tightest.providerName} ${formatPercent(tightest.remaining)} remaining`
      : undefined,
    windowLabel: tightest ? `${tightest.providerName} · ${windowName(tightest.windowMinutes)}` : undefined,
    projection: Number.isFinite(notes.projectedRunOutAt) && notes.window
      ? `${notes.window.providerName} ${windowName(notes.window.windowMinutes)} runs out in ${durationUntil(notes.projectedRunOutAt, now)}`
      : undefined,
  };
}

/// Today / Yesterday / Last 30 Days plus a short trend, built from the daily
/// aggregate the paired Mac shares. Missing days stay missing: a bucket without
/// a synced day reports no data instead of a zero.
export function buildUsageDigest(history, now = Date.now()) {
  if (!history || !Array.isArray(history.days)) return undefined;
  const today = buildTodayUsage(history, now);
  const dayKey = today?.dayKey;
  const days = [...history.days].filter((day) => typeof day?.day === "string").sort(byDay);
  const yesterdayKey = shiftDay(dayKey, -1);
  const windowStart = shiftDay(dayKey, -(LAST_30_DAYS - 1));
  return {
    dayKey,
    capturedAt: history.capturedAt,
    entries: (today?.entries || []).map((entry) => ({
      ...entry,
      color: providerMeta(entry.id).color,
      tokenShare: today.totalTokens > 0 ? entry.tokens / today.totalTokens * 100 : undefined,
    })),
    today: bucketOf(days.filter((day) => day.day === dayKey)),
    yesterday: bucketOf(days.filter((day) => day.day === yesterdayKey)),
    last30Days: bucketOf(days.filter((day) => day.day >= windowStart && day.day <= dayKey)),
    trend: buildTrend(days, dayKey),
  };
}

/// One bar per calendar day in the trailing window, oldest first. ccusage omits
/// days with no activity, so an absent day is a genuine zero: dropping it would
/// slide later days left and misreport when the usage happened.
function buildTrend(days, dayKey, count = POPOVER_TREND_DAYS) {
  if (!dayKey) return [];
  const tokensByDay = new Map();
  for (const day of days) {
    const tokens = numeric(day.claudeTokens) + numeric(day.codexTokens);
    tokensByDay.set(day.day, (tokensByDay.get(day.day) || 0) + tokens);
  }
  return Array.from({ length: count }, (_, index) => {
    const day = shiftDay(dayKey, index - (count - 1));
    return { day, tokens: tokensByDay.get(day) || 0 };
  });
}

function bucketOf(days) {
  if (!days.length) return { hasData: false, tokens: undefined, cost: undefined, label: "—" };
  const tokens = days.reduce((total, day) => total + numeric(day.claudeTokens) + numeric(day.codexTokens), 0);
  const rawCost = days.reduce((total, day) => total + numeric(day.claudeCost) + numeric(day.codexCost), 0);
  // ccusage reports 0 for models it has no price for; claiming "$0.00" there
  // would be a lie, so an unpriced bucket says so instead.
  const cost = tokens > 0 && rawCost <= 0 ? undefined : rawCost;
  return {
    hasData: true,
    tokens,
    cost,
    label: `${Number.isFinite(cost) ? formatMoney(cost) : "Price unavailable"} · ${compactNumber(tokens)} tokens`,
  };
}

/// The reason the local-usage card is empty, worded the same way the Dashboard
/// words it so the two surfaces never disagree about why data is missing.
export function usageEmptyState(state) {
  if (!state?.sync?.paired) {
    return {
      title: "Pair your Mac to see today's usage",
      message: "Direct sync brings the same daily usage aggregate to this PC.",
    };
  }
  if (!state?.dailyUsageHistory) {
    return {
      title: "No usage history from your Mac yet",
      message: "Turn on “Share daily usage with paired devices” in TokenRemain › Devices on your Mac.",
    };
  }
  return {
    title: "No local usage yet today",
    message: "This fills in after Claude or Codex records usage for the source Mac's current day.",
  };
}

/// Important updates, capped at two. A failed refresh keeps showing the cached
/// stories and says so rather than emptying the card.
export function popoverFeed(state, now = Date.now(), limit = POPOVER_FEED_LIMIT) {
  const items = topStories(state?.trending || [], now).slice(0, limit).map((post) => ({
    id: post.id,
    url: post.url,
    source: post.displayName,
    username: post.username,
    priority: post.priority,
    priorityLabel: priorityTitle(post.priority),
    age: relativeAge(post.publishedAt, now),
    title: post.text,
  }));
  const cached = Boolean(state?.feedError) && items.length > 0;
  return {
    items,
    cached,
    status: cached ? "Cached" : state?.feedError ? "Unavailable" : state?.feedLoading ? "Updating" : undefined,
    error: state?.feedError,
  };
}

export function buildPopoverModel(state, options = {}) {
  const { now = Date.now(), storedOrder, quotaLimit, feedLimit } = options;
  const providers = state?.providers || [];
  const today = buildTodayUsage(state?.dailyUsageHistory, now);
  const usage = buildUsageDigest(state?.dailyUsageHistory, now);
  return {
    updatedLabel: Number.isFinite(state?.lastUpdatedAt)
      ? freshnessDescription(state.lastUpdatedAt, now)
      : "Loading data…",
    isRefreshing: Boolean(state?.isRefreshing),
    risk: popoverRisk(providers, now),
    quota: popoverQuotaCards(state, today, { limit: quotaLimit, storedOrder, now }),
    quotaNotice: providers.some((provider) => summaryWindow(provider)) ? undefined : "Reading official quota…",
    usage: usage?.entries?.length ? usage : undefined,
    usageEmpty: usage?.entries?.length ? undefined : usageEmptyState(state),
    feed: popoverFeed(state, now, feedLimit),
  };
}

function byDay(left, right) {
  return left.day < right.day ? -1 : left.day > right.day ? 1 : 0;
}

function shiftDay(dayKey, offset) {
  const parsed = Date.parse(`${dayKey}T00:00:00Z`);
  if (!Number.isFinite(parsed)) return dayKey;
  return new Date(parsed + offset * DAY_MS).toISOString().slice(0, 10);
}

function numeric(value) {
  return Number.isFinite(value) ? value : 0;
}
