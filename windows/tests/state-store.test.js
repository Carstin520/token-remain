import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
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
