import assert from "node:assert/strict";
import test from "node:test";
import { activateLanguage } from "../src/i18n.js";
import { formatCodexResetCredits, formatExtraUsage, poolDisplayName, providerQuotaDetailRows, visibleScopedWindows } from "../src/quota-details.js";

const window = { usedPercent: 25, windowMinutes: 10_080 };
const provider = {
  providerID: "claude",
  scopedWindows: [
    { scopeID: "fable", displayName: "Fable", window },
    { scopeID: "codex_bengalfox_session", displayName: "GPT-5.3-Codex-Spark", window },
    { scopeID: "antigravity_3p_5h", displayName: "Claude / Third-party", window },
    { scopeID: "future_scope", displayName: "Future model", window },
  ],
};

test("Scoped quota preferences gate only their known scopes and keep unknown scopes visible", () => {
  assert.deepEqual(visibleScopedWindows(provider).map((scope) => scope.scopeID), ["fable", "future_scope"]);
  assert.deepEqual(visibleScopedWindows(provider, { showFableQuota: false }).map((scope) => scope.scopeID), ["future_scope"]);
  assert.deepEqual(visibleScopedWindows(provider, { showCodexSparkQuota: true }).map((scope) => scope.scopeID), ["fable", "codex_bengalfox_session", "future_scope"]);
  assert.deepEqual(visibleScopedWindows(provider, { showAntigravityThirdPartyQuota: true }).map((scope) => scope.scopeID), ["fable", "antigravity_3p_5h", "future_scope"]);
  assert.deepEqual(visibleScopedWindows(provider, {
    showFableQuota: true,
    showCodexSparkQuota: true,
    showAntigravityThirdPartyQuota: true,
  }).map((scope) => scope.scopeID), ["fable", "codex_bengalfox_session", "antigravity_3p_5h", "future_scope"]);
});

test("Extra usage and reset-credit rows format valid values and omit absent data", () => {
  assert.equal(formatExtraUsage({ spentUSD: 12.5, monthlyLimitUSD: 50 }), "$12.50 spent / $50.00");
  assert.equal(formatExtraUsage({ spentUSD: 2 }), "$2.00 spent");
  assert.equal(formatExtraUsage(undefined), undefined);
  assert.equal(formatCodexResetCredits({ availableCount: 3 }), "3 available");
  assert.equal(formatCodexResetCredits(undefined), undefined);
  assert.deepEqual(providerQuotaDetailRows({}), []);
  assert.deepEqual(providerQuotaDetailRows({ codexResetCredits: { availableCount: 0 } }), [{
    key: "codex-reset-credits",
    label: "Rate-limit reset cards",
    value: "0 available",
  }]);
  assert.deepEqual(providerQuotaDetailRows({ accountBalance: { amount: 0, currencyCode: "CNY" } }), [{
    key: "account-balance",
    label: "Account Balance",
    value: "CN¥0.00",
  }]);
  activateLanguage("zh-Hans");
  assert.equal(poolDisplayName("Cursor Models"), "Cursor 模型");
  assert.equal(poolDisplayName("Other Models"), "其他模型");
  activateLanguage("en");
});
