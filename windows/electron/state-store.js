import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { normalizeNotificationBookkeeping } from "./notification-policy.js";
import { normalizeQuotaUsageHistory, recordQuotaUsageHistory } from "./quota-history.js";
import { normalizeProviderIDs, PROVIDER_ID_SET } from "./providers/catalog.js";
import { DEFAULT_REFRESH_MINUTES, isRefreshMinutes } from "./refresh-policy.js";
import { newSourceID } from "./sync/crypto.js";
import { normalizeUpdateCheckState } from "./update-check.js";

const LANGUAGE_PREFERENCES = new Set(["system", "en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "de"]);
const TRAY_DISPLAY_MODES = new Set(["full", "compact", "minimal"]);
const SUMMARY_STRATEGIES = new Set(["shortestWindow", "lowestRemaining"]);
const DEFAULT_TRAY_PROVIDERS = Object.freeze(["claude", "codex"]);
const POPOVER_GLASS_STYLES = new Set(["frosted", "clear"]);
const DEFAULT_POPOVER_GLASS_STYLE = "frosted";
/// Mirrors the macOS reference backdrop opacity and its 2% storage grid; see
/// src/glass/glass-model.js for the renderer half of the same contract.
const DEFAULT_POPOVER_BACKDROP_OPACITY = 0.62;
const POPOVER_BACKDROP_OPACITY_STEP = 0.02;

/// Clamp to 0–1 and snap to the 2% grid. Anything non-finite falls back to the
/// shipped default rather than to zero, which would persist an invisible popup.
function clampPopoverBackdropOpacity(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return DEFAULT_POPOVER_BACKDROP_OPACITY;
  const steps = 1 / POPOVER_BACKDROP_OPACITY_STEP;
  return Math.round(Math.min(Math.max(value, 0), 1) * steps) / steps;
}

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
    this.state.notificationBookkeeping = normalizeNotificationBookkeeping(this.state.notificationBookkeeping);
    this.state.updateCheck = normalizeUpdateCheckState(this.state.updateCheck);
    this.state.preferences = {
      feedNotificationsEnabled: false,
      floatingWidgetEnabled: false,
      language: "system",
      popoverBackdropOpacity: DEFAULT_POPOVER_BACKDROP_OPACITY,
      popoverGlassStyle: DEFAULT_POPOVER_GLASS_STYLE,
      refreshMinutes: DEFAULT_REFRESH_MINUTES,
      showAntigravityThirdPartyQuota: false,
      showCodexSparkQuota: false,
      showFableQuota: true,
      summaryStrategy: "shortestWindow",
      trayDisplayMode: "full",
      trayProviders: [...DEFAULT_TRAY_PROVIDERS],
      ...(this.state.preferences || {}),
    };
    if (!LANGUAGE_PREFERENCES.has(this.state.preferences.language)) this.state.preferences.language = "system";
    if (!isRefreshMinutes(this.state.preferences.refreshMinutes)) this.state.preferences.refreshMinutes = DEFAULT_REFRESH_MINUTES;
    this.state.preferences.feedNotificationsEnabled = this.state.preferences.feedNotificationsEnabled === true;
    this.state.preferences.showFableQuota = typeof this.state.preferences.showFableQuota === "boolean"
      ? this.state.preferences.showFableQuota
      : true;
    this.state.preferences.showCodexSparkQuota = this.state.preferences.showCodexSparkQuota === true;
    this.state.preferences.showAntigravityThirdPartyQuota = this.state.preferences.showAntigravityThirdPartyQuota === true;
    if (!SUMMARY_STRATEGIES.has(this.state.preferences.summaryStrategy)) this.state.preferences.summaryStrategy = "shortestWindow";
    if (!POPOVER_GLASS_STYLES.has(this.state.preferences.popoverGlassStyle)) this.state.preferences.popoverGlassStyle = DEFAULT_POPOVER_GLASS_STYLE;
    this.state.preferences.popoverBackdropOpacity = clampPopoverBackdropOpacity(this.state.preferences.popoverBackdropOpacity);
    if (!TRAY_DISPLAY_MODES.has(this.state.preferences.trayDisplayMode)) this.state.preferences.trayDisplayMode = "full";
    this.state.preferences.trayProviders = Array.isArray(this.state.preferences.trayProviders)
      ? normalizeProviderIDs(this.state.preferences.trayProviders).slice(0, 4)
      : [...DEFAULT_TRAY_PROVIDERS];
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

  async setFeedNotificationsEnabled(enabled) {
    this.state.preferences = {
      ...(this.state.preferences || {}),
      feedNotificationsEnabled: enabled === true,
    };
    await this.save();
  }

  async setShowFableQuota(enabled) {
    this.state.preferences = { ...(this.state.preferences || {}), showFableQuota: enabled === true };
    await this.save();
  }

  async setShowCodexSparkQuota(enabled) {
    this.state.preferences = { ...(this.state.preferences || {}), showCodexSparkQuota: enabled === true };
    await this.save();
  }

  async setShowAntigravityThirdPartyQuota(enabled) {
    this.state.preferences = { ...(this.state.preferences || {}), showAntigravityThirdPartyQuota: enabled === true };
    await this.save();
  }

  async setSummaryStrategy(value) {
    if (!SUMMARY_STRATEGIES.has(value)) throw new Error("Unsupported quota summary strategy");
    this.state.preferences = { ...(this.state.preferences || {}), summaryStrategy: value };
    await this.save();
  }

  async setPopoverGlassStyle(value) {
    if (!POPOVER_GLASS_STYLES.has(value)) throw new Error("Unsupported popover glass style");
    this.state.preferences = { ...(this.state.preferences || {}), popoverGlassStyle: value };
    await this.save();
  }

  /// Out-of-range and off-grid values are corrected rather than rejected: the
  /// slider is a continuous control and this app never interrupts one to ask.
  async setPopoverBackdropOpacity(value) {
    if (typeof value !== "number" || !Number.isFinite(value)) throw new Error("Unsupported popover backdrop opacity");
    this.state.preferences = {
      ...(this.state.preferences || {}),
      popoverBackdropOpacity: clampPopoverBackdropOpacity(value),
    };
    await this.save();
  }

  async setTrayDisplayMode(value) {
    if (!TRAY_DISPLAY_MODES.has(value)) throw new Error("Unsupported tray display mode");
    this.state.preferences = { ...(this.state.preferences || {}), trayDisplayMode: value };
    await this.save();
  }

  async setTrayProviders(values) {
    this.state.preferences = { ...(this.state.preferences || {}), trayProviders: normalizeProviderIDs(values).slice(0, 4) };
    await this.save();
  }

  setNotificationBookkeeping(value) {
    this.state.notificationBookkeeping = normalizeNotificationBookkeeping(value);
  }

  setUpdateCheck(value) {
    this.state.updateCheck = normalizeUpdateCheckState(value);
  }

  async setLanguage(value) {
    if (!LANGUAGE_PREFERENCES.has(value)) throw new Error("Unsupported language");
    this.state.preferences = { ...(this.state.preferences || {}), language: value };
    await this.save();
  }

  async setRefreshMinutes(value) {
    if (!isRefreshMinutes(value)) throw new Error("Unsupported refresh interval");
    this.state.preferences = { ...(this.state.preferences || {}), refreshMinutes: value };
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
