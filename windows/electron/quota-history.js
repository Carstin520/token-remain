export const QUOTA_HISTORY_BUCKET_MS = 15 * 60 * 1000;
export const QUOTA_HISTORY_RETENTION_MS = 45 * 24 * 60 * 60 * 1000;

const PROVIDER_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/;

function primaryWindow(provider) {
  const windows = (provider?.windows || []).filter((window) => Number.isFinite(window?.usedPercent));
  if (!windows.length) return undefined;
  const rolling = windows.filter((window) => Number.isInteger(window.windowMinutes) && window.windowMinutes > 0);
  if (!rolling.length) return windows[0];
  return rolling.reduce((current, window) => (window.windowMinutes < current.windowMinutes ? window : current));
}

function bucket(value) {
  return Math.floor(value / QUOTA_HISTORY_BUCKET_MS);
}

function normalizeSample(sample, now) {
  if (!PROVIDER_ID.test(sample?.providerID || "")) return undefined;
  if (!Number.isFinite(sample.usedPercent)) return undefined;
  if (!Number.isInteger(sample.windowMinutes) || sample.windowMinutes < 0 || sample.windowMinutes > 525_600) return undefined;
  if (!Number.isFinite(sample.capturedAt) || sample.capturedAt > now + 5 * 60 * 1000) return undefined;
  const resetsAt = Number.isFinite(sample.resetsAt) ? sample.resetsAt : undefined;
  return {
    providerID: sample.providerID,
    usedPercent: Math.min(100, Math.max(0, sample.usedPercent)),
    windowMinutes: sample.windowMinutes,
    resetsAt,
    capturedAt: sample.capturedAt,
  };
}

export function normalizeQuotaUsageHistory(history, now = Date.now()) {
  const cutoff = now - QUOTA_HISTORY_RETENTION_MS;
  const samples = Array.isArray(history?.samples)
    ? history.samples
      .map((sample) => normalizeSample(sample, now))
      .filter((sample) => sample && sample.capturedAt >= cutoff)
    : [];
  samples.sort((left, right) => left.capturedAt - right.capturedAt || left.providerID.localeCompare(right.providerID));
  return { samples };
}

/// Mirrors macOS QuotaUsageHistory: one latest sample per provider per
/// fifteen-minute bucket, retained for forty-five days.
export function recordQuotaUsageHistory(history, providers, now = Date.now()) {
  const normalized = normalizeQuotaUsageHistory(history, now);
  const samples = [...normalized.samples];

  for (const provider of Array.isArray(providers) ? providers : []) {
    if (!PROVIDER_ID.test(provider?.providerID || "")) continue;
    const window = primaryWindow(provider);
    if (!window) continue;
    const capturedAt = Number.isFinite(provider.capturedAt) ? Math.min(provider.capturedAt, now) : now;
    const sample = normalizeSample({
      providerID: provider.providerID,
      usedPercent: window.usedPercent,
      windowMinutes: Number.isInteger(window.windowMinutes) ? window.windowMinutes : 0,
      resetsAt: window.resetsAt,
      capturedAt,
    }, now);
    if (!sample) continue;

    const index = samples.findIndex((item) => (
      item.providerID === sample.providerID && bucket(item.capturedAt) === bucket(sample.capturedAt)
    ));
    if (index >= 0) {
      if (sample.capturedAt >= samples[index].capturedAt) samples[index] = sample;
    } else {
      samples.push(sample);
    }
  }

  samples.sort((left, right) => left.capturedAt - right.capturedAt || left.providerID.localeCompare(right.providerID));
  return { samples };
}
