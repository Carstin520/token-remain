import { homedir } from "node:os";
import { join } from "node:path";
import { clampPercent, fetchJSON, number, parseReset, readBoundedJSON } from "./shared.js";

export async function collectClaude({ env = process.env, now = Date.now() } = {}) {
  const directory = env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
  let credentials;
  try {
    credentials = await readBoundedJSON(join(directory, ".credentials.json"));
  } catch {
    throw new Error("Claude Code is not signed in on this PC");
  }
  const oauth = credentials?.claudeAiOauth;
  const token = oauth?.accessToken?.trim();
  if (!token) throw new Error("Claude credentials contain no OAuth token");
  const expiry = number(oauth.expiresAt);
  if (expiry && expiry - now <= 120_000) throw new Error("Claude Code sign-in has expired");
  const payload = await fetchJSON("https://api.anthropic.com/api/oauth/usage", {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      "anthropic-beta": "oauth-2025-04-20",
      "User-Agent": "claude-code/2.1.69",
    },
  });
  return parseClaudeUsage(payload, {
    now,
    subscriptionType: oauth.subscriptionType,
    rateLimitTier: oauth.rateLimitTier,
  });
}

export function parseClaudeUsage(object, { now = Date.now(), subscriptionType, rateLimitTier } = {}) {
  const primary = quotaWindow(object?.five_hour, 300);
  if (!primary) throw new Error("Claude returned no five-hour quota window");
  const secondary = quotaWindow(object?.seven_day, 10_080);
  const scopedWindows = Object.keys(object || {})
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
  return {
    providerID: "claude",
    capturedAt: now,
    planName: claudePlanName(subscriptionType, rateLimitTier),
    windows: [primary, ...(secondary ? [secondary] : [])],
    ...(scopedWindows.length ? { scopedWindows } : {}),
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
