import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { StateStore } from "../electron/state-store.js";

const safeStorage = {
  isEncryptionAvailable: () => true,
  encryptString: (value) => Buffer.from(`protected:${value}`, "utf8"),
  decryptString: (value) => value.toString("utf8").replace(/^protected:/, ""),
};

test("Remote usage history is protected at rest and restored at launch", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-state-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    const remoteSnapshot = {
      sourceInstanceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      sequence: 2,
      dailyUsageHistory: {
        sourceDay: "2026-08-04",
        capturedAt: 1_786_000_000_000,
        days: [{ day: "2026-08-04", claudeTokens: 123_456_789, claudeCost: 12.34, codexTokens: 0, codexCost: 0 }],
      },
    };
    store.setRemoteSnapshot(remoteSnapshot);
    await store.save();

    const onDisk = await readFile(join(directory, "state-v1.json"), "utf8");
    assert.doesNotMatch(onDisk, /123456789|claudeTokens|dailyUsageHistory/);
    assert.match(onDisk, /protectedRemoteSnapshot/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.deepEqual(restored.state.remoteSnapshot, remoteSnapshot);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Quota snapshots accumulate locally and remain protected at rest", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-quota-history-"));
  try {
    const now = Date.now();
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    store.recordQuotaUsage([{
      providerID: "codex",
      capturedAt: now,
      windows: [{ usedPercent: 37, windowMinutes: 300, resetsAt: now + 60_000 }],
    }], now);
    await store.save();

    const onDisk = await readFile(join(directory, "state-v1.json"), "utf8");
    assert.doesNotMatch(onDisk, /"usedPercent"\s*:\s*37|"quotaUsageHistory"/);
    assert.match(onDisk, /protectedQuotaUsageHistory/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.quotaUsageHistory.samples[0].providerID, "codex");
    assert.equal(restored.state.quotaUsageHistory.samples[0].usedPercent, 37);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Local ccusage aggregates remain protected at rest", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-local-usage-"));
  try {
    const history = {
      sourceDay: "2026-08-10",
      capturedAt: 1_786_000_000_000,
      days: [{
        day: "2026-08-10",
        agents: [{ id: "gemini", tokens: 987_654_321, cost: 3.21, unpricedModels: [] }],
        claudeTokens: 0,
        claudeCost: 0,
        codexTokens: 0,
        codexCost: 0,
      }],
    };
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    store.setLocalDailyUsageHistory(history);
    await store.save();

    const onDisk = await readFile(join(directory, "state-v1.json"), "utf8");
    assert.doesNotMatch(onDisk, /987654321|gemini|localDailyUsageHistory/);
    assert.match(onDisk, /protectedLocalDailyUsageHistory/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.deepEqual(restored.state.localDailyUsageHistory, history);
    assert.equal(restored.state.localDailyUsageHistory.days[0].agents[0].models, undefined);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Retained per-model usage stays inside the encrypted local history", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-local-model-usage-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    store.setLocalDailyUsageHistory({
      sourceDay: "2026-08-25",
      capturedAt: 1_787_625_600_000,
      days: [{ day: "2026-08-25", agents: [{
        id: "codex",
        tokens: 100,
        cost: 0.5,
        unpricedModels: [],
        models: [{ id: "gpt-5.3-codex", inputTokens: 40, outputTokens: 20, cacheTokens: 40, cost: 0.5 }],
      }] }],
    });
    await store.save();

    const onDisk = await readFile(join(directory, "state-v1.json"), "utf8");
    assert.doesNotMatch(onDisk, /gpt-5\.3-codex|inputTokens|localDailyUsageHistory/);
    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.deepEqual(restored.state.localDailyUsageHistory.days[0].agents[0].models, [{
      id: "gpt-5.3-codex",
      inputTokens: 40,
      outputTokens: 20,
      cacheTokens: 40,
      cost: 0.5,
      constituentCount: 1,
    }]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("disabled local usage sources default, validate, persist, and restore", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-local-source-preference-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.deepEqual(store.state.preferences.disabledLocalUsageSources, []);
    await store.setLocalUsageSourceEnabled(" Codex ", false);
    await store.setLocalUsageSourceEnabled("future_agent", false);
    await store.setLocalUsageSourceEnabled("codex", true);
    await assert.rejects(() => store.setLocalUsageSourceEnabled("bad source", false), /Unsupported local usage source/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.deepEqual(restored.state.preferences.disabledLocalUsageSources, ["future_agent"]);

    const persisted = JSON.parse(await readFile(join(directory, "state-v1.json"), "utf8"));
    persisted.preferences.disabledLocalUsageSources = [" Gemini ", "gemini", 42, "bad source", "-invalid"];
    await writeFile(join(directory, "state-v1.json"), JSON.stringify(persisted));
    const validated = new StateStore({ userDataPath: directory, safeStorage });
    await validated.load();
    assert.deepEqual(validated.state.preferences.disabledLocalUsageSources, ["gemini"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Floating shortcut preference and last position persist", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-floating-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.equal(store.state.preferences.floatingWidgetEnabled, false);
    await store.setFloatingWidgetEnabled(true);
    await store.setFloatingWidgetBounds({ x: 120, y: 80, width: 142, height: 54 });

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.preferences.floatingWidgetEnabled, true);
    assert.deepEqual(restored.state.preferences.floatingWidgetBounds, { x: 120, y: 80, width: 142, height: 54 });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("S-batch preferences default, persist, validate, and reset onboarding only", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-s-batch-preferences-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.equal(store.state.preferences.backgroundDepth, 0);
    assert.equal(store.state.preferences.taskbarIconHidden, false);
    assert.equal(store.state.preferences.zaiRegion, "global");

    await store.completeOnboarding(["zai"]);
    await store.setBackgroundDepth(0.431);
    await store.setTaskbarIconHidden(true);
    await store.setZAIRegion("china");
    await assert.rejects(() => store.setBackgroundDepth("deep"), /Unsupported background depth/);
    await assert.rejects(() => store.setZAIRegion("auto"), /Unsupported Z\.ai API region/);
    await store.resetOnboarding();

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.onboardingCompleted, false);
    assert.deepEqual(restored.state.enabledProviders, ["zai"]);
    assert.equal(restored.state.preferences.backgroundDepth, 0.44);
    assert.equal(restored.state.preferences.taskbarIconHidden, true);
    assert.equal(restored.state.preferences.zaiRegion, "china");

    const persisted = JSON.parse(await readFile(join(directory, "state-v1.json"), "utf8"));
    persisted.preferences.backgroundDepth = "bright";
    persisted.preferences.taskbarIconHidden = "yes";
    persisted.preferences.zaiRegion = "mars";
    await writeFile(join(directory, "state-v1.json"), JSON.stringify(persisted));
    const validated = new StateStore({ userDataPath: directory, safeStorage });
    await validated.load();
    assert.equal(validated.state.preferences.backgroundDepth, 0);
    assert.equal(validated.state.preferences.taskbarIconHidden, false);
    assert.equal(validated.state.preferences.zaiRegion, "global");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Scoped-pool visibility defaults to Auto, validates catalog values, and persists overrides", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-quota-preferences-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.deepEqual(store.state.preferences.scopedPoolVisibility, {});

    await store.setScopedPoolVisibility("claude|fable", "off");
    await store.setScopedPoolVisibility("codex|codex_bengalfox", "on");
    await store.setScopedPoolVisibility("claude|fable", "auto");
    await assert.rejects(() => store.setScopedPoolVisibility("future|pool", "on"), /Unsupported scoped quota pool/);
    await assert.rejects(() => store.setScopedPoolVisibility("codex|codex_bengalfox", "sometimes"), /Unsupported scoped quota visibility/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.deepEqual(restored.state.preferences.scopedPoolVisibility, { "codex|codex_bengalfox": "on" });

    const persisted = JSON.parse(await readFile(join(directory, "state-v1.json"), "utf8"));
    persisted.preferences.scopedPoolVisibility = {
      "codex|codex_bengalfox": "off",
      "claude|fable": true,
      "future|pool": "on",
    };
    await writeFile(join(directory, "state-v1.json"), JSON.stringify(persisted));
    const validated = new StateStore({ userDataPath: directory, safeStorage });
    await validated.load();
    assert.deepEqual(validated.state.preferences.scopedPoolVisibility, { "codex|codex_bengalfox": "off" });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Legacy scoped-quota booleans migrate every on/off combination and stop persisting", async () => {
  const combinations = [
    [false, false, false],
    [true, false, true],
    [false, true, true],
    [true, true, false],
  ];
  for (const [fable, codex, antigravity] of combinations) {
    const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-quota-migration-"));
    try {
      await writeFile(join(directory, "state-v1.json"), JSON.stringify({
        schemaVersion: 1,
        sourceInstanceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        sequence: 0,
        providers: [],
        notices: {},
        preferences: {
          showFableQuota: fable,
          showCodexSparkQuota: codex,
          showAntigravityThirdPartyQuota: antigravity,
        },
      }));
      const store = new StateStore({ userDataPath: directory, safeStorage });
      await store.load();
      assert.deepEqual(store.state.preferences.scopedPoolVisibility, {
        "claude|fable": fable ? "on" : "off",
        "codex|codex_bengalfox": codex ? "on" : "off",
        "antigravity|antigravity_3p_": antigravity ? "on" : "off",
      });
      const onDisk = JSON.parse(await readFile(join(directory, "state-v1.json"), "utf8"));
      assert.equal("showFableQuota" in onDisk.preferences, false);
      assert.equal("showCodexSparkQuota" in onDisk.preferences, false);
      assert.equal("showAntigravityThirdPartyQuota" in onDisk.preferences, false);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }
});

test("An existing scoped-pool override wins over its legacy boolean during migration", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-quota-migration-precedence-"));
  try {
    await writeFile(join(directory, "state-v1.json"), JSON.stringify({
      schemaVersion: 1,
      sourceInstanceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      sequence: 0,
      providers: [],
      notices: {},
      preferences: { scopedPoolVisibility: { "claude|fable": "off" }, showFableQuota: true },
    }));
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.deepEqual(store.state.preferences.scopedPoolVisibility, { "claude|fable": "off" });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Detected-installation baseline queues each disabled new app once and stays persisted on dismissal", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-detection-baseline-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    const detection = (providerID, installed = true) => ({ providerID, installed, detail: `Detected ${providerID}` });

    assert.deepEqual(await store.applyProviderDetections([detection("claude")]), []);
    assert.deepEqual(store.state.detectedInstallations, ["claude"]);
    const suggestions = await store.applyProviderDetections([detection("claude"), detection("codex")]);
    assert.deepEqual(suggestions, [{ providerID: "codex", detail: "Detected codex" }]);
    assert.deepEqual(store.state.pendingDetectionSuggestions, suggestions);

    const onDisk = JSON.parse(await readFile(join(directory, "state-v1.json"), "utf8"));
    assert.deepEqual(onDisk.detectedInstallations, ["claude", "codex"]);
    assert.equal("pendingDetectionSuggestions" in onDisk, false);

    store.dismissDetectionSuggestion("codex");
    assert.deepEqual(await store.applyProviderDetections([detection("claude"), detection("codex")]), []);
    assert.deepEqual(store.state.pendingDetectionSuggestions, []);

    await store.applyProviderDetections([detection("claude")]);
    assert.deepEqual(await store.applyProviderDetections([detection("claude"), detection("codex")]), [
      { providerID: "codex", detail: "Detected codex" },
    ]);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.deepEqual(restored.state.detectedInstallations, ["claude", "codex"]);
    assert.deepEqual(restored.state.pendingDetectionSuggestions, []);
    await restored.setProviderEnabled("cursor", true);
    assert.deepEqual(await restored.applyProviderDetections([
      detection("claude"), detection("codex"), detection("cursor"),
    ]), []);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Notification preference and bounded bookkeeping persist", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-notifications-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.equal(store.state.preferences.feedNotificationsEnabled, false);
    await store.setFeedNotificationsEnabled(true);
    store.setNotificationBookkeeping({
      providerSilencedAt: { codex: 1234, invalid: "not-a-timestamp" },
      feedSeenIDs: Array.from({ length: 250 }, (_, index) => `post-${index}`),
    });
    await store.save();

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.preferences.feedNotificationsEnabled, true);
    assert.deepEqual(restored.state.notificationBookkeeping.providerSilencedAt, { codex: 1234 });
    assert.equal(restored.state.notificationBookkeeping.feedSeenIDs.length, 200);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Language preference persists and rejects unsupported locales", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-language-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.equal(store.state.preferences.language, "system");
    await store.setLanguage("zh-Hant");
    await assert.rejects(() => store.setLanguage("fr"), /Unsupported language/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.preferences.language, "zh-Hant");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Refresh preference defaults, persists, and rejects unsupported intervals", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-refresh-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.equal(store.state.preferences.refreshMinutes, 5);
    await store.setRefreshMinutes(15);
    await assert.rejects(() => store.setRefreshMinutes(2), /Unsupported refresh interval/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.preferences.refreshMinutes, 15);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Summary strategy defaults, persists, and rejects unknown values", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-summary-strategy-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.equal(store.state.preferences.summaryStrategy, "shortestWindow");

    await store.setSummaryStrategy("lowestRemaining");
    await assert.rejects(() => store.setSummaryStrategy("longest"), /Unsupported quota summary strategy/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.preferences.summaryStrategy, "lowestRemaining");

    const persisted = JSON.parse(await readFile(join(directory, "state-v1.json"), "utf8"));
    persisted.preferences.summaryStrategy = "widest";
    await writeFile(join(directory, "state-v1.json"), JSON.stringify(persisted));
    const validated = new StateStore({ userDataPath: directory, safeStorage });
    await validated.load();
    assert.equal(validated.state.preferences.summaryStrategy, "shortestWindow");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Popover glass style defaults to frosted, persists, and rejects unknown materials", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-popover-glass-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.equal(store.state.preferences.popoverGlassStyle, "frosted");

    await store.setPopoverGlassStyle("clear");
    await assert.rejects(() => store.setPopoverGlassStyle("etched"), /Unsupported popover glass style/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.preferences.popoverGlassStyle, "clear");

    const persisted = JSON.parse(await readFile(join(directory, "state-v1.json"), "utf8"));
    persisted.preferences.popoverGlassStyle = "sandblasted";
    await writeFile(join(directory, "state-v1.json"), JSON.stringify(persisted));
    const validated = new StateStore({ userDataPath: directory, safeStorage });
    await validated.load();
    assert.equal(validated.state.preferences.popoverGlassStyle, "frosted");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Popover backdrop opacity defaults to 0.62 and is clamped onto the 2% grid", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-popover-opacity-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.equal(store.state.preferences.popoverBackdropOpacity, 0.62);

    // A continuous slider is never interrupted to be told its value is wrong:
    // out-of-range and off-grid values are corrected in place.
    await store.setPopoverBackdropOpacity(0.431);
    assert.equal(store.state.preferences.popoverBackdropOpacity, 0.44);
    await store.setPopoverBackdropOpacity(2);
    assert.equal(store.state.preferences.popoverBackdropOpacity, 1);
    await store.setPopoverBackdropOpacity(-1);
    assert.equal(store.state.preferences.popoverBackdropOpacity, 0);
    await store.setPopoverBackdropOpacity(0.3);
    await assert.rejects(() => store.setPopoverBackdropOpacity("half"), /Unsupported popover backdrop opacity/);
    await assert.rejects(() => store.setPopoverBackdropOpacity(Number.NaN), /Unsupported popover backdrop opacity/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.preferences.popoverBackdropOpacity, 0.3);

    // A hand-edited or corrupted file must not be able to hide the popup.
    const persisted = JSON.parse(await readFile(join(directory, "state-v1.json"), "utf8"));
    persisted.preferences.popoverBackdropOpacity = "opaque";
    await writeFile(join(directory, "state-v1.json"), JSON.stringify(persisted));
    const validated = new StateStore({ userDataPath: directory, safeStorage });
    await validated.load();
    assert.equal(validated.state.preferences.popoverBackdropOpacity, 0.62);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Tray preferences default, persist, and validate mode and provider catalog", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-tray-preferences-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.equal(store.state.preferences.trayDisplayMode, "full");
    assert.deepEqual(store.state.preferences.trayProviders, ["claude", "codex"]);

    await store.setTrayDisplayMode("compact");
    await store.setTrayProviders(["ollama", "cursor", "invalid", "codex", "claude", "copilot"]);
    await assert.rejects(() => store.setTrayDisplayMode("dense"), /Unsupported tray display mode/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.preferences.trayDisplayMode, "compact");
    assert.deepEqual(restored.state.preferences.trayProviders, ["claude", "codex", "cursor", "copilot"]);

    const persisted = JSON.parse(await readFile(join(directory, "state-v1.json"), "utf8"));
    persisted.preferences.trayDisplayMode = "wide";
    persisted.preferences.trayProviders = "claude";
    await writeFile(join(directory, "state-v1.json"), JSON.stringify(persisted));
    const validated = new StateStore({ userDataPath: directory, safeStorage });
    await validated.load();
    assert.equal(validated.state.preferences.trayDisplayMode, "full");
    assert.deepEqual(validated.state.preferences.trayProviders, ["claude", "codex"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Onboarding selection and Windows-local credentials persist encrypted", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-provider-state-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    await store.completeOnboarding(["cursor", "openrouter", "unsupported"]);
    await store.setProviderSecret("openrouter", "sk-or-sensitive-value");

    const onDisk = await readFile(join(directory, "state-v1.json"), "utf8");
    assert.doesNotMatch(onDisk, /sk-or-sensitive-value|providerSecrets/);
    assert.match(onDisk, /protectedProviderSecrets/);

    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.onboardingCompleted, true);
    assert.deepEqual(restored.state.enabledProviders, ["cursor", "openrouter"]);
    assert.equal(restored.getProviderSecret("openrouter"), "sk-or-sensitive-value");

    await restored.clearProviderSecret("openrouter");
    assert.equal(restored.hasProviderSecret("openrouter"), false);
    assert.doesNotMatch(await readFile(join(directory, "state-v1.json"), "utf8"), /protectedProviderSecrets/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
