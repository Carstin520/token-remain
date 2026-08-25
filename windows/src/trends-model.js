import { localSourceDisplayName } from "./local-sources.js";
import { agentsForUsageDay, boundedUsageModels } from "./usage-history.js";

export const TREND_RANGES = [7, 14, 30];
export const TREND_METRICS = ["tokens", "cost"];

export function niceCeiling(value) {
  if (!Number.isFinite(value) || value <= 0) return 1;
  const exponent = Math.floor(Math.log10(value));
  const base = 10 ** exponent;
  const fraction = value / base;
  const niceFraction = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 2.5 ? 2.5 : fraction <= 5 ? 5 : 10;
  return niceFraction * base;
}

export function usageTrendModel(history, {
  range = 14,
  metric = "tokens",
  providerIDs = ["claude", "codex"],
  disabledSourceIDs = [],
} = {}) {
  const safeRange = TREND_RANGES.includes(range) ? range : 14;
  const safeMetric = TREND_METRICS.includes(metric) ? metric : "tokens";
  const source = Array.isArray(history?.days) ? history.days : [];
  const days = source.slice(-safeRange).map((day) => {
    const agents = new Map(agentsForUsageDay(day, disabledSourceIDs).map((agent) => [agent.id, agent]));
    const values = Object.fromEntries(providerIDs.map((id) => {
      const raw = safeMetric === "tokens" ? agents.get(id)?.tokens : agents.get(id)?.cost;
      return [id, Number.isFinite(raw) && raw > 0 ? raw : 0];
    }));
    return {
      day: day?.day,
      values,
      total: Object.values(values).reduce((sum, value) => sum + value, 0),
    };
  });
  const maximum = niceCeiling(Math.max(0, ...days.map((day) => day.total)));
  return { days, maximum, metric: safeMetric, range: safeRange, providerIDs };
}

export function togglePinnedDay(currentDayID, selectedDayID) {
  return currentDayID === selectedDayID ? undefined : selectedDayID;
}

export function stepPinnedDay(dayIDs, currentDayID, direction) {
  const days = Array.isArray(dayIDs) ? dayIDs.filter((day) => typeof day === "string") : [];
  if (!days.length) return undefined;
  const currentIndex = days.indexOf(currentDayID);
  const resolvedIndex = currentIndex >= 0 ? currentIndex : days.length - 1;
  if (direction === "left" || direction === -1) return days[Math.max(0, resolvedIndex - 1)];
  if (direction === "right" || direction === 1) return days[Math.min(days.length - 1, resolvedIndex + 1)];
  return days[resolvedIndex];
}

export function unpinDay() {
  return undefined;
}

/// Projects one retained day into the compact panel shown below the chart.
/// Retention is capped separately at eight rows; this presentation keeps the
/// five leading named models and rolls the remaining visible rows into Other.
export function trendDayModelBreakdown(day, agentIDs, metric = "tokens", namedLimit = 5) {
  const safeMetric = TREND_METRICS.includes(metric) ? metric : "tokens";
  const byID = new Map(agentsForUsageDay(day).map((agent) => [agent.id, agent]));
  const groups = (Array.isArray(agentIDs) ? agentIDs : []).flatMap((requestedID) => {
    const agentID = String(requestedID || "").toLowerCase();
    const agent = byID.get(agentID);
    const models = boundedUsageModels(agent?.models);
    if (!agent || !models.length) return [];
    const unpriced = new Set((agent.unpricedModels || []).map((id) => String(id).toLowerCase()));
    const namedIDs = new Set(models.filter((model) => model.id !== "other").map((model) => model.id.toLowerCase()));
    const isUnpriced = (model) => unpriced.has(model.id.toLowerCase())
      || (model.id === "other" && [...unpriced].some((id) => !namedIDs.has(id)));
    const named = models.filter((model) => model.id !== "other").sort((left, right) => {
      if (safeMetric === "cost") {
        const pricingOrder = Number(isUnpriced(left)) - Number(isUnpriced(right));
        if (pricingOrder) return pricingOrder;
        if (left.cost !== right.cost) return right.cost - left.cost;
      } else {
        const tokenOrder = modelTotalTokens(right) - modelTotalTokens(left);
        if (tokenOrder) return tokenOrder;
      }
      return left.id.localeCompare(right.id);
    });
    const limit = Math.max(0, Number.isInteger(namedLimit) ? namedLimit : 5);
    const kept = named.slice(0, limit);
    const tail = [...named.slice(limit), ...models.filter((model) => model.id === "other")];
    const otherIsUnpriced = tail.some(isUnpriced);
    const displayed = tail.length ? [...kept, combineDisplayedOther(tail)] : kept;
    const metricTotal = displayed.reduce((total, model) => (
      total + (safeMetric === "tokens" ? modelTotalTokens(model) : model.cost)
    ), 0);
    return [{
      id: agentID,
      displayName: localSourceDisplayName(agentID),
      rows: displayed.map((model) => {
        const totalTokens = modelTotalTokens(model);
        const metricValue = safeMetric === "tokens" ? totalTokens : model.cost;
        return {
          ...model,
          displayName: trendModelDisplayName(model),
          totalTokens,
          share: metricTotal > 0 ? metricValue / metricTotal : 0,
          isUnpriced: model.id === "other" ? otherIsUnpriced : isUnpriced(model),
        };
      }),
    }];
  });
  return { day: day?.day, groups };
}

