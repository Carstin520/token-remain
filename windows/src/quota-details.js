import { formatBalance, windowTitle } from "./format.js";
import { tr, trKey } from "./i18n.js";
import { CODEX_USAGE_URL } from "../electron/codex-usage.js";
import {
  resolvedScopedPoolVisibility,
  scopedPoolEntryForWindow,
  uniqueScopedWindows,
} from "./scoped-pools.js";

export function visibleScopedWindows(provider, preferences = {}) {
  return uniqueScopedWindows(provider).filter((scoped) => {
    const entry = scopedPoolEntryForWindow(scoped, provider?.providerID);
    // Account-level sibling pools and future scopes are outside this catalog
    // and remain visible on Dashboard cards, matching the Mac's behavior.
    return !entry || resolvedScopedPoolVisibility(entry, provider, preferences.scopedPoolVisibility);
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

/// Mac parity: host identity stays in the card header while the actual billing
/// source prefixes each quota-window title (`DeepSeek API · 5 hr window`).
export function attributedQuotaWindowTitle(window, { scopeName, attribution } = {}) {
  const duration = windowTitle(window?.windowMinutes);
  const scoped = scopeName ? `${poolDisplayName(scopeName)} · ${duration}` : duration;
  const source = attribution?.displayName;
  return source ? `${tr(source)} · ${scoped}` : scoped;
}

function usd(amount) {
  return formatBalance({ amount, currencyCode: "USD" });
}
