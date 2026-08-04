export function buildOverviewSummary(providers = [], now = Date.now()) {
  const entries = providers.flatMap((provider) => (provider.windows || []).flatMap((window) => {
    if (!Number.isFinite(window.usedPercent)) return [];
    return [{
      providerID: provider.providerID,
      remaining: Math.max(0, Math.min(100, 100 - window.usedPercent)),
      resetsAt: Number.isFinite(window.resetsAt) ? window.resetsAt : undefined,
    }];
  }));
  const tightest = entries.reduce((current, entry) => (
    !current || entry.remaining < current.remaining ? entry : current
  ), undefined);
  const nextReset = entries
    .filter((entry) => entry.resetsAt > now)
    .reduce((current, entry) => (
      !current || entry.resetsAt < current.resetsAt ? entry : current
    ), undefined);
  return { tightest, nextReset };
}
