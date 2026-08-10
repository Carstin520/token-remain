import { existsSync, readdirSync } from "node:fs";
import http from "node:http";
import https from "node:https";
import { join } from "node:path";
import {
  clamp,
  environmentValue,
  fetchPayload,
  findExecutable,
  numeric,
  quota,
  readSmallJSON,
  readSmallText,
  runExecutable,
  sqliteRows,
  sqliteValue,
  timestamp,
  titleCase,
  windowsHome,
} from "./shared.js";

function appDataPath(env, ...parts) {
  const root = environmentValue(env, "APPDATA");
  return root ? join(root, ...parts) : undefined;
}

function decodeJWTExpiry(token) {
  try {
    const payload = JSON.parse(Buffer.from(String(token).split(".")[1], "base64url").toString("utf8"));
    return numeric(payload.exp) ? payload.exp * 1000 : undefined;
  } catch {
    return undefined;
  }
}

export function parseCursorUsage(object, { now = Date.now(), planName } = {}) {
  if (object?.enabled === false) throw new Error("Cursor has no active subscription");
  const plan = object?.planUsage;
  let used = numeric(plan?.totalPercentUsed);
  if (used === undefined) {
    const limit = numeric(plan?.limit);
    const spend = numeric(plan?.totalSpend) ?? (limit !== undefined ? limit - (numeric(plan?.remaining) ?? limit) : undefined);
    if (limit > 0 && spend !== undefined) used = spend / limit * 100;
  }
  if (used === undefined) throw new Error("Cursor returned no usable quota");
  const start = numeric(object.billingCycleStart);
  const end = numeric(object.billingCycleEnd);
  const minutes = start > 0 && end > start ? Math.max(1, Math.trunc((end - start) / 60_000)) : 43_200;
  return quota("cursor", [{ usedPercent: clamp(used), windowMinutes: minutes, ...(end > 0 ? { resetsAt: Math.trunc(end) } : {}) }], {
    now,
    planName: titleCase(planName),
  });
}

async function cursorAuth(env) {
  const database = appDataPath(env, "Cursor", "User", "globalStorage", "state.vscdb");
  if (!database || !existsSync(database)) return undefined;
  const accessToken = await sqliteValue(database, "cursorAuth/accessToken").catch(() => undefined);
  if (!accessToken) return undefined;
  const membershipType = await sqliteValue(database, "cursorAuth/stripeMembershipType").catch(() => undefined);
  return { accessToken, membershipType };
}

export async function collectCursor({ env = process.env, now = Date.now(), fetchImpl = fetch } = {}) {
  const auth = await cursorAuth(env);
  if (!auth) throw new Error("Cursor is not signed in on this PC");
  if ((decodeJWTExpiry(auth.accessToken) || Infinity) <= now) throw new Error("Cursor sign-in is stale; open Cursor once to renew it");
  const payload = await fetchPayload(
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
    {
      method: "POST",
      body: "{}",
      headers: { Authorization: `Bearer ${auth.accessToken}`, "Content-Type": "application/json", "Connect-Protocol-Version": "1" },
    },
    { fetchImpl, timeoutMs: 12_000 },
  );
  return parseCursorUsage(payload, { now, planName: auth.membershipType });
}

function githubTokenFromJSON(object) {
  if (!object || typeof object !== "object") return undefined;
  for (const [host, value] of Object.entries(object)) {
    if (host === "github.com" || host.startsWith("github.com:")) {
      const token = String(value?.oauth_token || "").trim();
      if (token) return token;
    }
  }
  return undefined;
}

function githubTokenFromYAML(text) {
  let inGithub = false;
  for (const line of String(text).split(/\r?\n/)) {
    if (/^\S/.test(line)) {
      inGithub = line.trim().startsWith("github.com:");
      continue;
    }
    if (!inGithub) continue;
    const match = line.trim().match(/^oauth_token:\s*["']?([^"']+)["']?$/);
    if (match?.[1]?.trim()) return match[1].trim();
  }
  return undefined;
}

