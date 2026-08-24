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

test("Scoped quota preferences default, persist, and reject non-boolean stored values", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-quota-preferences-"));
  try {
    const store = new StateStore({ userDataPath: directory, safeStorage });
    await store.load();
    assert.equal(store.state.preferences.showFableQuota, true);
    assert.equal(store.state.preferences.showCodexSparkQuota, false);
    assert.equal(store.state.preferences.showAntigravityThirdPartyQuota, false);

    await store.setShowFableQuota(false);
    await store.setShowCodexSparkQuota(true);
    await store.setShowAntigravityThirdPartyQuota(true);
    const restored = new StateStore({ userDataPath: directory, safeStorage });
    await restored.load();
    assert.equal(restored.state.preferences.showFableQuota, false);
    assert.equal(restored.state.preferences.showCodexSparkQuota, true);
    assert.equal(restored.state.preferences.showAntigravityThirdPartyQuota, true);

    const persisted = JSON.parse(await readFile(join(directory, "state-v1.json"), "utf8"));
    persisted.preferences.showFableQuota = "yes";
    persisted.preferences.showCodexSparkQuota = 1;
    persisted.preferences.showAntigravityThirdPartyQuota = null;
    await writeFile(join(directory, "state-v1.json"), JSON.stringify(persisted));
    const validated = new StateStore({ userDataPath: directory, safeStorage });
    await validated.load();
    assert.equal(validated.state.preferences.showFableQuota, true);
    assert.equal(validated.state.preferences.showCodexSparkQuota, false);
    assert.equal(validated.state.preferences.showAntigravityThirdPartyQuota, false);
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
