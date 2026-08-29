import { canonicalLocalSourceID, normalizeDisabledLocalUsageSources } from "./local-sources.js";

const MAXIMUM_DAYS = 30;
const MAXIMUM_AGENTS_PER_DAY = 32;
export const MAXIMUM_MODELS_PER_AGENT = 8;
const MAXIMUM_MODEL_NAME_LENGTH = 512;
const MAXIMUM_CONSTITUENT_COUNT = 1_000_000;

export function agentsForUsageDay(day, disabledSourceIDs = []) {
  if (!day) return [];
  const disabled = new Set(normalizeDisabledLocalUsageSources(disabledSourceIDs));
  const source = Array.isArray(day.agents) ? day.agents.slice(0, MAXIMUM_AGENTS_PER_DAY) : [
    { id: "claude", tokens: day.claudeTokens, cost: day.claudeCost },
    { id: "codex", tokens: day.codexTokens, cost: day.codexCost },
  ];
  return source.flatMap((agent) => {
    const id = normalizeAgentID(agent?.id);
    const tokens = numeric(agent?.tokens);
    const cost = numeric(agent?.cost);
    if (!id || disabled.has(id) || (tokens <= 0 && cost <= 0)) return [];
    const models = boundedUsageModels(agent?.models);
    return [{
      id,
      tokens,
      cost,
      unpricedModels: normalizeUnpricedModels(agent.unpricedModels),
      ...(models.length ? { models } : {}),
    }];
  });
}

export function usageDayTotals(day, disabledSourceIDs = []) {
  const agents = agentsForUsageDay(day, disabledSourceIDs);
  const tokens = agents.reduce((total, agent) => total + agent.tokens, 0);
  const knownCost = agents.reduce((total, agent) => total + agent.cost, 0);
  const hasUnpricedUsage = agents.some((agent) => agent.unpricedModels.length > 0
    || (agent.id !== "ollama" && agent.tokens > 0 && agent.cost === 0));
  return { agents, tokens, knownCost, cost: hasUnpricedUsage ? undefined : knownCost, hasUnpricedUsage };
}

export function usageProviderIDs(history, limit = 8, disabledSourceIDs = []) {
  const totals = new Map();
  for (const day of history?.days || []) {
    for (const agent of agentsForUsageDay(day, disabledSourceIDs)) totals.set(agent.id, (totals.get(agent.id) || 0) + agent.tokens);
  }
  return [...totals.entries()]
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    .slice(0, limit)
    .map(([id]) => id);
}

export function mergeDailyUsageHistories(localHistory, remoteHistory, disabledSourceIDs = []) {
  if (!localHistory) return filterDailyUsageHistory(remoteHistory, disabledSourceIDs);
  if (!remoteHistory) return filterDailyUsageHistory(localHistory, disabledSourceIDs);
  const localDays = new Map((localHistory.days || []).map((day) => [day.day, day]));
  const remoteDays = new Map((remoteHistory.days || []).map((day) => [day.day, day]));
  const dayKeys = [...new Set([...localDays.keys(), ...remoteDays.keys()])].sort().slice(-MAXIMUM_DAYS);
  const days = dayKeys.map((dayKey) => {
    const merged = new Map();
    for (const day of [localDays.get(dayKey), remoteDays.get(dayKey)]) {
      for (const agent of agentsForUsageDay(day)) {
        const current = merged.get(agent.id) || { id: agent.id, tokens: 0, cost: 0, unpricedModels: [], models: [] };
        current.tokens += agent.tokens;
        current.cost += agent.cost;
        current.unpricedModels = [...new Set([...current.unpricedModels, ...agent.unpricedModels])].sort();
        current.models = boundedUsageModels([...(current.models || []), ...(agent.models || [])]);
        merged.set(agent.id, current);
      }
    }
    return withLegacyFields(dayKey, [...merged.values()]);
  });
  return filterDailyUsageHistory({
    sourceDay: localHistory.sourceDay || remoteHistory.sourceDay,
    capturedAt: Math.max(localHistory.capturedAt || 0, remoteHistory.capturedAt || 0),
    days,
  }, disabledSourceIDs);
}

export function filterDailyUsageHistory(history, disabledSourceIDs = []) {
  const normalized = normalizeDailyUsageHistory(history);
  if (!normalized) return undefined;
  const disabled = normalizeDisabledLocalUsageSources(disabledSourceIDs);
  if (!disabled.length) return normalized;
  return {
    ...normalized,
    days: normalized.days.map((day) => withLegacyFields(day.day, agentsForUsageDay(day, disabled))),
  };
}

export function normalizeDailyUsageHistory(history) {
  if (!history || typeof history !== "object" || !Array.isArray(history.days)) return undefined;
  const byDay = new Map();
  for (const day of history.days) {
    if (!validDayKey(day?.day)) continue;
    byDay.set(day.day, withLegacyFields(day.day, agentsForUsageDay(day)));
  }
  const normalized = {
    ...(validDayKey(history.sourceDay) ? { sourceDay: history.sourceDay } : {}),
    ...(Number.isFinite(history.capturedAt) && history.capturedAt >= 0 ? { capturedAt: history.capturedAt } : {}),
    days: [...byDay.values()].sort((left, right) => left.day.localeCompare(right.day)).slice(-MAXIMUM_DAYS),
  };
  return normalized;
}

