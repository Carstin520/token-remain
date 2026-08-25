import assert from "node:assert/strict";
import test from "node:test";
import { formatCodexResetCredits, formatExtraUsage, providerQuotaDetailRows, visibleScopedWindows } from "../src/quota-details.js";

const window = { usedPercent: 25, windowMinutes: 10_080 };
const provider = {
  providerID: "claude",
  scopedWindows: [
    { scopeID: "fable", displayName: "Fable", window },
    { scopeID: "codex_bengalfox", displayName: "GPT-5.3-Codex-Spark", window },
    { scopeID: "antigravity_3p_5h", displayName: "Claude / Third-party", window },
    { scopeID: "future_scope", displayName: "Future model", window },
  ],
};

test("Scoped quota preferences gate only their known scopes and keep unknown scopes visible", () => {
  assert.deepEqual(visibleScopedWindows(provider).map((scope) => scope.scopeID), ["fable", "future_scope"]);
  assert.deepEqual(visibleScopedWindows(provider, { showFableQuota: false }).map((scope) => scope.scopeID), ["future_scope"]);
  assert.deepEqual(visibleScopedWindows(provider, { showCodexSparkQuota: true }).map((scope) => scope.scopeID), ["fable", "codex_bengalfox", "future_scope"]);
  assert.deepEqual(visibleScopedWindows(provider, { showAntigravityThirdPartyQuota: true }).map((scope) => scope.scopeID), ["fable", "antigravity_3p_5h", "future_scope"]);
  assert.deepEqual(visibleScopedWindows(provider, {
    showFableQuota: true,
    showCodexSparkQuota: true,
    showAntigravityThirdPartyQuota: true,
  }).map((scope) => scope.scopeID), ["fable", "codex_bengalfox", "antigravity_3p_5h", "future_scope"]);
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
});
