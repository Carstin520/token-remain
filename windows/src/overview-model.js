import { providerMeta } from "./provider-meta.js";

export function buildOverviewSummary(providers = [], now = Date.now()) {
  const risk = buildRiskNotes(providers, now);
  const entries = quotaEntries(providers);
  const nextReset = entries
    .filter((entry) => entry.resetsAt > now)
    .reduce((current, entry) => (!current || entry.resetsAt < current.resetsAt ? entry : current), undefined);
  return {
    tightest: risk.tightest,
    nextReset,
    trackedCount: trackedProviderCount(providers),
    risk: risk.level,
    projectedRunOutAt: risk.projectedRunOutAt,
    riskNotes: risk,
  };
}

export function trackedProviderCount(providers = []) {
  return providers.filter((provider) => provider.windows?.length).length;
}

export function riskLevel(remaining, projectedRunOut = false) {
  if (!Number.isFinite(remaining)) return undefined;
  if (remaining < 10) return "high";
  if (remaining < 30 || projectedRunOut) return "medium";
  return "low";
}

export function usagePace(window, now = Date.now()) {
  if (!Number.isFinite(window?.resetsAt) || !Number.isInteger(window?.windowMinutes) || window.windowMinutes <= 0) return undefined;
  const duration = window.windowMinutes * 60_000;
  const timeUntilReset = window.resetsAt - now;
  if (timeUntilReset <= 0 || timeUntilReset > duration) return undefined;
  const elapsed = duration - timeUntilReset;
  const expectedUsedPercent = clamp(elapsed / duration * 100, 0, 100);
  if (expectedUsedPercent < 3) return undefined;
  const actualUsedPercent = clamp(window.usedPercent, 0, 100);
  const deltaPercent = actualUsedPercent - expectedUsedPercent;
  const status = Math.abs(deltaPercent) <= 2 ? "onTrack" : deltaPercent > 0 ? "deficit" : "reserve";
  if (actualUsedPercent <= 0 || elapsed <= 0 || actualUsedPercent >= 100) {
    return {
      status,
      expectedUsedPercent,
      actualUsedPercent,
      deltaPercent,
      estimatedRunOutAt: actualUsedPercent >= 100 ? now : undefined,
      willLastUntilReset: actualUsedPercent < 100,
    };
  }
  const usedPercentPerMillisecond = actualUsedPercent / elapsed;
  const millisecondsUntilEmpty = (100 - actualUsedPercent) / usedPercentPerMillisecond;
  return {
    status,
    expectedUsedPercent,
    actualUsedPercent,
    deltaPercent,
    estimatedRunOutAt: millisecondsUntilEmpty < timeUntilReset ? now + millisecondsUntilEmpty : undefined,
    willLastUntilReset: millisecondsUntilEmpty >= timeUntilReset,
  };
}

export function buildRiskNotes(providers = [], now = Date.now()) {
  const entries = quotaEntries(providers);
  const tightest = entries.reduce((current, entry) => (!current || entry.remaining < current.remaining ? entry : current), undefined);
  const projected = entries.flatMap((entry) => {
    const pace = usagePace(entry, now);
    return pace && !pace.willLastUntilReset && Number.isFinite(pace.estimatedRunOutAt) ? [{ entry, pace }] : [];
  }).reduce((current, assessment) => (
    !current || assessment.pace.estimatedRunOutAt < current.pace.estimatedRunOutAt ? assessment : current
  ), undefined);
  const window = projected?.entry || tightest;
  const level = riskLevel(tightest?.remaining, Boolean(projected));
  return {
    level,
    tightest,
    window,
    projectedRunOutAt: projected?.pace.estimatedRunOutAt,
    headline: projected
      ? "Current pace may run out early"
      : level === "high" ? "Quota is nearly depleted"
        : level === "medium" ? "Watch your usage pace"
          : level === "low" ? "Usage pace is healthy" : "Waiting for official quota",
    summary: projected
      ? `${window.providerName} ${formatWindowShort(window.windowMinutes)} is projected to run out after ${formatDuration(projected.pace.estimatedRunOutAt - now)}, before the official reset. Slow down or switch providers.`
      : level === "high" ? "Quota is nearly depleted. Use carefully or wait for the window to reset."
        : level === "medium" ? "Some windows are running low. Slow down or watch the reset time."
          : level === "low" ? "At the current pace, your quota should last until the next reset."
            : "No official quota snapshot yet. TokenRemain will retry automatically.",
  };
}

export function buildTodayUsage(history, now = Date.now()) {
  if (!history || !Array.isArray(history.days)) return undefined;
  const dayKey = history.sourceDay || utcDayKey(now);
  const day = history.days.find((item) => item.day === dayKey);
  if (!day) return { dayKey, capturedAt: history.capturedAt, entries: [] };
  const entries = [
    { id: "claude", displayName: "Claude", tokens: day.claudeTokens, cost: day.claudeCost },
    { id: "codex", displayName: "Codex", tokens: day.codexTokens, cost: day.codexCost },
  ].filter((entry) => entry.tokens > 0 || entry.cost > 0).sort((left, right) => right.tokens - left.tokens);
  const totalTokens = entries.reduce((total, entry) => total + entry.tokens, 0);
  const rawCost = entries.reduce((total, entry) => total + entry.cost, 0);
  const hasAmbiguousZeroCost = entries.some((entry) => entry.tokens > 0 && entry.cost === 0);
  const totalCost = entries.length && !hasAmbiguousZeroCost ? rawCost : undefined;
  return {
    dayKey,
    capturedAt: history.capturedAt,
    entries: entries.map((entry) => ({
      ...entry,
      costShare: Number.isFinite(totalCost) && totalCost > 0 ? entry.cost / totalCost * 100 : undefined,
    })),
    totalTokens,
    totalCost,
  };
}

function quotaEntries(providers) {
  return providers.flatMap((provider) => {
    const providerName = providerMeta(provider.providerID).name;
    const windows = [...(provider.windows || []), ...(provider.scopedWindows || []).map((scope) => ({
      ...scope.window,
      scopeName: scope.displayName,
    }))];
    return windows.flatMap((window) => Number.isFinite(window.usedPercent) ? [{
      providerID: provider.providerID,
      providerName,
      scopeName: window.scopeName,
      remaining: clamp(100 - window.usedPercent, 0, 100),
      usedPercent: clamp(window.usedPercent, 0, 100),
      windowMinutes: window.windowMinutes,
      resetsAt: Number.isFinite(window.resetsAt) ? window.resetsAt : undefined,
    }] : []);
  });
}

function formatWindowShort(minutes) {
  if (minutes % 1_440 === 0) return `${minutes / 1_440} d`;
  if (minutes % 60 === 0) return `${minutes / 60} hr`;
  return `${minutes} min`;
}

function formatDuration(milliseconds) {
  const totalMinutes = Math.max(0, Math.floor(milliseconds / 60_000));
  const days = Math.floor(totalMinutes / 1_440);
  const hours = Math.floor(totalMinutes % 1_440 / 60);
  const minutes = totalMinutes % 60;
  return [days ? `${days} d` : "", hours ? `${hours} hr` : "", !days && minutes ? `${minutes} min` : ""]
    .filter(Boolean).join(" ") || "now";
}

function utcDayKey(value) {
  return new Date(value).toISOString().slice(0, 10);
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}
