import { homedir } from "node:os";
import { join } from "node:path";
import { signInRequiredError } from "../notification-policy.js";
import { clampPercent, fetchJSON, number, parseReset, readBoundedJSON } from "./shared.js";

export async function collectClaude({ env = process.env, now = Date.now(), fetchImpl = fetch } = {}) {
  const directory = env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
  let credentials;
  try {
    credentials = await readBoundedJSON(join(directory, ".credentials.json"));
  } catch {
    throw signInRequiredError("Claude Code is not signed in on this PC");
  }
  const oauth = credentials?.claudeAiOauth;
  const token = oauth?.accessToken?.trim();
  if (!token) throw signInRequiredError("Claude credentials contain no OAuth token");
  const expiry = number(oauth.expiresAt);
  if (expiry && expiry - now <= 120_000) throw signInRequiredError("Claude Code sign-in has expired");
  const payload = await fetchJSON(
    "https://api.anthropic.com/api/oauth/usage",
    {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/2.1.69",
      },
    },
    { fetchImpl, timeoutMs: 30_000 },
  );
  return parseClaudeUsage(payload, {
    now,
    subscriptionType: oauth.subscriptionType,
    rateLimitTier: oauth.rateLimitTier,
  });
}

export function parseClaudeUsage(object, { now = Date.now(), subscriptionType, rateLimitTier } = {}) {
  const structured = structuredLimits(object?.limits);
  const primary = quotaWindow(object?.five_hour, 300) || structured.primary;
  if (!primary) throw new Error("Claude returned no five-hour quota window");
  const secondary = quotaWindow(object?.seven_day, 10_080) || structured.secondary;
  const legacyScopedWindows = Object.keys(object || {})
    .filter((key) => key.startsWith("seven_day_") && key.length > "seven_day_".length)
    .sort()
    .map((key) => {
      const window = quotaWindow(object[key], 10_080);
      if (!window) return undefined;
      const scopeID = key.slice("seven_day_".length).toLowerCase();
      return {
        scopeID,
        displayName: scopeID.split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" "),
        window,
      };
    })
    .filter(Boolean);
  const scopedWindows = uniqueScopedWindows([...legacyScopedWindows, ...structured.scopedWindows]);
  const extraUsage = parseExtraUsage(object?.extra_usage);
  return {
    providerID: "claude",
    capturedAt: now,
    planName: claudePlanName(subscriptionType, rateLimitTier),
    windows: [primary, ...(secondary ? [secondary] : [])],
    ...(extraUsage ? { extraUsage } : {}),
    ...(scopedWindows.length ? { scopedWindows } : {}),
  };
}

function structuredLimits(value) {
  const result = { primary: undefined, secondary: undefined, scopedWindows: [] };
  if (!Array.isArray(value)) return result;
  for (const row of value) {
    const kind = typeof row?.kind === "string" ? row.kind.toLowerCase() : "";
    if (kind === "session") {
      result.primary = limitWindow(row, 300) || result.primary;
      continue;
    }
    if (kind === "weekly_all") {
      result.secondary = limitWindow(row, 10_080) || result.secondary;
      continue;
    }
    if (kind !== "weekly_scoped") continue;
    const window = limitWindow(row, 10_080);
    const model = row?.scope?.model;
    if (!window || !model || typeof model !== "object") continue;
    const rawID = typeof model.id === "string" ? model.id.trim() : "";
    const rawName = typeof model.display_name === "string" ? model.display_name.trim() : "";
    const displayName = rawName || (rawID ? scopeDisplayName(rawID) : "");
    if (!displayName || isGeneralWeeklyLabel(displayName)) continue;
    const scopeID = normalizedScopeID(rawID || displayName);
    if (!scopeID) continue;
    result.scopedWindows.push({ scopeID, displayName, window });
  }
  return result;
}

function limitWindow(value, windowMinutes) {
  const used = number(value?.percent) ?? number(value?.utilization);
  if (used === undefined) return undefined;
  const resetsAt = parseReset(value?.resets_at);
  return {
    usedPercent: clampPercent(used),
    windowMinutes,
    ...(resetsAt ? { resetsAt } : {}),
  };
}

function uniqueScopedWindows(windows) {
  const order = [];
  const latestByScope = new Map();
  for (const scope of windows) {
    const key = scope.scopeID.toLowerCase();
    if (!latestByScope.has(key)) order.push(key);
    latestByScope.set(key, scope);
  }
  return order.map((key) => latestByScope.get(key));
}

function scopeDisplayName(scopeID) {
  return scopeID.split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1).toLowerCase()).join(" ");
}

function normalizedScopeID(value) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 32) || undefined;
}

function isGeneralWeeklyLabel(value) {
  const reference = "allmodels";
  const normalized = value.toLowerCase().replace(/[^a-z]/g, "");
  if (normalized.endsWith(reference)) return true;
  if (normalized.length < reference.length - 2) return false;
  let index = 0;
  for (const character of reference) {
    if (normalized[index] === character) index += 1;
    if (index === normalized.length) return true;
  }
  return index === normalized.length;
}

function parseExtraUsage(value) {
  if (value?.is_enabled !== true) return undefined;
  const spentCents = number(value.used_credits);
  if (spentCents === undefined) return undefined;
  const limitCents = number(value.monthly_limit);
  const monthlyLimitUSD = limitCents > 0 ? limitCents / 100 : undefined;
  if (spentCents <= 0 && monthlyLimitUSD === undefined) return undefined;
  return {
    spentUSD: Math.max(0, spentCents / 100),
    ...(monthlyLimitUSD !== undefined ? { monthlyLimitUSD } : {}),
  };
}

function quotaWindow(value, windowMinutes) {
  const used = number(value?.utilization);
  if (used === undefined) return undefined;
  const resetsAt = parseReset(value?.resets_at);
  return {
    usedPercent: clampPercent(used),
    windowMinutes,
    ...(resetsAt ? { resetsAt } : {}),
  };
}

function claudePlanName(subscriptionType, rateLimitTier) {
  if (typeof subscriptionType !== "string" || !subscriptionType.trim()) return undefined;
  const base = subscriptionType.charAt(0).toUpperCase() + subscriptionType.slice(1).toLowerCase();
  const multiplier = typeof rateLimitTier === "string" ? rateLimitTier.match(/\d+x/)?.[0] : undefined;
  return multiplier ? `${base} ${multiplier}` : base;
}
