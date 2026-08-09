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

export function usageTrendModel(history, { range = 14, metric = "tokens", providerIDs = ["claude", "codex"] } = {}) {
  const safeRange = TREND_RANGES.includes(range) ? range : 14;
  const safeMetric = TREND_METRICS.includes(metric) ? metric : "tokens";
  const source = Array.isArray(history?.days) ? history.days : [];
  const days = source.slice(-safeRange).map((day) => {
    const values = Object.fromEntries(providerIDs.map((id) => {
      const raw = safeMetric === "tokens" ? day?.[`${id}Tokens`] : day?.[`${id}Cost`];
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