export function trendModelDisplayName(model) {
  if (model?.id === "other") return { key: "trends.model_other_format", count: model.constituentCount };
  const raw = String(model?.id || "");
  const withoutClaude = raw.startsWith("claude-") ? raw.slice("claude-".length) : raw;
  return withoutClaude.length > 28 ? `${withoutClaude.slice(0, 27)}…` : withoutClaude;
}

export function compactAxisValue(value, metric = "tokens") {
  if (metric === "cost") return value >= 100 ? `$${value.toFixed(0)}` : `$${value.toFixed(1)}`;
  for (const [threshold, suffix] of [[1_000_000_000, "B"], [1_000_000, "M"], [1_000, "K"]]) {
    if (value >= threshold) {
      const scaled = value / threshold;
      return `${scaled >= 100 ? scaled.toFixed(0) : scaled.toFixed(1)}${suffix}`;
    }
  }
  return value.toFixed(0);
}

export function linePoints(values, width = 100, height = 20) {
  if (!Array.isArray(values) || !values.length) return "";
  const maximum = Math.max(1, ...values.map((value) => Number.isFinite(value) ? value : 0));
  const denominator = Math.max(1, values.length - 1);
  return values.map((value, index) => {
    const x = width * index / denominator;
    const y = height - height * Math.max(0, Number.isFinite(value) ? value : 0) / maximum;
    return `${x.toFixed(2)},${y.toFixed(2)}`;
  }).join(" ");
}

export function quotaTrendRows(history, providers, range = 7, now = Date.now()) {
  const safeRange = TREND_RANGES.includes(range) ? range : 7;
  const cutoff = now - safeRange * 24 * 60 * 60 * 1000;
  const samples = Array.isArray(history?.samples) ? history.samples : [];
  return (Array.isArray(providers) ? providers : []).flatMap((provider) => {
    const providerSamples = samples
      .filter((sample) => sample?.providerID === provider?.providerID && Number.isFinite(sample.capturedAt) && sample.capturedAt >= cutoff)
      .sort((left, right) => left.capturedAt - right.capturedAt);
    if (!providerSamples.length) return [];
    return [{
      providerID: provider.providerID,
      samples: providerSamples,
      latest: providerSamples.at(-1),
      points: quotaLinePoints(providerSamples, cutoff, now),
    }];
  });
}

export function quotaLinePoints(samples, cutoff, now, width = 100, height = 38) {
  const duration = Math.max(1, now - cutoff);
  return samples.map((sample) => {
    const x = width * Math.min(1, Math.max(0, (sample.capturedAt - cutoff) / duration));
    const y = height * (1 - Math.min(100, Math.max(0, sample.usedPercent)) / 100);
    return `${x.toFixed(2)},${y.toFixed(2)}`;
  }).join(" ");
}

function modelTotalTokens(model) {
  return model.inputTokens + model.outputTokens + model.cacheTokens;
}

function combineDisplayedOther(rows) {
  return rows.reduce((other, row) => ({
    id: "other",
    inputTokens: other.inputTokens + row.inputTokens,
    outputTokens: other.outputTokens + row.outputTokens,
    cacheTokens: other.cacheTokens + row.cacheTokens,
    cost: other.cost + row.cost,
    constituentCount: other.constituentCount + row.constituentCount,
  }), { id: "other", inputTokens: 0, outputTokens: 0, cacheTokens: 0, cost: 0, constituentCount: 0 });
}
