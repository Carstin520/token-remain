// Presentation model for the tray popover.
//
// The popover is a compact read of the same state the Dashboard renders, so all
// quota, risk, formatting, and feed-curation rules are imported rather than
// restated here. What this module adds is popover-specific selection: which
// three provider cards fit, the Today / Yesterday / Last 30 Days digest, and
// honest empty states when neither this PC nor Mac Direct Sync has usage.

import { priorityTitle, topStories } from "./feed-model.js";
import {
  compactNumber,
  durationUntil,
  formatBalance,
  formatMoney,
  formatPercent,
  freshnessDescription,
  isStaleCapture,
  relativeAge,
  resetDescription,
  windowName,
  windowTitle,
} from "./format.js";
import { normalizeOrder } from "./layout.js";
import { tr, trKey } from "./i18n.js";
import {
  buildRiskNotes,
  buildTodayUsage,
  isQuotaWindow,
  rankOfficialQuotaProviders,
  riskLevel,
  summaryWindow,
  usagePace,
} from "./overview-model.js";
import { providerMeta } from "./provider-meta.js";
import { poolDisplayName, providerQuotaDetailRows, visibleScopedWindows } from "./quota-details.js";
import { usageDayTotals } from "./usage-history.js";

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
    state?.noticeDetails?.[id] || (state?.notices?.[id]
      ? { message: state.notices[id], detail: state.notices[id], kind: "unknown" }
      : undefined),
    state,
    now,
  ));
}

function quotaCard(provider, notice, preferences, now) {
  const meta = providerMeta(provider.providerID);
  const summary = summaryWindow(provider, preferences?.summaryStrategy);
  const summaryDetail = windowDetail(summary, now);
  // Keys come from the snapshot position, never the display title, so two
  // windows sharing a duration or title can never collide or swap rows.
  const indexed = (provider.windows || [])
    .map((window, index) => ({ window, index }))
    .filter(({ window }) => isQuotaWindow(window));
  return {
    id: provider.providerID,
    name: meta.name,
    color: meta.color,
    iconFile: meta.icon,
    windowTitle: summaryDetail.title,
    remaining: summaryDetail.remaining,
    remainingText: summaryDetail.remainingText,
    resetText: summaryDetail.resetText,
    level: summaryDetail.level,
    aheadOfPace: summaryDetail.aheadOfPace,
    // Every valid window exactly once, summary window first — the Mac's stable
    // first row — with the rest kept in snapshot order.
    windows: [
      ...indexed.filter(({ window }) => window === summary),
      ...indexed.filter(({ window }) => window !== summary),
    ].map(({ window, index }) => ({ key: `window-${index}`, ...windowDetail(window, now) })),
    scopedWindows: scopedWindowDetails(provider, preferences, now),
    detailRows: providerQuotaDetailRows(provider),
    ...(Number.isFinite(provider.capturedAt)
      ? {
        capturedText: freshnessDescription(provider.capturedAt, now),
        capturedStale: isStaleCapture(provider.capturedAt, now),
      }
      : {}),
    notice: notice?.message,
    noticeDetail: notice?.detail,
    noticeKind: notice?.kind,
  };
}

/// Preference-gated scoped windows for the expanded card. The shared helper
/// also keeps the latest duplicate in first-seen order, like the Mac model.
function scopedWindowDetails(provider, preferences, now) {
  return visibleScopedWindows(provider, preferences).flatMap((scope) => {
    if (!isQuotaWindow(scope.window)) return [];
    const detail = windowDetail(scope.window, now);
    const scopeName = poolDisplayName(scope.displayName || scope.scopeID);
    return [{
      ...detail,
      key: `scope-${scope.scopeID.toLowerCase()}`,
      scopeName,
      title: `${scopeName} · ${detail.title}`,
    }];
  });
}

/// One window's presentation-ready read, shared by the card summary and the
/// expanded per-window list so both quote identical remaining/reset/risk copy.
function windowDetail(window, now) {
  const remaining = Math.min(100, Math.max(0, 100 - window.usedPercent));
  const pace = usagePace(window, now);
  return {
    title: window.poolName ? `${poolDisplayName(window.poolName)} · ${windowTitle(window.windowMinutes)}` : windowTitle(window.windowMinutes),
    name: windowName(window.windowMinutes),
    remaining,
    remainingText: window.remainingBalance
      ? trKey("quota.remaining", [formatBalance(window.remainingBalance)])
      : trKey("quota.remaining", [formatPercent(remaining)]),
    resetText: resetDescription(window.resetsAt, now),
    level: riskLevel(remaining),
    aheadOfPace: pace?.status === "deficit",
  };
}

