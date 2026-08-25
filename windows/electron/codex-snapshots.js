import { open, readdir, stat } from "node:fs/promises";
import { isAbsolute, join, relative, resolve } from "node:path";

export const CODEX_SNAPSHOT_TAIL_BYTES = 512 * 1024;
export const CODEX_SNAPSHOT_EARLY_STOP_SKEW_MS = 24 * 60 * 60_000;

function finiteNumber(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function normalizedText(value) {
  const text = typeof value === "string" ? value.trim() : "";
  return text || undefined;
}

function localWindow(value, fallbackMinutes) {
  const usedPercent = finiteNumber(value?.used_percent);
  if (usedPercent === undefined) return undefined;
  const minutes = finiteNumber(value?.window_minutes) ?? fallbackMinutes;
  const resetsAt = finiteNumber(value?.resets_at);
  return {
    usedPercent,
    windowMinutes: Math.trunc(minutes),
    ...(resetsAt !== undefined ? { resetsAt: Math.trunc(resetsAt * 1000) } : {}),
  };
}

/// Parses the newest token_count row for every distinct Codex limit in one
/// bounded session tail. Walking backwards mirrors the append-only JSONL
/// writer and avoids letting an older event from the same file win.
export function parseCodexSessionSnapshots(text, fallbackCapturedAt = 0) {
  const newestByLimit = new Map();
  const lines = String(text).split(/\r?\n/);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    let object;
    try { object = JSON.parse(lines[index]); } catch { continue; }
    const payload = object?.payload;
    const limits = payload?.type === "token_count" ? payload.rate_limits : undefined;
    const primary = localWindow(limits?.primary, 300);
    if (!primary) continue;
    const limitID = normalizedText(limits.limit_id);
    const limitName = normalizedText(limits.limit_name);
    const key = `${limitID || "<legacy>"}|${limitName || ""}`;
    if (newestByLimit.has(key)) continue;
    const parsedTimestamp = typeof object.timestamp === "string" ? Date.parse(object.timestamp) : NaN;
    newestByLimit.set(key, {
      capturedAt: Number.isFinite(parsedTimestamp) ? parsedTimestamp : fallbackCapturedAt,
      limitID,
      limitName,
      planName: normalizedText(limits.plan_type),
      primary,
      secondary: localWindow(limits.secondary, 10_080),
    });
  }
  return [...newestByLimit.values()];
}

function scopedBase(snapshot) {
  if (!snapshot.limitName) return undefined;
  const limitID = snapshot.limitID?.toLowerCase();
  if (limitID && limitID !== "codex") return limitID;
  return snapshot.limitName.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "") || undefined;
}

function fnv1a32(value) {
  let hash = 0x811c9dc5;
  for (const byte of Buffer.from(value, "utf8")) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, "0");
}

/// Leaves room for the longest `_session` suffix in the 32-byte wire scope.
/// Long IDs retain the Spark prefix and gain the same stable FNV-1a suffix as
/// the macOS authority, avoiding collisions between equal 24-byte prefixes.
export function codexWireScopeBase(value) {
  return Buffer.byteLength(value, "utf8") > 24 ? `${value.slice(0, 15)}_${fnv1a32(value)}` : value;
}

export function codexModelScopedWindows(snapshots, relativeTo) {
  const newestByScope = new Map();
  for (const snapshot of snapshots) {
    const limitID = snapshot.limitID?.toLowerCase();
    if (limitID === "codex" || (!snapshot.limitID && !snapshot.limitName)) continue;
    const base = scopedBase(snapshot);
    if (!base) continue;
    const previous = newestByScope.get(base);
    if (!previous || snapshot.capturedAt > previous.capturedAt) newestByScope.set(base, snapshot);
  }
  const scoped = [];
  for (const [base, snapshot] of newestByScope) {
    const prefix = codexWireScopeBase(base);
    const pairs = snapshot.secondary
      ? [["_session", snapshot.primary], ["_weekly", snapshot.secondary]]
      : [[snapshot.primary.windowMinutes >= 10_080 ? "_weekly" : "_session", snapshot.primary]];
    for (const [suffix, window] of pairs) {
      if (window.resetsAt !== undefined && window.resetsAt <= relativeTo) continue;
      scoped.push({
        scopeID: `${prefix}${suffix}`,
        displayName: snapshot.limitName,
        window,
        observedAt: snapshot.capturedAt,
      });
    }
  }
  return scoped.sort((left, right) => left.displayName.toLowerCase().localeCompare(right.displayName.toLowerCase())
    || left.window.windowMinutes - right.window.windowMinutes);
}

export function codexQuotaFromSnapshots(snapshots) {
  let newestCanonical;
  let newestLegacy;
  for (const snapshot of snapshots) {
    if (snapshot.limitID?.toLowerCase() === "codex") {
      if (!newestCanonical || snapshot.capturedAt > newestCanonical.capturedAt) newestCanonical = snapshot;
    } else if (!snapshot.limitID && !snapshot.limitName
      && (!newestLegacy || snapshot.capturedAt > newestLegacy.capturedAt)) {
      newestLegacy = snapshot;
    }
  }
  const base = newestCanonical || newestLegacy;
  if (!base) throw new Error("Codex local rate-limit snapshot was not found");
  const scopedWindows = codexModelScopedWindows(snapshots, base.capturedAt);
  return {
    providerID: "codex",
    capturedAt: base.capturedAt,
    ...(base.planName ? { planName: base.planName } : {}),
    windows: [base.primary, ...(base.secondary ? [base.secondary] : [])],
    ...(scopedWindows.length ? { scopedWindows } : {}),
  };
}

