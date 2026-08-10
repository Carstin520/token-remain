import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { normalizeQuotaUsageHistory, recordQuotaUsageHistory } from "./quota-history.js";
import { normalizeProviderIDs, PROVIDER_ID_SET } from "./providers/catalog.js";
import { newSourceID } from "./sync/crypto.js";

const LANGUAGE_PREFERENCES = new Set(["system", "en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "de"]);

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
    if (this.state.protectedProviderSecrets) {
      if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
      this.state.providerSecrets = JSON.parse(this.safeStorage.decryptString(
        Buffer.from(this.state.protectedProviderSecrets, "base64"),
      ));
    }
    this.state.quotaUsageHistory = normalizeQuotaUsageHistory(this.state.quotaUsageHistory);
    this.state.preferences = {
      floatingWidgetEnabled: false,
      language: "system",
      ...(this.state.preferences || {}),
    };
    if (!LANGUAGE_PREFERENCES.has(this.state.preferences.language)) this.state.preferences.language = "system";
    this.state.onboardingCompleted = Boolean(this.state.onboardingCompleted);
    this.state.enabledProviders = normalizeProviderIDs(this.state.enabledProviders);
    this.state.providerSecrets = Object.fromEntries(
      Object.entries(this.state.providerSecrets || {}).filter(([providerID, value]) => (
        PROVIDER_ID_SET.has(providerID) && typeof value === "string" && value.trim()
      )),
    );
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

  getProviderSecret(providerID) {
    if (!PROVIDER_ID_SET.has(providerID)) return undefined;
    return this.state.providerSecrets?.[providerID];
  }

  hasProviderSecret(providerID) {
    return Boolean(this.getProviderSecret(providerID));
  }

  async setProviderSecret(providerID, value) {
    if (!PROVIDER_ID_SET.has(providerID)) throw new Error("Unsupported provider");
    const secret = String(value || "").trim();
    if (!secret || Buffer.byteLength(secret) > 32 * 1024) throw new Error("Credential is missing or too long");
    this.state.providerSecrets = { ...(this.state.providerSecrets || {}), [providerID]: secret };
    await this.save();
  }

  async clearProviderSecret(providerID) {
    if (!PROVIDER_ID_SET.has(providerID)) throw new Error("Unsupported provider");
    const next = { ...(this.state.providerSecrets || {}) };
    delete next[providerID];
    this.state.providerSecrets = next;
    await this.save();
  }

  async completeOnboarding(providerIDs) {
    this.state.enabledProviders = normalizeProviderIDs(providerIDs);
    this.state.onboardingCompleted = true;
    await this.save();
  }

  async setProviderEnabled(providerID, enabled) {
    if (!PROVIDER_ID_SET.has(providerID)) throw new Error("Unsupported provider");
    const current = new Set(this.state.enabledProviders || []);
    if (enabled) current.add(providerID);
    else current.delete(providerID);
    this.state.enabledProviders = normalizeProviderIDs([...current]);
    await this.save();
  }

  async setFloatingWidgetEnabled(enabled) {
    this.state.preferences = {
      ...(this.state.preferences || {}),
      floatingWidgetEnabled: Boolean(enabled),
    };
    await this.save();
  }

  async setLanguage(value) {
    if (!LANGUAGE_PREFERENCES.has(value)) throw new Error("Unsupported language");
    this.state.preferences = { ...(this.state.preferences || {}), language: value };
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
    if (Object.keys(this.state.providerSecrets || {}).length) {
      if (!this.safeStorage.isEncryptionAvailable()) throw new Error("Windows credential protection is unavailable");
      persisted.protectedProviderSecrets = this.safeStorage
        .encryptString(JSON.stringify(this.state.providerSecrets))
        .toString("base64");
    } else {
      delete persisted.protectedProviderSecrets;
    }
    delete persisted.providerSecrets;
    await writeFile(temporary, JSON.stringify(persisted, null, 2), { mode: 0o600 });
    await rename(temporary, this.path);
  }
}