/// Risk strip: the level badge, the Mac's headline, the tightest window's
/// remaining share, and the projected run-out when one is predicted.
export function popoverRisk(providers = [], now = Date.now()) {
  const notes = buildRiskNotes(providers, now);
  const tightest = notes.tightest;
  return {
    level: notes.level,
    badge: notes.level && notes.level !== "unknown" ? trKey(`risk.badge.${notes.level}`, [], notes.level.toUpperCase()) : "UNKNOWN",
    headline: notes.headline,
    detail: tightest
      ? trKey("risk.provider_remaining", [tightest.providerName, formatPercent(tightest.remaining)])
      : undefined,
    windowLabel: tightest ? `${tightest.providerName} · ${windowName(tightest.windowMinutes)}` : undefined,
    projection: Number.isFinite(notes.projectedRunOutAt) && notes.window
      ? tr("%1$@ %2$@ runs out in %3$@", [notes.window.providerName, windowName(notes.window.windowMinutes), durationUntil(notes.projectedRunOutAt, now)])
      : undefined,
  };
}

/// Today / Yesterday / Last 30 Days plus a short trend, built from the daily
/// local/synced aggregate. Missing days stay missing: a bucket without a
/// recorded day reports no data instead of a zero.
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
      // The ring's hover label and the row tooltip quote a per-provider dollar
      // figure, so the digest carries the same cost the daily history recorded
      // for that agent — never today's total split by tokens.
      cost: Number.isFinite(entry.cost) ? entry.cost : 0,
      hasCompletePricing: hasCompletePricing(entry),
    })),
    today: bucketOf(days.filter((day) => day.day === dayKey)),
    yesterday: bucketOf(days.filter((day) => day.day === yesterdayKey)),
    last30Days: bucketOf(days.filter((day) => day.day >= windowStart && day.day <= dayKey)),
    trend: buildTrend(days, dayKey),
  };
}

/// The Mac's ProviderUsage.hasCompletePricing, widened by the same test
/// usageDayTotals already applies to the day as a whole: a model ccusage could
/// not price, or tokens recorded with no cost at all, means the provider's
/// dollar figure is incomplete. Ollama is the exception the totals make too —
/// a local model genuinely costs nothing.
function hasCompletePricing(entry) {
  if (entry?.unpricedModels?.length) return false;
  if (entry?.id === "ollama") return true;
  return !(entry?.tokens > 0 && !(entry?.cost > 0));
}

/// One bar per calendar day in the trailing window, oldest first. ccusage omits
/// days with no activity, so an absent day is a genuine zero: dropping it would
/// slide later days left and misreport when the usage happened.
function buildTrend(days, dayKey, count = POPOVER_TREND_DAYS) {
  if (!dayKey) return [];
  const tokensByDay = new Map();
  for (const day of days) {
    const tokens = usageDayTotals(day).tokens;
    tokensByDay.set(day.day, (tokensByDay.get(day.day) || 0) + tokens);
  }
  return Array.from({ length: count }, (_, index) => {
    const day = shiftDay(dayKey, index - (count - 1));
    return { day, tokens: tokensByDay.get(day) || 0 };
  });
}

function bucketOf(days) {
  if (!days.length) return { hasData: false, tokens: undefined, cost: undefined, label: "—" };
  const totals = days.map(usageDayTotals);
  const tokens = totals.reduce((total, day) => total + day.tokens, 0);
  const rawCost = totals.reduce((total, day) => total + day.knownCost, 0);
  const cost = totals.some((day) => day.hasUnpricedUsage) ? undefined : rawCost;
  return {
    hasData: true,
    tokens,
    cost,
    label: `${Number.isFinite(cost) ? formatMoney(cost) : tr("Price unavailable")} · ${compactNumber(tokens)} ${tr("tokens")}`,
  };
}

/// The reason the local-usage card is empty, worded the same way the Dashboard
/// words it so the two surfaces never disagree about why data is missing.
export function usageEmptyState(state) {
  if (!state?.dailyUsageHistory && state?.localUsage?.error) {
    return {
      title: "Local usage could not be read",
      message: state.localUsage.error,
    };
  }
  if (!state?.dailyUsageHistory) {
    return {
      title: "No local usage history yet",
      message: "Use a supported coding app on this PC and built-in ccusage will record tokens and estimated API-list-price cost automatically.",
    };
  }
  return {
    title: "No local usage yet today",
    message: "This fills in after Claude Code, Codex, Gemini CLI, Copilot CLI, or another supported local agent records usage today.",
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
