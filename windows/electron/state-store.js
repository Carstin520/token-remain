import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
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

  async save() {
    await mkdir(dirname(this.path), { recursive: true });
    const temporary = `${this.path}.next`;
    const persisted = { ...this.state };
    delete persisted.remoteSnapshot;
    await writeFile(temporary, JSON.stringify(persisted, null, 2), { mode: 0o600 });
    await rename(temporary, this.path);
  }
}
