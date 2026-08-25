import { open, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { signInRequiredError } from "../notification-policy.js";
import { clampPercent, decodeJWTExpiry, fetchJSON, number, readBoundedJSON } from "./shared.js";

const SESSION_SECONDS = 300 * 60;
const WEEK_SECONDS = 10_080 * 60;

export async function collectCodex({ env = process.env, now = Date.now(), fetchImpl = fetch } = {}) {
  const path = join(resolveCodexHome(env), "auth.json");
  let auth;
  try {
    auth = await readBoundedJSON(path);
  } catch {
    throw signInRequiredError("Codex is not signed in on this PC");
  }
  const token = auth?.tokens?.access_token?.trim();
  if (!token) throw signInRequiredError("Codex auth.json has no access token");
  const expiry = decodeJWTExpiry(token);
  if (expiry && expiry <= now) throw signInRequiredError("Codex sign-in has expired");
  const headers = { Authorization: `Bearer ${token}`, Accept: "application/json" };
  if (auth.tokens.account_id) headers["ChatGPT-Account-Id"] = auth.tokens.account_id;
  let payload;
  try {
    payload = await fetchJSON(
      "https://chatgpt.com/backend-api/wham/usage",
      { headers },
      { fetchImpl, timeoutMs: 30_000 },
    );
  } catch (error) {
    if (error?.name === "TimeoutError" || /aborted due to timeout/i.test(error?.message || "")) {
      throw new Error("Codex quota request timed out. Check the Windows proxy or firewall, then refresh.");
    }
    if (/Request failed \((401|403)\)/.test(error?.message || "")) {
      throw signInRequiredError("Codex sign-in was rejected. Run codex logout, sign in again, then refresh.");
    }
    throw error;
  }
  const quota = parseCodexUsage(payload, now);
  const scopedWindows = await collectCodexScopedWindows(resolveCodexHome(env), quota.capturedAt).catch(() => []);
  return scopedWindows.length ? { ...quota, scopedWindows } : quota;
}

export function resolveCodexHome(env = process.env, home = homedir()) {
  const configured = String(env.CODEX_HOME || "").trim();
  if (!configured) return join(home, ".codex");
  if (configured === "~") return home;
  if (configured.startsWith("~/") || configured.startsWith("~\\")) {
    return join(home, configured.slice(2));
  }
  return configured.replace(/%USERPROFILE%/gi, env.USERPROFILE || home);
}

export function parseCodexUsage(object, now = Date.now()) {
  const rateLimit = object?.rate_limit || {};
  const candidates = [
    [rateLimit.primary_window, true],
    [rateLimit.secondary_window, false],
  ].filter(([window]) => window && typeof window === "object");
  const session = classified(candidates, SESSION_SECONDS, true, now);
  const weekly = classified(candidates, WEEK_SECONDS, false, now);
  const primary = session || weekly;
  if (!primary) throw new Error("Codex returned no quota window");
  const codexResetCredits = resetCredits(object?.rate_limit_reset_credits);
  return {
    providerID: "codex",
    capturedAt: now,
    planName: codexPlanName(object?.plan_type),
    windows: session ? [session, ...(weekly ? [weekly] : [])] : [primary],
    ...(codexResetCredits ? { codexResetCredits } : {}),
  };
}

function resetCredits(value) {
  const available = number(value?.available_count);
  if (available === undefined) return undefined;
  return { availableCount: Math.max(0, Math.trunc(available)) };
}

function classified(candidates, seconds, fallbackSession, now) {
  const exact = candidates.find(([window]) => number(window.limit_window_seconds) === seconds);
  const fallback = candidates.find(([window, isSession]) => number(window.limit_window_seconds) === undefined && isSession === fallbackSession);
  const candidate = exact || fallback;
  if (!candidate) return undefined;
  const window = candidate[0];
  const used = number(window.used_percent);
  if (used === undefined) return undefined;
  const duration = number(window.limit_window_seconds) || seconds;
  const resetAt = number(window.reset_at);
  const resetAfter = number(window.reset_after_seconds);
  return {
    usedPercent: clampPercent(used),
    windowMinutes: Math.trunc(duration / 60),
    ...(resetAt > 0 ? { resetsAt: Math.trunc(resetAt * 1000) } : resetAfter >= 0 ? { resetsAt: now + Math.trunc(resetAfter * 1000) } : {}),
  };
}

function codexPlanName(value) {
  if (typeof value !== "string" || !value.trim()) return undefined;
  if (value.toLowerCase() === "prolite") return "Pro 5x";
  if (value.toLowerCase() === "pro") return "Pro 20x";
  return value.split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1).toLowerCase()).join(" ");
}

function localWindow(value, fallbackMinutes) {
  const used = number(value?.used_percent);
  if (used === undefined) return undefined;
  const minutes = number(value?.window_minutes) ?? fallbackMinutes;
  const resetsAt = number(value?.resets_at);
  return {
    usedPercent: clampPercent(used),
    windowMinutes: Math.trunc(minutes),
    ...(resetsAt > 0 ? { resetsAt: Math.trunc(resetsAt * 1000) } : {}),
  };
}

function normalizedText(value) {
  const text = typeof value === "string" ? value.trim() : "";
  return text || undefined;
}

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

export function codexWireScopeBase(value) {
  return Buffer.byteLength(value, "utf8") > 24 ? `${value.slice(0, 15)}_${fnv1a32(value)}` : value;
}

export function codexModelScopedWindows(snapshots, relativeTo) {
  const newestByScope = new Map();
  let hasAccountSnapshot = false;
  for (const snapshot of snapshots) {
    const limitID = snapshot.limitID?.toLowerCase();
    if (limitID === "codex" || (!snapshot.limitID && !snapshot.limitName)) {
      hasAccountSnapshot = true;
      continue;
    }
    const base = scopedBase(snapshot);
    if (!base) continue;
    const previous = newestByScope.get(base);
    if (!previous || snapshot.capturedAt > previous.capturedAt) newestByScope.set(base, snapshot);
  }
  if (!hasAccountSnapshot) return [];
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

async function sessionFiles(root, result = []) {
  let entries;
  try { entries = await readdir(root, { withFileTypes: true }); } catch { return result; }
  for (const entry of entries) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) await sessionFiles(path, result);
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      const metadata = await stat(path).catch(() => undefined);
      if (metadata) result.push({ path, modifiedAt: metadata.mtimeMs });
    }
  }
  return result;
}

async function readTail(path, maximum = 512 * 1024) {
  const handle = await open(path, "r");
  try {
    const size = (await handle.stat()).size;
    const length = Math.min(size, maximum);
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, size - length);
    return buffer.toString("utf8");
  } finally {
    await handle.close();
  }
}

async function collectCodexScopedWindows(home, relativeTo) {
  const files = [
    ...await sessionFiles(join(home, "sessions")),
    ...await sessionFiles(join(home, "archived_sessions")),
  ].sort((left, right) => right.modifiedAt - left.modifiedAt);
  const snapshots = [];
  let newestCanonical;
  for (const file of files) {
    if (newestCanonical && newestCanonical.capturedAt - file.modifiedAt > 24 * 60 * 60 * 1000) break;
    const parsed = parseCodexSessionSnapshots(await readTail(file.path), file.modifiedAt);
    snapshots.push(...parsed);
    for (const snapshot of parsed) {
      if (snapshot.limitID?.toLowerCase() === "codex" && (!newestCanonical || snapshot.capturedAt > newestCanonical.capturedAt)) {
        newestCanonical = snapshot;
      }
    }
  }
  return codexModelScopedWindows(snapshots, relativeTo);
}
