import { formatBalance } from "./format.js";
import { trKey } from "./i18n.js";

export function visibleScopedWindows(provider, preferences = {}) {
  const order = [];
  const latestByScope = new Map();
  for (const scope of provider?.scopedWindows || []) {
    if (typeof scope?.scopeID !== "string" || !scope.scopeID) continue;
    const key = scope.scopeID.toLowerCase();
    if (!latestByScope.has(key)) order.push(key);
    latestByScope.set(key, scope);
  }
  return order.map((key) => latestByScope.get(key)).filter((scope) => {
    if (isFableScope(scope)) return preferences.showFableQuota !== false;
    if (isCodexSparkScope(scope)) return preferences.showCodexSparkQuota === true;
    if (isAntigravityThirdPartyScope(scope)) return preferences.showAntigravityThirdPartyQuota === true;
    return true;
  });
}

export function formatExtraUsage(extraUsage) {
  if (!Number.isFinite(extraUsage?.spentUSD) || extraUsage.spentUSD < 0) return undefined;
  const spent = trKey("quota.spent", [usd(extraUsage.spentUSD)]);
  if (!Number.isFinite(extraUsage.monthlyLimitUSD) || extraUsage.monthlyLimitUSD <= 0) return spent;
  return `${spent} / ${usd(extraUsage.monthlyLimitUSD)}`;
}

export function formatCodexResetCredits(credits) {
  if (!Number.isSafeInteger(credits?.availableCount) || credits.availableCount < 0) return undefined;
  return trKey("codex.reset_credits.available_balance", [credits.availableCount]);
}

export function providerQuotaDetailRows(provider) {
  const resetCredits = formatCodexResetCredits(provider?.codexResetCredits);
  const extraUsage = formatExtraUsage(provider?.extraUsage);
  return [
    ...(resetCredits ? [{ key: "codex-reset-credits", label: trKey("codex.reset_credits.title"), value: resetCredits }] : []),
    ...(extraUsage ? [{ key: "extra-usage", label: trKey("quota.extra_usage"), value: extraUsage }] : []),
  ];
}

function isFableScope(scope) {
  return scope.scopeID.toLowerCase().startsWith("fable") || /fable/i.test(scope.displayName || "");
}

function isCodexSparkScope(scope) {
  return scope.scopeID.toLowerCase() === "codex_bengalfox" || /codex-spark/i.test(scope.displayName || "");
}

function isAntigravityThirdPartyScope(scope) {
  return scope.scopeID.toLowerCase().startsWith("antigravity_3p_");
}

function usd(amount) {
  return formatBalance({ amount, currencyCode: "USD" });
}