async function copilotToken(env) {
  for (const name of ["COPILOT_API_TOKEN", "GITHUB_COPILOT_TOKEN"]) {
    const token = String(environmentValue(env, name) || "").trim();
    if (token) return token;
  }
  const home = windowsHome(env);
  const jsonPaths = [
    join(home, ".config", "github-copilot", "apps.json"),
    join(home, ".config", "github-copilot", "hosts.json"),
    appDataPath(env, "GitHub Copilot", "apps.json"),
    appDataPath(env, "GitHub Copilot", "hosts.json"),
  ].filter(Boolean);
  for (const path of jsonPaths) {
    try {
      const token = githubTokenFromJSON(await readSmallJSON(path));
      if (token) return token;
    } catch {}
  }
  try { return githubTokenFromYAML(await readSmallText(join(home, ".config", "gh", "hosts.yml"))); }
  catch { return undefined; }
}

function usedPercentFromCopilotSnapshot(snapshot) {
  if (!snapshot || snapshot.unlimited === true) return undefined;
  const entitlement = numeric(snapshot.entitlement);
  const remaining = numeric(snapshot.remaining);
  if (entitlement === -1 || remaining === -1 || entitlement === 0) return undefined;
  const percentRemaining = numeric(snapshot.percent_remaining ?? snapshot.percentRemaining);
  if (percentRemaining !== undefined) return clamp(100 - percentRemaining);
  if (entitlement > 0 && remaining !== undefined) return clamp(100 - remaining / entitlement * 100);
  return undefined;
}

export function parseCopilotUsage(body, now = Date.now()) {
  const resetsAt = timestamp(body?.quota_reset_date ?? body?.limited_user_reset_date);
  const snapshots = body?.quota_snapshots || {};
  const values = [snapshots.premium_interactions, snapshots.chat, snapshots.completions]
    .map(usedPercentFromCopilotSnapshot)
    .filter((value) => value !== undefined);
  if (!values.length) throw new Error("Copilot returned no personal quota");
  return quota("copilot", values.slice(0, 2).map((usedPercent) => ({
    usedPercent,
    windowMinutes: 43_200,
    ...(resetsAt ? { resetsAt } : {}),
  })), { now, planName: titleCase(body?.copilot_plan) });
}

export async function collectCopilot({ env = process.env, now = Date.now(), fetchImpl = fetch } = {}) {
  const token = await copilotToken(env);
  if (!token) throw new Error("GitHub Copilot is not signed in on this PC");
  const payload = await fetchPayload("https://api.github.com/copilot_internal/user", {
    headers: {
      Authorization: `token ${token}`,
      Accept: "application/json",
      "Editor-Version": "vscode/1.96.2",
      "Editor-Plugin-Version": "copilot-chat/0.26.7",
      "User-Agent": "GitHubCopilotChat/0.26.7",
      "X-Github-Api-Version": "2025-04-01",
    },
  }, { fetchImpl });
  return parseCopilotUsage(payload, now);
}

function tomlValue(text, key) {
  for (const line of String(text).split(/\r?\n/)) {
    const match = line.trim().match(new RegExp(`^${key}\\s*=\\s*["']([^"']+)["']`));
    if (match?.[1]?.trim()) return match[1].trim();
  }
  return undefined;
}

async function codeiumAuth(providerID, env) {
  const home = windowsHome(env);
  if (providerID === "windsurf") {
    const apiKey = String(environmentValue(env, "WINDSURF_API_KEY") || "").trim();
    if (apiKey) return { apiKey, apiServerURL: String(environmentValue(env, "WINDSURF_API_SERVER_URL") || "https://server.codeium.com").replace(/\/$/, "") };
  }
  if (providerID === "devin") {
    try {
      const text = await readSmallText(join(home, ".local", "share", "devin", "credentials.toml"));
      const apiKey = tomlValue(text, "windsurf_api_key");
      if (apiKey) return { apiKey, apiServerURL: (tomlValue(text, "api_server_url") || "https://server.codeium.com").replace(/\/$/, "") };
    } catch {}
  }
  const database = appDataPath(env, providerID === "devin" ? "Devin" : "Windsurf", "User", "globalStorage", "state.vscdb");
  if (!database || !existsSync(database)) return undefined;
  const raw = await sqliteValue(database, "windsurfAuthStatus").catch(() => undefined);
  if (!raw) return undefined;
  try {
    const object = typeof raw === "string" ? JSON.parse(raw) : raw;
    const apiKey = String(object?.apiKey || "").trim();
    if (!apiKey) return undefined;
    return { apiKey, apiServerURL: String(object.apiServerUrl || "https://server.codeium.com").replace(/\/$/, "") };
  } catch { return undefined; }
}

