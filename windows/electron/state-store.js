import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { normalizeQuotaUsageHistory, recordQuotaUsageHistory } from "./quota-history.js";
import { newSourceID } from "./sync/crypto.js";

export class StateStore {
  constructor({ userDataPath, safeStorage }) {
    this.path = join(userDataPath, "state-v1.json");
    this.safeStorage = safeStorage;
    this.state = undefined;
  }

  async load() {
    if (this.state) return this.state;
    try {
      this.state = JSON.parse(await readFile(this.path, "utf8"));
    } catch {
      this.state = { schemaVersion: 1, sourceInstanceID: newSourceID(), sequence: 0, providers: [], notices: {} };
      await this.save();
    }
    if (!this.state.sourceInstanceID) this.state.sourceInstanceID = newSourceID();
    if (this.state.protectedRemoteSnapshot) {
      if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
      this.state.remoteSnapshot = JSON.parse(this.safeStorage.decryptString(
        Buffer.from(this.state.protectedRemoteSnapshot, "base64"),
      ));
    } else if (this.state.remoteSnapshot) {
      this.setRemoteSnapshot(this.state.remoteSnapshot);
      await this.save();
    }
    if (this.state.protectedQuotaUsageHistory) {
      if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
      this.state.quotaUsageHistory = JSON.parse(this.safeStorage.decryptString(
        Buffer.from(this.state.protectedQuotaUsageHistory, "base64"),
      ));
    }
    if (this.state.protectedLocalDailyUsageHistory) {
      if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
      this.state.localDailyUsageHistory = JSON.parse(this.safeStorage.decryptString(
        Buffer.from(this.state.protectedLocalDailyUsageHistory, "base64"),
      ));
    }
    this.state.quotaUsageHistory = normalizeQuotaUsageHistory(this.state.quotaUsageHistory);
    this.state.preferences = {
      floatingWidgetEnabled: false,
      ...(this.state.preferences || {}),
    };
    return this.state;
  }

  getPairedMac() {
    const value = this.state?.pairedMac;
    if (!value) return undefined;
    if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
    const decoded = JSON.parse(this.safeStorage.decryptString(Buffer.from(value.protected, "base64")));
    return {
      baseURL: value.baseURL,
      deviceName: value.deviceName,
      serverSourceInstanceID: value.serverSourceInstanceID,
      lastRemoteSequence: Number.isSafeInteger(value.lastRemoteSequence) ? value.lastRemoteSequence : 0,
      ...decoded,
      key: Buffer.from(decoded.key, "base64"),
    };
  }

  async setPairedMac(value) {
    if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
    const protectedValue = this.safeStorage.encryptString(JSON.stringify({ key: value.key.toString("base64"), keyID: value.keyID }));
    this.state.pairedMac = {
      baseURL: value.baseURL,
      deviceName: value.deviceName,
      serverSourceInstanceID: value.serverSourceInstanceID,
      lastRemoteSequence: 0,
      protected: protectedValue.toString("base64"),
    };
    await this.save();
  }

  async disconnect() {
    delete this.state.pairedMac;
    delete this.state.remoteSnapshot;
    delete this.state.protectedRemoteSnapshot;
    delete this.state.lastSyncAt;
    await this.save();
  }

  setRemoteSnapshot(snapshot) {
    if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
    this.state.remoteSnapshot = snapshot;
    this.state.protectedRemoteSnapshot = this.safeStorage
      .encryptString(JSON.stringify(snapshot))
      .toString("base64");
  }

  recordQuotaUsage(providers, now = Date.now()) {
    this.state.quotaUsageHistory = recordQuotaUsageHistory(this.state.quotaUsageHistory, providers, now);
  }

  setLocalDailyUsageHistory(history) {
    if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
    this.state.localDailyUsageHistory = history;
  }

  async setFloatingWidgetEnabled(enabled) {
    this.state.preferences = {
      ...(this.state.preferences || {}),
      floatingWidgetEnabled: Boolean(enabled),
    };
    await this.save();
  }

  async setFloatingWidgetBounds(bounds) {
    if (!bounds) return;
    this.state.preferences = {
      ...(this.state.preferences || {}),
      floatingWidgetBounds: {
        x: Math.round(bounds.x),
        y: Math.round(bounds.y),
        width: Math.round(bounds.width),
        height: Math.round(bounds.height),
      },
    };
    await this.save();
  }

  async save() {
    await mkdir(dirname(this.path), { recursive: true });
    const temporary = `${this.path}.next`;
    const persisted = { ...this.state };
    delete persisted.remoteSnapshot;
    if (this.state.quotaUsageHistory) {
      if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
      persisted.protectedQuotaUsageHistory = this.safeStorage
        .encryptString(JSON.stringify(this.state.quotaUsageHistory))
        .toString("base64");
    }
    delete persisted.quotaUsageHistory;
    if (this.state.localDailyUsageHistory) {
      if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
      persisted.protectedLocalDailyUsageHistory = this.safeStorage
        .encryptString(JSON.stringify(this.state.localDailyUsageHistory))
        .toString("base64");
    }
    delete persisted.localDailyUsageHistory;
    await writeFile(temporary, JSON.stringify(persisted, null, 2), { mode: 0o600 });
    await rename(temporary, this.path);
  }
}
