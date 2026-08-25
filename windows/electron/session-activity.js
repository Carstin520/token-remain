import { watch } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const LOCAL_AI_ACTIVITY_GRACE_MS = 3 * 60_000;
export const SESSION_ACTIVITY_SWEEP_MS = 60_000;

function environmentValue(env, name) {
  if (typeof env[name] === "string") return env[name];
  const key = Object.keys(env).find((candidate) => candidate.toLowerCase() === name.toLowerCase());
  return key ? env[key] : undefined;
}

function expandWindowsPath(value, env, home) {
  const text = String(value || "").trim();
  if (text === "~") return home;
  if (text.startsWith("~/") || text.startsWith("~\\")) return join(home, text.slice(2));
  return text.replace(/%([^%]+)%/g, (_match, name) => environmentValue(env, name) || `%${name}%`);
}

/// Windows equivalents of the macOS monitor's three append-only roots:
/// Codex CLI sessions, Claude Code projects, and Claude Desktop local-agent
/// sessions. CODEX_HOME / CLAUDE_CONFIG_DIR retain the host apps' overrides.
export function resolveLocalAISessionRoots({ env = process.env, home = homedir() } = {}) {
  const codexHome = expandWindowsPath(environmentValue(env, "CODEX_HOME") || join(home, ".codex"), env, home);
  const claudeHome = expandWindowsPath(environmentValue(env, "CLAUDE_CONFIG_DIR") || join(home, ".claude"), env, home);
  const appData = expandWindowsPath(environmentValue(env, "APPDATA") || join(home, "AppData", "Roaming"), env, home);
  return [...new Set([
    join(codexHome, "sessions"),
    join(claudeHome, "projects"),
    join(appData, "Claude", "local-agent-mode-sessions"),
  ])];
}

async function newestJSONLModification(root) {
  let entries;
  try { entries = await readdir(root, { withFileTypes: true }); } catch { return undefined; }
  let latest;
  for (const entry of entries) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      const nested = await newestJSONLModification(path);
      if (nested !== undefined && (latest === undefined || nested > latest)) latest = nested;
    } else if (entry.isFile() && entry.name.toLowerCase().endsWith(".jsonl")) {
      const metadata = await stat(path).catch(() => undefined);
      if (metadata?.isFile() && (latest === undefined || metadata.mtimeMs > latest)) latest = metadata.mtimeMs;
    }
  }
  return latest;
}

export async function latestSessionModificationAt(roots, { now = Date.now() } = {}) {
  let latest;
  for (const root of roots) {
    const modifiedAt = await newestJSONLModification(root);
    if (modifiedAt === undefined) continue;
    const bounded = Math.min(modifiedAt, now);
    if (latest === undefined || bounded > latest) latest = bounded;
  }
  return latest;
}

export class LocalAISessionActivityMonitor {
  constructor({
    roots,
    env = process.env,
    home = homedir(),
    watchImpl = watch,
    sweepIntervalMs = SESSION_ACTIVITY_SWEEP_MS,
    debounceMs = 250,
    onActivity,
  } = {}) {
    this.roots = roots || resolveLocalAISessionRoots({ env, home });
    this.watchImpl = watchImpl;
    this.sweepIntervalMs = sweepIntervalMs;
    this.debounceMs = debounceMs;
    this.onActivity = onActivity;
    this.lastActivityAt = undefined;
    this.watchers = new Map();
    this.started = false;
    this.seeded = false;
    this.sweepPromise = undefined;
    this.sweepTimer = undefined;
    this.debounceTimer = undefined;
    this.pendingActivityAt = undefined;
  }

  async start(now = Date.now()) {
    if (this.started) return;
    this.started = true;
    await this.sweep(now);
    this.sweepTimer = setInterval(() => { this.sweep().catch(() => {}); }, this.sweepIntervalMs);
    this.sweepTimer.unref?.();
  }

  stop() {
    this.started = false;
    clearInterval(this.sweepTimer);
    clearTimeout(this.debounceTimer);
    this.sweepTimer = undefined;
    this.debounceTimer = undefined;
    for (const watcher of this.watchers.values()) watcher.close?.();
    this.watchers.clear();
  }

  async sweep(now = Date.now()) {
    if (this.sweepPromise) return this.sweepPromise;
    this.sweepPromise = (async () => {
      const latest = await latestSessionModificationAt(this.roots, { now });
      if (latest !== undefined) this.recordActivityAt(latest, { notify: this.seeded });
      await this.armAvailableRoots();
      this.seeded = true;
    })();
    try {
      await this.sweepPromise;
    } finally {
      this.sweepPromise = undefined;
    }
  }

  hasRecentSessionActivity(now = Date.now(), graceMs = LOCAL_AI_ACTIVITY_GRACE_MS) {
    if (this.lastActivityAt !== undefined && this.lastActivityAt > now) this.lastActivityAt = now;
    if (this.lastActivityAt === undefined) return false;
    const age = now - this.lastActivityAt;
    return age >= 0 && age <= graceMs;
  }

  recordActivityAt(timestamp, { notify = true } = {}) {
    if (!Number.isFinite(timestamp)) return;
    if (this.lastActivityAt !== undefined && timestamp <= this.lastActivityAt) return;
    this.lastActivityAt = timestamp;
    if (notify) this.onActivity?.(timestamp);
  }

  queueWatchActivity(timestamp = Date.now()) {
    this.pendingActivityAt = Math.max(this.pendingActivityAt || 0, timestamp);
    clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = undefined;
      const observedAt = this.pendingActivityAt;
      this.pendingActivityAt = undefined;
      this.recordActivityAt(observedAt);
    }, this.debounceMs);
    this.debounceTimer.unref?.();
  }

  async armAvailableRoots() {
    for (const [root, watcher] of this.watchers) {
      const metadata = await stat(root).catch(() => undefined);
      if (metadata?.isDirectory()) continue;
      watcher.close?.();
      this.watchers.delete(root);
    }
    for (const root of this.roots) {
      if (this.watchers.has(root)) continue;
      const metadata = await stat(root).catch(() => undefined);
      if (!metadata?.isDirectory()) continue;
      const listener = (_eventType, filename) => {
        const name = filename === undefined ? "" : String(filename);
        if (name.toLowerCase().endsWith(".jsonl")) this.queueWatchActivity();
        else this.sweep().catch(() => {});
      };
      let watcher;
      try {
        watcher = this.watchImpl(root, { recursive: true }, listener);
      } catch {
        // Some Node/platform combinations do not implement recursive watching.
        // The root watcher catches direct writes and the minute stat sweep
        // covers nested directories and re-arms roots created after launch.
        try { watcher = this.watchImpl(root, listener); } catch { continue; }
      }
      watcher.on?.("error", () => {
        watcher.close?.();
        if (this.watchers.get(root) === watcher) this.watchers.delete(root);
      });
      watcher.unref?.();
      this.watchers.set(root, watcher);
    }
  }
}