export function parseCodeiumUsage(providerID, body, now = Date.now()) {
  const status = body?.userStatus?.planStatus || {};
  const plan = status.planInfo || {};
  const windows = [];
  const dailyRemaining = numeric(status.dailyQuotaRemainingPercent);
  if (!plan.hideDailyQuota && dailyRemaining !== undefined) {
    windows.push({ usedPercent: clamp(100 - dailyRemaining), windowMinutes: 1_440, ...(timestamp(status.dailyQuotaResetAtUnix) ? { resetsAt: timestamp(status.dailyQuotaResetAtUnix) } : {}) });
  }
  const weeklyRemaining = numeric(status.weeklyQuotaRemainingPercent);
  if (weeklyRemaining !== undefined) {
    windows.push({ usedPercent: clamp(100 - weeklyRemaining), windowMinutes: 10_080, ...(timestamp(status.weeklyQuotaResetAtUnix) ? { resetsAt: timestamp(status.weeklyQuotaResetAtUnix) } : {}) });
  }
  return quota(providerID, windows, { now, planName: String(plan.planName || "").trim() || undefined });
}

async function collectCodeium(providerID, { env = process.env, now = Date.now(), fetchImpl = fetch } = {}) {
  const auth = await codeiumAuth(providerID, env);
  if (!auth) throw new Error(`${titleCase(providerID)} is not signed in on this PC`);
  const payload = await fetchPayload(`${auth.apiServerURL}/exa.seat_management_pb.SeatManagementService/GetUserStatus`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Connect-Protocol-Version": "1" },
    body: JSON.stringify({ metadata: { apiKey: auth.apiKey, ideName: providerID, ideVersion: "1.0", extensionName: providerID, extensionVersion: "1.0", locale: "en" } }),
  }, { fetchImpl });
  return parseCodeiumUsage(providerID, payload, now);
}

export const collectDevin = (options) => collectCodeium("devin", options);
export const collectWindsurf = (options) => collectCodeium("windsurf", options);

async function grokAuth(env) {
  const root = await readSmallJSON(join(windowsHome(env), ".grok", "auth.json")).catch(() => undefined);
  if (!root || typeof root !== "object") return undefined;
  for (const key of Object.keys(root).sort()) {
    const token = String(root[key]?.key || "").trim();
    if (token) return { token, expiry: decodeJWTExpiry(token) || timestamp(root[key]?.expires_at ?? root[key]?.expires) };
  }
  return undefined;
}

export function parseGrokUsage(body, { now = Date.now(), planName } = {}) {
  const config = body?.config;
  const period = config?.currentPeriod;
  const start = timestamp(period?.start);
  const end = timestamp(period?.end);
  if (!start || !end || end <= start) throw new Error("Grok returned no quota period");
  const usedPercent = numeric(config.creditUsagePercent) ?? 0;
  return quota("grok", [{ usedPercent: clamp(usedPercent), windowMinutes: Math.max(1, Math.trunc((end - start) / 60_000)), resetsAt: end }], { now, planName });
}

export async function collectGrok({ env = process.env, now = Date.now(), fetchImpl = fetch } = {}) {
  const auth = await grokAuth(env);
  if (!auth) throw new Error("Grok CLI is not signed in on this PC");
  if (auth.expiry && auth.expiry <= now) throw new Error("Grok sign-in is stale; run Grok once to renew it");
  const headers = { Authorization: `Bearer ${auth.token}`, "X-XAI-Token-Auth": "xai-grok-cli", Accept: "application/json" };
  const body = await fetchPayload("https://cli-chat-proxy.grok.com/v1/billing?format=credits", { headers }, { fetchImpl });
  const settings = await fetchPayload("https://cli-chat-proxy.grok.com/v1/settings", { headers }, { fetchImpl }).catch(() => ({}));
  return parseGrokUsage(body, { now, planName: String(settings.subscription_tier_display || "").trim() || undefined });
}