/// Mirrors DailyUsageHistory.boundedModels on macOS: at most eight rows total.
/// Once the bound is exceeded, seven named rows remain and the tail is summed
/// into one `other` row, including token categories, cost, and model count.
export function boundedUsageModels(rows, cap = MAXIMUM_MODELS_PER_AGENT) {
  if (!Number.isInteger(cap) || cap <= 0 || !Array.isArray(rows)) return [];
  const merged = new Map();
  for (const row of rows) {
    const id = normalizeModelID(row?.id);
    if (!id || id === "<synthetic>") continue;
    const previous = merged.get(id);
    merged.set(id, {
      id,
      inputTokens: (previous?.inputTokens || 0) + numeric(row?.inputTokens),
      outputTokens: (previous?.outputTokens || 0) + numeric(row?.outputTokens),
      cacheTokens: (previous?.cacheTokens || 0) + numeric(row?.cacheTokens),
      cost: (previous?.cost || 0) + numeric(row?.cost),
      constituentCount: Math.max(previous?.constituentCount || 1, boundedConstituentCount(row?.constituentCount)),
    });
  }
  const carriedOther = merged.get("other");
  merged.delete("other");
  const ordered = [...merged.values()].sort((left, right) => (
    modelTotalTokens(right) - modelTotalTokens(left)
      || right.cost - left.cost
      || left.id.localeCompare(right.id)
  ));
  if (ordered.length + (carriedOther ? 1 : 0) <= cap) {
    return [...ordered, ...(carriedOther ? [carriedOther] : [])];
  }
  const kept = ordered.slice(0, Math.max(0, cap - 1));
  const other = combineOtherModels([...ordered.slice(Math.max(0, cap - 1)), ...(carriedOther ? [carriedOther] : [])]);
  return other && (modelTotalTokens(other) > 0 || other.cost > 0) ? [...kept, other] : kept;
}

export function withLegacyFields(day, agents) {
  const normalized = agents.flatMap((agent) => {
    const id = normalizeAgentID(agent?.id);
    const tokens = numeric(agent?.tokens);
    const cost = numeric(agent?.cost);
    if (!id || (tokens <= 0 && cost <= 0)) return [];
    const models = boundedUsageModels(agent?.models);
    return [{
      id,
      tokens,
      cost,
      unpricedModels: normalizeUnpricedModels(agent?.unpricedModels),
      ...(models.length ? { models } : {}),
    }];
  })
    .sort((left, right) => right.tokens - left.tokens || left.id.localeCompare(right.id))
    .slice(0, MAXIMUM_AGENTS_PER_DAY);
  const byID = new Map(normalized.map((agent) => [agent.id, agent]));
  return {
    day,
    agents: normalized,
    claudeTokens: byID.get("claude")?.tokens || 0,
    claudeCost: byID.get("claude")?.cost || 0,
    codexTokens: byID.get("codex")?.tokens || 0,
    codexCost: byID.get("codex")?.cost || 0,
  };
}

function normalizeAgentID(value) {
  const result = canonicalLocalSourceID(value);
  return /^[a-z0-9][a-z0-9._-]{0,63}$/.test(result) ? result : undefined;
}

function numeric(value) {
  return Number.isFinite(value) && value > 0 ? value : 0;
}

function normalizeModelID(value) {
  if (typeof value !== "string" || value.length > MAXIMUM_MODEL_NAME_LENGTH || /[\u0000-\u001f\u007f]/.test(value)) return undefined;
  const result = value.trim().toLowerCase();
  return result || undefined;
}

function normalizeUnpricedModels(value) {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.flatMap((item) => {
    const id = normalizeModelID(item);
    return id ? [id] : [];
  }))].slice(0, 32).sort();
}

function boundedConstituentCount(value) {
  return Number.isSafeInteger(value) && value > 0 ? Math.min(value, MAXIMUM_CONSTITUENT_COUNT) : 1;
}

function modelTotalTokens(model) {
  return model.inputTokens + model.outputTokens + model.cacheTokens;
}

function combineOtherModels(rows) {
  if (!rows.length) return undefined;
  return rows.reduce((result, row) => ({
    id: "other",
    inputTokens: result.inputTokens + row.inputTokens,
    outputTokens: result.outputTokens + row.outputTokens,
    cacheTokens: result.cacheTokens + row.cacheTokens,
    cost: result.cost + row.cost,
    constituentCount: Math.min(MAXIMUM_CONSTITUENT_COUNT, result.constituentCount + row.constituentCount),
  }), { id: "other", inputTokens: 0, outputTokens: 0, cacheTokens: 0, cost: 0, constituentCount: 0 });
}

function validDayKey(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = Date.parse(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed) && new Date(parsed).toISOString().slice(0, 10) === value;
}
