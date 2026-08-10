const MAXIMUM_DAYS = 30;

export function agentsForUsageDay(day) {
  if (!day) return [];
  const source = Array.isArray(day.agents) ? day.agents : [
    { id: "claude", tokens: day.claudeTokens, cost: day.claudeCost },
    { id: "codex", tokens: day.codexTokens, cost: day.codexCost },
  ];
  return source.flatMap((agent) => {
    const id = normalizeAgentID(agent?.id);
    const tokens = numeric(agent?.tokens);
    const cost = numeric(agent?.cost);
    if (!id || (tokens <= 0 && cost <= 0)) return [];
    return [{
      id,
      tokens,
      cost,
      unpricedModels: Array.isArray(agent.unpricedModels) ? agent.unpricedModels.filter((value) => typeof value === "string") : [],
    }];
  });
}

export function usageDayTotals(day) {
  const agents = agentsForUsageDay(day);
  const tokens = agents.reduce((total, agent) => total + agent.tokens, 0);
  const knownCost = agents.reduce((total, agent) => total + agent.cost, 0);
  const hasUnpricedUsage = agents.some((agent) => agent.unpricedModels.length > 0
    || (agent.id !== "ollama" && agent.tokens > 0 && agent.cost === 0));
  return { agents, tokens, knownCost, cost: hasUnpricedUsage ? undefined : knownCost, hasUnpricedUsage };
}

export function usageProviderIDs(history, limit = 8) {
  const totals = new Map();
  for (const day of history?.days || []) {
    for (const agent of agentsForUsageDay(day)) totals.set(agent.id, (totals.get(agent.id) || 0) + agent.tokens);
  }
  return [...totals.entries()]
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    .slice(0, limit)
    .map(([id]) => id);
}

export function mergeDailyUsageHistories(localHistory, remoteHistory) {
  if (!localHistory) return remoteHistory;
  if (!remoteHistory) return localHistory;
  const localDays = new Map((localHistory.days || []).map((day) => [day.day, day]));
  const remoteDays = new Map((remoteHistory.days || []).map((day) => [day.day, day]));
  const dayKeys = [...new Set([...localDays.keys(), ...remoteDays.keys()])].sort().slice(-MAXIMUM_DAYS);
  const days = dayKeys.map((dayKey) => {
    const merged = new Map();
    for (const day of [localDays.get(dayKey), remoteDays.get(dayKey)]) {
      for (const agent of agentsForUsageDay(day)) {
        const current = merged.get(agent.id) || { id: agent.id, tokens: 0, cost: 0, unpricedModels: [] };
        current.tokens += agent.tokens;
        current.cost += agent.cost;
        current.unpricedModels = [...new Set([...current.unpricedModels, ...agent.unpricedModels])].sort();
        merged.set(agent.id, current);
      }
    }
    return withLegacyFields(dayKey, [...merged.values()]);
  });
  return {
    sourceDay: localHistory.sourceDay || remoteHistory.sourceDay,
    capturedAt: Math.max(localHistory.capturedAt || 0, remoteHistory.capturedAt || 0),
    days,
  };
}

export function withLegacyFields(day, agents) {
  const normalized = agents
    .filter((agent) => agent?.id && (numeric(agent.tokens) > 0 || numeric(agent.cost) > 0))
    .map((agent) => ({ ...agent, tokens: numeric(agent.tokens), cost: numeric(agent.cost) }))
    .sort((left, right) => right.tokens - left.tokens || left.id.localeCompare(right.id));
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
  const result = String(value || "").trim().toLowerCase();
  return /^[a-z0-9][a-z0-9._-]{0,63}$/.test(result) ? result : undefined;
}

function numeric(value) {
  return Number.isFinite(value) && value > 0 ? value : 0;
}