export function parseAntigravityUsage(payload, now = Date.now()) {
  const groups = (payload?.response || payload)?.groups;
  if (!Array.isArray(groups)) throw new Error("Antigravity returned no quota groups");
  const pools = new Map();
  for (const group of groups) {
    for (const bucket of Array.isArray(group?.buckets) ? group.buckets : []) {
      const id = String(bucket.bucketId || "");
      const remaining = numeric(bucket.remainingFraction ?? bucket.remaining?.remainingFraction ?? bucket.remaining?.value);
      if (!id || remaining === undefined || pools.has(id)) continue;
      pools.set(id, {
        usedPercent: clamp((1 - remaining) * 100),
        windowMinutes: id.endsWith("-weekly") || id.toLowerCase().includes("weekly") ? 10_080 : 300,
        ...(timestamp(bucket.resetTime) ? { resetsAt: timestamp(bucket.resetTime) } : {}),
      });
    }
  }
  const primary = pools.get("gemini-5h") || pools.get("gemini-weekly");
  if (!primary) throw new Error("Antigravity returned no Gemini quota pool");
  const secondary = pools.has("gemini-5h") ? pools.get("gemini-weekly") : undefined;
  const scopedWindows = [
    ["3p-5h", "antigravity_3p_5h"],
    ["3p-weekly", "antigravity_3p_weekly"],
  ].flatMap(([bucketID, scopeID]) => pools.has(bucketID) ? [{ scopeID, displayName: "Claude / Third-party", window: pools.get(bucketID) }] : []);
  return quota("antigravity", [primary, secondary].filter(Boolean), { now, scopedWindows });
}

function loopbackRequest({ scheme, port, csrfToken }, body) {
  const transport = scheme === "https" ? https : http;
  const payload = Buffer.from(JSON.stringify(body));
  return new Promise((resolve, reject) => {
    const request = transport.request({
      host: "127.0.0.1",
      port,
      path: "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
      method: "POST",
      timeout: 4_000,
      headers: {
        "Content-Type": "application/json",
        "Content-Length": payload.length,
        "Connect-Protocol-Version": "1",
        "X-Codeium-Csrf-Token": csrfToken,
      },
      ...(scheme === "https" ? { rejectUnauthorized: false } : {}),
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => {
        if (response.statusCode !== 200) return reject(new Error(`Antigravity local service returned ${response.statusCode}`));
        try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); }
        catch { reject(new Error("Antigravity local service returned invalid JSON")); }
      });
    });
    request.on("timeout", () => request.destroy(new Error("Antigravity local service timed out")));
    request.on("error", reject);
    request.end(payload);
  });
}

