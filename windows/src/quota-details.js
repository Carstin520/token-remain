import { formatBalance } from "./format.js";
import { tr, trKey } from "./i18n.js";
import { CODEX_USAGE_URL } from "../electron/codex-usage.js";

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
  const accountBalance = provider?.accountBalance;
  const balance = Number.isFinite(accountBalance?.amount) && accountBalance.amount >= 0 && accountBalance.currencyCode
    ? formatBalance(accountBalance)
    : undefined;
  return [
    ...(resetCredits ? [
      {
        key: "codex-reset-credits",
        label: trKey("codex.reset_credits.title"),
        value: resetCredits,
        action: { label: trKey("codex.reset_credits.manage"), url: CODEX_USAGE_URL },
      },
      { key: "codex-reset-credits-expiration", note: trKey("codex.reset_credits.expiration") },
    ] : []),
    ...(extraUsage ? [{ key: "extra-usage", label: trKey("quota.extra_usage"), value: extraUsage }] : []),
    ...(balance ? [{ key: "account-balance", label: trKey("quota.account_balance"), value: balance }] : []),
  ];
}

export function poolDisplayName(value) {
  return typeof value === "string" && value ? tr(value) : value;
}

function isFableScope(scope) {
  return scope.scopeID.toLowerCase().startsWith("fable") || /fable/i.test(scope.displayName || "");
}

function isCodexSparkScope(scope) {
  return scope.scopeID.toLowerCase().startsWith("codex_bengalfox") || /codex-spark/i.test(scope.displayName || "");
}

function isAntigravityThirdPartyScope(scope) {
  return scope.scopeID.toLowerCase().startsWith("antigravity_3p_");
}

function usd(amount) {
  return formatBalance({ amount, currencyCode: "USD" });
}
