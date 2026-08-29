// Model-level and optional quota pools whose visibility can be overridden.
// The persisted map contains only explicit "on" / "off" choices; a missing
// key is Auto and resolves from the current pool's group-wide activity.

export const SCOPED_POOL_CATALOG = Object.freeze([
  entry("claude", "fable", "settings.menubar_fable", "settings.menubar_fable_hint", false),
  entry("codex", "codex_bengalfox", "settings.menubar_codex_spark", "settings.menubar_codex_spark_hint", false),
  entry("antigravity", "antigravity_3p_", "settings.antigravity_3p", "settings.antigravity_3p_hint", true),
  entry("mimo", "mimo_daily", "settings.pool_mimo_daily", "settings.pool_mimo_daily_hint", true),
  entry("ollama", "ollama_hourly", "settings.pool_ollama_hourly", "settings.pool_ollama_hourly_hint", true),
  entry("deepseek", "deepseek_", "settings.pool_deepseek_currencies", "settings.pool_deepseek_currencies_hint", true),
  entry("openrouter", "openrouter_credits", "settings.pool_openrouter_credits", "settings.pool_openrouter_credits_hint", true),
]);

export const SCOPED_POOL_CATALOG_KEYS = new Set(SCOPED_POOL_CATALOG.map((item) => item.key));

export const LEGACY_SCOPED_POOL_MAPPINGS = Object.freeze([
  { legacyKey: "showFableQuota", catalogKey: "claude|fable" },
  { legacyKey: "showCodexSparkQuota", catalogKey: "codex|codex_bengalfox" },
  { legacyKey: "showAntigravityThirdPartyQuota", catalogKey: "antigravity|antigravity_3p_" },
]);

export function scopedPoolStorageKey(providerID, poolKey) {
  return `${providerID}|${poolKey}`;
}

export function normalizeScopedPoolVisibility(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value).filter(([key, visibility]) => (
    SCOPED_POOL_CATALOG_KEYS.has(key) && (visibility === "on" || visibility === "off")
  )));
}

export function scopedPoolEntryForWindow(scoped, providerID) {
  const scope = typeof scoped?.scopeID === "string" ? scoped.scopeID.toLowerCase() : "";
  const providerMatch = SCOPED_POOL_CATALOG.find((item) => (
    item.providerID === providerID && scope.startsWith(item.poolKey)
  ));
  if (providerMatch) return providerMatch;

  // Re-hosted or mixed-source snapshots can carry a pool under another host.
  // The pool prefix remains unique, while the visibility key keeps its catalog
  // owner so all surfaces still consult the same preference.
  const crossProviderMatch = SCOPED_POOL_CATALOG.find((item) => scope.startsWith(item.poolKey));
  if (crossProviderMatch) return crossProviderMatch;

  // Match the Mac's tolerant display-name fallback for legacy PTY snapshots.
  const displayName = typeof scoped?.displayName === "string" ? scoped.displayName.toLowerCase() : "";
  if (displayName.includes("fable")) return SCOPED_POOL_CATALOG[0];
  if (displayName.includes("codex-spark")) return SCOPED_POOL_CATALOG[1];
  return undefined;
}

export function uniqueScopedWindows(provider) {
  const order = [];
  const latestByScope = new Map();
  for (const scoped of provider?.scopedWindows || []) {
    if (typeof scoped?.scopeID !== "string" || !scoped.scopeID) continue;
    const key = scoped.scopeID.toLowerCase();
    if (!latestByScope.has(key)) order.push(key);
    latestByScope.set(key, scoped);
  }
  return order.map((key) => latestByScope.get(key));
}

export function scopedPoolIsActive(entry_, provider) {
  if (!entry_) return false;
  return uniqueScopedWindows(provider).some((scoped) => (
    scopedPoolEntryForWindow(scoped, provider?.providerID)?.key === entry_.key
      && windowIsActive(scoped.window)
  ));
}

export function resolvedScopedPoolVisibility(entry_, provider, visibilityByKey = {}) {
  const explicit = visibilityByKey?.[entry_?.key];
  if (explicit === "on") return true;
  if (explicit === "off") return false;
  return scopedPoolIsActive(entry_, provider);
}

export function scopedPoolSettingsGroups(providerOrder = [], providers = []) {
  const quotaByProvider = new Map(
    providers.filter((provider) => provider?.providerID).map((provider) => [provider.providerID, provider]),
  );
  const seen = new Set();
  return providerOrder.flatMap((providerID) => {
    if (seen.has(providerID) || !quotaByProvider.has(providerID)) return [];
    seen.add(providerID);
    const entries = SCOPED_POOL_CATALOG.filter((item) => item.providerID === providerID);
    return entries.length ? [{ providerID, entries }] : [];
  });
}

function entry(providerID, poolKey, titleKey, detailKey, followsExpansion) {
  return Object.freeze({
    providerID,
    poolKey,
    titleKey,
    detailKey,
    followsExpansion,
    key: scopedPoolStorageKey(providerID, poolKey),
  });
}

function windowIsActive(window) {
  return window?.usedPercent > 0 || window?.remainingBalance?.amount > 0;
}