async function antigravityProcesses() {
  const script = "Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'language_server*' -or $_.Name -like 'language-server*' } | ForEach-Object { \"$($_.ProcessId)`t$($_.CommandLine)\" }";
  const output = await runExecutable("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], { timeoutMs: 10_000 });
  return output.split(/\r?\n/).flatMap((line) => {
    const [pidText, command = ""] = line.split("\t", 2);
    const lower = command.toLowerCase();
    if (!lower.includes("antigravity") || !lower.includes("language_server") && !lower.includes("language-server")) return [];
    const token = command.match(/--csrf_token(?:=|\s+)([^\s]+)/i)?.[1];
    const pid = Number(pidText);
    return Number.isSafeInteger(pid) && pid > 0 && token ? [{ pid, csrfToken: token }] : [];
  });
}

async function listeningPorts(pid) {
  const script = `Get-NetTCPConnection -OwningProcess ${pid} -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort`;
  const output = await runExecutable("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], { timeoutMs: 6_000 });
  return [...new Set(output.split(/\s+/).map(Number).filter((value) => Number.isInteger(value) && value > 0 && value < 65_536))];
}

export async function collectAntigravity({ now = Date.now() } = {}) {
  for (const process of await antigravityProcesses().catch(() => [])) {
    for (const port of await listeningPorts(process.pid).catch(() => [])) {
      for (const scheme of ["https", "http"]) {
        try {
          const payload = await loopbackRequest({ scheme, port, csrfToken: process.csrfToken }, {
            metadata: { ideName: "antigravity", extensionName: "antigravity", ideVersion: "unknown", locale: "en" },
          });
          return parseAntigravityUsage(payload, now);
        } catch {}
      }
    }
  }
  throw new Error("Open Antigravity on this PC so TokenRemain can read its local quota service");
}

export function openCodeQuota(costs, now = Date.now()) {
  const sessionStart = now - 5 * 60 * 60_000;
  const session = costs.filter((row) => row.ms >= sessionStart && row.ms < now);
  const sessionSpend = session.reduce((sum, row) => sum + row.cost, 0);
  const date = new Date(now);
  const day = date.getUTCDay() || 7;
  const weekStart = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() - day + 1);
  const weekEnd = weekStart + 7 * 24 * 60 * 60_000;
  const weeklySpend = costs.filter((row) => row.ms >= weekStart && row.ms < weekEnd).reduce((sum, row) => sum + row.cost, 0);
  const firstSession = session.reduce((minimum, row) => Math.min(minimum, row.ms), Infinity);
  return quota("opencode", [
    {
      usedPercent: clamp(sessionSpend / 12 * 100),
      windowMinutes: 300,
      ...(Number.isFinite(firstSession) ? { resetsAt: firstSession + 5 * 60 * 60_000 } : {}),
      remainingBalance: { amount: Math.max(0, 12 - sessionSpend), currencyCode: "USD" },
    },
    {
      usedPercent: clamp(weeklySpend / 30 * 100),
      windowMinutes: 10_080,
      resetsAt: weekEnd,
      remainingBalance: { amount: Math.max(0, 30 - weeklySpend), currencyCode: "USD" },
    },
  ], { now, planName: "Go" });
}

export async function collectOpenCode({ env = process.env, now = Date.now() } = {}) {
  const home = windowsHome(env);
  const directory = String(environmentValue(env, "OPENCODE_DATA_DIR") || (
    environmentValue(env, "XDG_DATA_HOME") ? join(environmentValue(env, "XDG_DATA_HOME"), "opencode") : join(home, ".local", "share", "opencode")
  ));
  let databases;
  try { databases = readdirSync(directory).filter((name) => name.startsWith("opencode") && name.endsWith(".db")); }
  catch { throw new Error("OpenCode is not installed on this PC"); }
  const cutoff = now - 8 * 24 * 60 * 60_000;
  const costs = [];
  for (const name of databases) {
    const sql = "SELECT time_created AS ms, json_extract(data,'$.cost') AS cost FROM message WHERE time_created >= ? AND json_valid(data) AND json_extract(data,'$.role') = 'assistant' AND json_extract(data,'$.providerID') = 'opencode-go' AND json_type(data,'$.cost') IN ('integer','real')";
    const rows = await sqliteRows(join(directory, name), sql, [cutoff]).catch(() => []);
    costs.push(...rows.map((row) => ({ ms: numeric(row.ms), cost: numeric(row.cost) })).filter((row) => row.ms !== undefined && row.cost >= 0));
  }
  if (!costs.length) throw new Error("OpenCode has no local Go usage yet");
  return openCodeQuota(costs, now);
}

export function parseKiroUsage(raw, now = Date.now()) {
  const text = String(raw).replace(/\u001B\[[0-9;?]*[ -/]*[@-~]/g, "");
  if (/not logged in|login required|kiro-cli login|oauth error/i.test(text)) throw new Error("Kiro CLI is not signed in");
  let percent = numeric(text.match(/█+[░\s]*(\d+(?:\.\d+)?)%/)?.[1]);
  if (percent === undefined) {
    const covered = text.match(/\((\d+(?:\.\d+)?)\s+of\s+(\d+(?:\.\d+)?)\s+covered/i);
    if (covered && Number(covered[2]) > 0) percent = Number(covered[1]) / Number(covered[2]) * 100;
  }
  if (percent === undefined) throw new Error("Kiro CLI usage output was not recognized");
  const reset = text.match(/resets on (\d{4}-\d{2}-\d{2})/i)?.[1];
  const plan = text.match(/Plan:\s*([^\r\n]+)/i)?.[1]?.trim() || text.match(/\|\s*(KIRO\s+\w+)/i)?.[1]?.trim();
  return quota("kiro", [{ usedPercent: clamp(percent), windowMinutes: 43_200, ...(reset ? { resetsAt: Date.parse(`${reset}T00:00:00`) } : {}) }], { now, planName: titleCase(plan?.replace(/^kiro\s+/i, "")) });
}

export async function collectKiro({ env = process.env, now = Date.now() } = {}) {
  const executable = findExecutable(process.platform === "win32" ? ["kiro-cli.exe", "kiro-cli.cmd"] : ["kiro-cli"], { env });
  if (!executable) throw new Error("Kiro CLI is not installed on this PC");
  const output = await runExecutable(executable, ["chat", "--no-interactive", "/usage"], { env, timeoutMs: 30_000 });
  return parseKiroUsage(output, now);
}
