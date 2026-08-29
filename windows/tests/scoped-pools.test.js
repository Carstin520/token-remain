import assert from "node:assert/strict";
import test from "node:test";
import {
  SCOPED_POOL_CATALOG,
  normalizeScopedPoolVisibility,
  resolvedScopedPoolVisibility,
  scopedPoolEntryForWindow,
  scopedPoolIsActive,
  scopedPoolSettingsGroups,
} from "../src/scoped-pools.js";

test("scoped-pool catalog mirrors macOS keys, localization, and expansion behavior", () => {
  assert.deepEqual(SCOPED_POOL_CATALOG.map((entry) => ({
    key: entry.key,
    titleKey: entry.titleKey,
    followsExpansion: entry.followsExpansion,
  })), [
    { key: "claude|fable", titleKey: "settings.menubar_fable", followsExpansion: false },
    { key: "codex|codex_bengalfox", titleKey: "settings.menubar_codex_spark", followsExpansion: false },
    { key: "antigravity|antigravity_3p_", titleKey: "settings.antigravity_3p", followsExpansion: true },
    { key: "mimo|mimo_daily", titleKey: "settings.pool_mimo_daily", followsExpansion: true },
    { key: "ollama|ollama_hourly", titleKey: "settings.pool_ollama_hourly", followsExpansion: true },
    { key: "deepseek|deepseek_", titleKey: "settings.pool_deepseek_currencies", followsExpansion: true },
    { key: "openrouter|openrouter_credits", titleKey: "settings.pool_openrouter_credits", followsExpansion: true },
  ]);
});

test("catalog matching is prefix-based, provider-first, and keeps legacy name fallbacks", () => {
  assert.equal(scopedPoolEntryForWindow({ scopeID: "codex_bengalfox_weekly" }, "codex")?.key, "codex|codex_bengalfox");
  assert.equal(scopedPoolEntryForWindow({ scopeID: "mimo_daily_bonus" }, "mimo")?.key, "mimo|mimo_daily");
  assert.equal(scopedPoolEntryForWindow({ scopeID: "deepseek_usd" }, "deepseek")?.key, "deepseek|deepseek_");
  assert.equal(scopedPoolEntryForWindow({ scopeID: "fable_weekly" }, "codex")?.key, "claude|fable");
  assert.equal(scopedPoolEntryForWindow({ scopeID: "legacy", displayName: "GPT-5.3-Codex-Spark" }, "codex")?.key, "codex|codex_bengalfox");
  assert.equal(scopedPoolEntryForWindow({ scopeID: "future_pool" }, "claude"), undefined);
});

test("Auto resolves group-wide activity from latest scopes and positive balances", () => {
  const entry = SCOPED_POOL_CATALOG.find((item) => item.providerID === "codex");
  const provider = {
    providerID: "codex",
    scopedWindows: [
      { scopeID: "codex_bengalfox_session", window: { usedPercent: 0 } },
      { scopeID: "codex_bengalfox_weekly", window: { usedPercent: 12 } },
    ],
  };
  assert.equal(scopedPoolIsActive(entry, provider), true);
  assert.equal(resolvedScopedPoolVisibility(entry, provider, {}), true);
  assert.equal(resolvedScopedPoolVisibility(entry, provider, { [entry.key]: "off" }), false);
  assert.equal(resolvedScopedPoolVisibility(entry, { ...provider, scopedWindows: [] }, { [entry.key]: "on" }), true);

  const deepseek = SCOPED_POOL_CATALOG.find((item) => item.providerID === "deepseek");
  assert.equal(scopedPoolIsActive(deepseek, {
    providerID: "deepseek",
    scopedWindows: [{ scopeID: "deepseek_usd", window: { usedPercent: 0, remainingBalance: { amount: 2 } } }],
  }), true);
  assert.equal(scopedPoolIsActive(deepseek, {
    providerID: "deepseek",
    scopedWindows: [
      { scopeID: "deepseek_usd", window: { usedPercent: 50 } },
      { scopeID: "deepseek_usd", window: { usedPercent: 0, remainingBalance: { amount: 0 } } },
    ],
  }), false, "the latest duplicate is the active-state authority");
});

test("visibility validation and settings groups keep only catalog-backed connected apps", () => {
  assert.deepEqual(normalizeScopedPoolVisibility({
    "claude|fable": "off",
    "codex|codex_bengalfox": "auto",
    "future|pool": "on",
  }), { "claude|fable": "off" });
  assert.deepEqual(
    scopedPoolSettingsGroups(
      ["codex", "cursor", "claude", "codex"],
      [{ providerID: "claude" }, { providerID: "codex" }],
    ).map((group) => group.providerID),
    ["codex", "claude"],
  );
});