export function codexSnapshotRoots(codexHome) {
  return [join(codexHome, "sessions"), join(codexHome, "archived_sessions")];
}

async function discoverJSONL(root, result) {
  let entries;
  try { entries = await readdir(root, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    if (entry.name.startsWith(".")) continue;
    const path = join(root, entry.name);
    if (entry.isDirectory()) await discoverJSONL(path, result);
    else if (entry.isFile() && entry.name.toLowerCase().endsWith(".jsonl")) {
      const metadata = await stat(path).catch(() => undefined);
      if (metadata?.isFile()) result.push({ path, modifiedAt: metadata.mtimeMs });
    }
  }
}

export async function discoverCodexSnapshotFiles(roots) {
  const candidates = [];
  for (const root of roots) await discoverJSONL(root, candidates);
  return candidates.sort((left, right) => right.modifiedAt - left.modifiedAt);
}

export async function readCodexSnapshotTail(path, maximum = CODEX_SNAPSHOT_TAIL_BYTES) {
  const handle = await open(path, "r");
  try {
    const size = (await handle.stat()).size;
    const length = Math.min(size, maximum);
    const buffer = Buffer.alloc(length);
    const { bytesRead } = await handle.read(buffer, 0, length, size - length);
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, bytesRead));
    } catch {
      return "";
    }
  } finally {
    await handle.close();
  }
}

function pathIsUnder(path, root) {
  const candidate = resolve(path);
  const parent = resolve(root);
  const pathFromRoot = relative(parent, candidate);
  return pathFromRoot === "" || (!pathFromRoot.startsWith("..") && !isAbsolute(pathFromRoot));
}

/// Mtime-keyed parse cache plus a complete candidate metadata baseline. The
/// latter guarantees that a newly created or rewritten file is inspected once
/// even when a rolled-back filesystem clock puts it beyond the normal early
/// stop allowance.
export class CodexSnapshotFileCache {
  constructor({ readTail = readCodexSnapshotTail } = {}) {
    this.readTail = readTail;
    this.entries = new Map();
    this.knownModificationDates = new Map();
  }

  changedCandidatesSinceLastScan(candidates, roots) {
    const hadBaseline = [...this.knownModificationDates.keys()].some((path) => roots.some((root) => pathIsUnder(path, root)));
    const changed = hadBaseline
      ? candidates.filter((candidate) => this.knownModificationDates.get(candidate.path) !== candidate.modifiedAt)
      : [];
    const current = new Set(candidates.map((candidate) => candidate.path));
    for (const path of this.knownModificationDates.keys()) {
      if (roots.some((root) => pathIsUnder(path, root)) && !current.has(path)) this.knownModificationDates.delete(path);
    }
    for (const candidate of candidates) this.knownModificationDates.set(candidate.path, candidate.modifiedAt);
    return changed;
  }

  prune(roots, candidates) {
    const current = new Set(candidates.map((candidate) => candidate.path));
    for (const path of this.entries.keys()) {
      if (roots.some((root) => pathIsUnder(path, root)) && !current.has(path)) this.entries.delete(path);
    }
  }

  async snapshots(candidate) {
    const cached = this.entries.get(candidate.path);
    if (cached?.modifiedAt === candidate.modifiedAt) return cached.snapshots;
    let snapshots = [];
    try {
      snapshots = parseCodexSessionSnapshots(await this.readTail(candidate.path), candidate.modifiedAt);
    } catch {}
    this.entries.set(candidate.path, { modifiedAt: candidate.modifiedAt, snapshots });
    return snapshots;
  }
}

const sharedCache = new CodexSnapshotFileCache();

export async function collectCodexLocalSnapshot(codexHome, { cache = sharedCache } = {}) {
  const roots = codexSnapshotRoots(codexHome);
  const candidates = await discoverCodexSnapshotFiles(roots);
  const changed = cache.changedCandidatesSinceLastScan(candidates, roots);
  cache.prune(roots, candidates);

  const snapshots = [];
  for (const candidate of changed) snapshots.push(...await cache.snapshots(candidate));

  let traversalCanonical;
  for (const candidate of candidates) {
    if (traversalCanonical
      && traversalCanonical.capturedAt - candidate.modifiedAt > CODEX_SNAPSHOT_EARLY_STOP_SKEW_MS) break;
    const parsed = await cache.snapshots(candidate);
    snapshots.push(...parsed);
    for (const snapshot of parsed) {
      if (snapshot.limitID?.toLowerCase() === "codex"
        && (!traversalCanonical || snapshot.capturedAt > traversalCanonical.capturedAt)) {
        traversalCanonical = snapshot;
      }
    }
  }
  return codexQuotaFromSnapshots(snapshots);
}
