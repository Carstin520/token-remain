import { homedir } from "node:os";
import { join } from "node:path";
import { clampPercent, decodeJWTExpiry, fetchJSON, number, readBoundedJSON } from "./shared.js";

const SESSION_SECONDS = 300 * 60;
const WEEK_SECONDS = 10_080 * 60;

export async function collectCodex({ env = process.env, now = Date.now(), fetchImpl = fetch } = {}) {
  const path = join(resolveCodexHome(env), "auth.json");
  let auth;
  try {
    auth = await readBoundedJSON(path);
  } catch {
    throw new Error("Codex is not signed in on this PC");
  }
  const token = auth?.tokens?.access_token?.trim();
  if (!token) throw new Error("Codex auth.json has no access token");
  const expiry = decodeJWTExpiry(token);
  if (expiry && expiry <= now) throw new Error("Codex sign-in has expired");
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
      throw new Error("Codex sign-in was rejected. Run codex logout, sign in again, then refresh.");
    }
    throw error;
  }
  return parseCodexUsage(payload, now);
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
  return {
    providerID: "codex",
    capturedAt: now,
    planName: codexPlanName(object?.plan_type),
    windows: session ? [session, ...(weekly ? [weekly] : [])] : [primary],
  };
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
