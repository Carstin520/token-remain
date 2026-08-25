import { createDecipheriv, createHash, createHmac } from "node:crypto";
import net from "node:net";
import { join } from "node:path";
import { signInRequiredError } from "../notification-policy.js";
import { providerDefinition } from "./catalog.js";
import {
  balanceWindow,
  clamp,
  environmentValue,
  fetchPayload,
  numeric,
  quota,
  readSmallJSON,
  readSmallText,
  timestamp,
  titleCase,
  windowsHome,
} from "./shared.js";

function clean(value) {
  const text = typeof value === "string" ? value.trim() : "";
  return text || undefined;
}

function configKey(text) {
  const raw = clean(text);
  if (!raw) return undefined;
  try {
    const object = JSON.parse(raw);
    if (typeof object === "string") return clean(object);
    return clean(object?.apiKey ?? object?.api_key ?? object?.key);
  } catch {
    return clean(raw.replace(/^"|"$/g, ""));
  }
}

export async function resolveManualSecret(providerID, { env = process.env, storedSecret } = {}) {
  const definition = providerDefinition(providerID);
  for (const name of definition?.environmentKeys || []) {
    const value = clean(environmentValue(env, name));
    if (value) return value;
  }
  const home = windowsHome(env);
  if (providerID === "zai") {
    const value = await readSmallText(join(home, ".config", "zai", "key.json")).then(configKey).catch(() => undefined);
    if (value) return value;
  }
  if (providerID === "openrouter") {
    const value = await readSmallText(join(home, ".config", "openrouter", "key.json")).then(configKey).catch(() => undefined);
    if (value) return value;
  }
  return clean(storedSecret);
}

function firstNumber(object, keys) {
  for (const key of keys) {
    const value = numeric(object?.[key]);
    if (value !== undefined) return value;
  }
  return undefined;
}

function resetTime(value) {
  return timestamp(value);
}

function findNested(value, predicate) {
  if (value && typeof value === "object") {
    if (!Array.isArray(value) && predicate(value)) return value;
    for (const child of Array.isArray(value) ? value : Object.values(value)) {
      const found = findNested(child, predicate);
      if (found) return found;
    }
  }
  return undefined;
}

function fetchHeaders(secret, scheme = "bearer") {
  return scheme === "cookie" ? { Cookie: secret, Accept: "application/json" } : { Authorization: `Bearer ${secret}`, Accept: "application/json" };
}

function durationLabel(minutes) {
  if (minutes === 60) return "Hourly";
  if (minutes === 300) return "Session";
  if (minutes === 1_440) return "Daily";
  if (minutes === 10_080) return "Weekly";
  if (minutes === 43_200) return "Monthly";
  return `${minutes} min`;
}

function scopeID(prefix, name, fallback, seen) {
  const slug = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
  const base = `${prefix}${slug || fallback}`.slice(0, 32);
  let candidate = base;
  let ordinal = 2;
  while (seen.has(candidate)) {
    const suffix = `_${ordinal}`;
    candidate = `${base.slice(0, 32 - suffix.length)}${suffix}`;
    ordinal += 1;
  }
  seen.add(candidate);
  return candidate;
}

function kimiScopeID(name, seen) {
  const slug = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
  const base = `kimi_${(slug || "window").slice(0, 25)}`;
  let candidate = base;
  let ordinal = 2;
  while (seen.has(candidate)) {
    candidate = `${base}_${ordinal}`;
    ordinal += 1;
  }
  seen.add(candidate);
  return candidate;
}

function zaiWindowMinutes(entry) {
  const unit = numeric(entry?.unit);
  const count = numeric(entry?.number);
  if (!(count > 0)) return undefined;
  const perUnit = unit === 1 || unit === 4 ? 1_440 : unit === 3 ? 60 : unit === 5 ? 1 : unit === 6 ? 10_080 : undefined;
  const minutes = perUnit * count;
  return minutes >= 1 && Number.isSafeInteger(Math.trunc(minutes)) ? Math.trunc(minutes) : undefined;
}

function zaiEntryName(entry) {
  for (const key of ["name", "display_name", "displayName", "show_name"]) {
    const value = clean(entry?.[key]);
    if (value && !["TOKENS_LIMIT", "TIME_LIMIT"].includes(value.toUpperCase())) return value;
  }
  return undefined;
}

function zaiWindow(entry, minutes, fallbackResetAt) {
  let percent;
  const usage = numeric(entry?.usage);
  if (usage > 0 && (numeric(entry?.remaining) !== undefined || numeric(entry?.currentValue ?? entry?.current_value) !== undefined)) {
    const usedFromRemaining = numeric(entry.remaining) === undefined ? 0 : usage - numeric(entry.remaining);
    const current = numeric(entry.currentValue ?? entry.current_value) ?? 0;
    percent = Math.max(0, Math.min(usage, Math.max(usedFromRemaining, current))) / usage * 100;
  } else {
    percent = numeric(entry?.percentage ?? entry?.usedPercent ?? entry?.used_percent);
  }
  if (percent === undefined) return undefined;
  const resetsAt = timestamp(entry?.nextResetTime ?? entry?.next_reset_time) ?? fallbackResetAt;
  return { usedPercent: clamp(percent), windowMinutes: minutes, ...(resetsAt ? { resetsAt } : {}) };
}

export function parseZAIUsage(body, { now = Date.now(), planName, subscriptionResetAt } = {}) {
  if (body?.success === false && String(body.msg || "").toLowerCase().includes("coding plan")) throw new Error("Z.ai account has no Coding Plan");
  const limits = body?.data?.limits ?? body?.limits;
  if (!Array.isArray(limits)) throw new Error("Z.ai returned no quota limits");
  const tokenEntries = [];
  const scopedWindows = [];
  const seen = new Set();
  for (const entry of limits) {
    const type = String(entry?.type ?? entry?.limit_type ?? entry?.name ?? "").toUpperCase();
    if (type === "TOKENS_LIMIT") {
      const minutes = zaiWindowMinutes(entry);
      const window = minutes && zaiWindow(entry, minutes);
      if (window) tokenEntries.push({ name: zaiEntryName(entry), window, order: tokenEntries.length });
    } else if (type === "TIME_LIMIT") {
      const minutes = zaiWindowMinutes(entry) ?? 43_200;
      const window = zaiWindow(entry, minutes, subscriptionResetAt);
      if (!window) continue;
      const name = zaiEntryName(entry);
      scopedWindows.push({
        scopeID: scopeID("zai_", name, `mcp_${minutes}m`, seen),
        displayName: name || "MCP",
        window,
        observedAt: now,
      });
    }
  }
  tokenEntries.sort((left, right) => left.window.windowMinutes - right.window.windowMinutes
    || right.window.usedPercent - left.window.usedPercent || left.order - right.order);
  const shortest = tokenEntries[0]?.window.windowMinutes;
  const longest = tokenEntries.at(-1)?.window.windowMinutes;
  const secondaryIndex = shortest !== undefined && longest !== shortest
    ? tokenEntries.findIndex((entry) => entry.window.windowMinutes === longest)
    : -1;
  let primary;
  let secondary;
  for (const [index, token] of tokenEntries.entries()) {
    const siblingCount = tokenEntries.filter((entry) => entry.window.windowMinutes === token.window.windowMinutes).length;
    if (index === 0) {
      primary = { ...token.window, ...(siblingCount > 1 && token.name ? { poolName: token.name } : {}) };
    } else if (index === secondaryIndex) {
      secondary = { ...token.window, ...(siblingCount > 1 && token.name ? { poolName: token.name } : {}) };
    } else {
      scopedWindows.push({
        scopeID: scopeID("zai_", token.name, `tokens_${token.window.windowMinutes}m`, seen),
        displayName: token.name || durationLabel(token.window.windowMinutes),
        window: token.window,
        observedAt: now,
      });
    }
  }
  if (!primary && scopedWindows.length) {
    const promoted = scopedWindows.shift();
    primary = { ...promoted.window, poolName: promoted.displayName };
  }
  if (!primary) throw new Error("Z.ai returned no usable quota window");
  return quota("zai", [primary, ...(secondary ? [secondary] : [])], { now, planName, scopedWindows });
}

async function collectZAI(secret, { fetchImpl, now, zaiRegion }) {
  const headers = fetchHeaders(secret);
  const origin = zaiRegion === "china" ? "https://open.bigmodel.cn" : "https://api.z.ai";
  const body = await fetchPayload(`${origin}/api/monitor/usage/quota/limit`, { headers }, { fetchImpl, timeoutMs: 12_000 });
  const subscription = await fetchPayload(`${origin}/api/biz/subscription/list`, { headers }, { fetchImpl, timeoutMs: 10_000 }).catch(() => undefined);
  return parseZAIUsage(body, {
    now,
    planName: clean(subscription?.data?.[0]?.productName),
    subscriptionResetAt: timestamp(subscription?.data?.[0]?.next_renew_time ?? subscription?.data?.[0]?.nextRenewTime),
  });
}

function decryptZCodeCredential(value, { env, home }) {
  if (typeof value !== "string" || !value.trim()) return undefined;
  if (!value.startsWith("enc:v1:")) return value.trim();
  try {
    const [ivText, tagText, ciphertextText] = value.slice("enc:v1:".length).split(".");
    if (!ivText || !tagText || !ciphertextText) return undefined;
    const username = clean(environmentValue(env, "USERNAME")) || clean(environmentValue(env, "USER")) || "user";
    const secret = clean(environmentValue(env, "ZCODE_CREDENTIAL_SECRET")) || `zcode-credential-fallback:win32:${home}:${username}`;
    const decipher = createDecipheriv("aes-256-gcm", createHash("sha256").update(secret).digest(), Buffer.from(ivText, "base64url"));
    decipher.setAuthTag(Buffer.from(tagText, "base64url"));
    return Buffer.concat([decipher.update(Buffer.from(ciphertextText, "base64url")), decipher.final()]).toString("utf8").trim() || undefined;
  } catch {
    return undefined;
  }
}

async function zcodeCandidates(env) {
  const home = windowsHome(env);
  const root = clean(environmentValue(env, "ZCODE_HOME")) || join(home, ".zcode");
  const config = await readSmallJSON(join(root, "v2", "config.json")).catch(() => undefined);
  const credentials = await readSmallJSON(join(root, "v2", "credentials.json")).catch(() => ({}));
  const providers = config?.provider;
  if (!providers || typeof providers !== "object") return [];
  const activeProvider = decryptZCodeCredential(credentials["oauth:active_provider"], { env, home });
  const jwt = decryptZCodeCredential(credentials.zcodejwttoken, { env, home });
  const keys = [
    "builtin:bigmodel-start-plan",
    "builtin:zai-start-plan",
    "builtin:bigmodel-coding-plan",
    "builtin:zai-coding-plan",
  ];
  const candidates = [];
  for (const key of keys) {
    const provider = providers[key];
    if (!provider || provider.enabled === false) continue;
    const kind = key.includes("-coding-plan") ? "coding" : "start";
    const region = key.includes(":zai-") ? "zai" : "bigmodel";
    const options = provider.options || {};
    const tokens = [];
    if (kind === "start" && activeProvider === region && jwt) tokens.push(jwt);
    if (clean(options.apiKey)) tokens.push(clean(options.apiKey));
    for (const token of [...new Set(tokens)]) candidates.push({ kind, region, token, baseURL: clean(options.baseURL), root });
  }
  return candidates;
}

export function parseZCodeBilling(body, now = Date.now()) {
  const code = numeric(body?.code);
  if (code !== undefined && code !== 0 && code !== 200) throw new Error("ZCode returned no plan balance");
  const balances = body?.data?.balances;
  if (!Array.isArray(balances) || !balances.length) throw new Error("ZCode returned no plan balance");
  const buckets = balances.flatMap((balance, order) => {
    const total = numeric(balance.total_units);
    const used = numeric(balance.used_units);
    if (!(total > 0) || !(used >= 0)) return [];
    const resetsAt = timestamp(balance.period_end ?? balance.expires_at);
    return [{
      order,
      name: clean(balance.show_name),
      planID: clean(balance.plan_id),
      window: { usedPercent: clamp(used / total * 100), windowMinutes: 43_200, ...(resetsAt ? { resetsAt } : {}) },
    }];
  }).sort((left, right) => right.window.usedPercent - left.window.usedPercent || left.order - right.order);
  if (!buckets.length) throw new Error("ZCode returned no usable plan balance");
  const busiest = buckets[0];
  const seen = new Set();
  const scopedWindows = buckets.slice(1).map((bucket, index) => ({
    scopeID: scopeID("zcode_", bucket.name, `pool_${index + 2}`, seen),
    displayName: bucket.name || `Pool ${index + 2}`,
    window: bucket.window,
    observedAt: now,
  }));
  const tier = busiest.planID?.match(/\b(lite|start|pro|max|team|enterprise)\b/i)?.[1];
  return quota("zai", [{ ...busiest.window, ...(busiest.name ? { poolName: busiest.name } : {}) }], {
    now,
    planName: tier ? `ZCode ${titleCase(tier)}` : "ZCode",
    scopedWindows,
  });
}

async function collectZCodeCandidate(candidate, { fetchImpl, now, env }) {
  if (candidate.kind === "coding") {
    const configured = candidate.region === "zai" && candidate.baseURL ? new URL(candidate.baseURL) : undefined;
    const configuredHost = configured?.protocol === "https:" && (configured.hostname === "api.z.ai" || configured.hostname.endsWith(".api.z.ai"))
      ? `${configured.protocol}//${configured.host}`
      : undefined;
    const origin = candidate.region === "zai" ? (configuredHost || "https://api.z.ai") : "https://bigmodel.cn";
    const body = await fetchPayload(`${origin}/api/monitor/usage/quota/limit`, { headers: { Authorization: candidate.token, Accept: "application/json" } }, { fetchImpl, timeoutMs: 10_000 });
    const parsed = await parseZAIQuota(body, { fetchImpl, now, subscription: false });
    const level = clean(body?.data?.level);
    return level ? { ...parsed, planName: `ZCode ${titleCase(level)}` } : parsed;
  }
  const appVersion = clean(environmentValue(env, "ZCODE_APP_VERSION")) || "3.2.5";
  const deviceMid = await readSmallJSON(join(candidate.root, "v2", "credentials.json"))
    .then((credentials) => decryptZCodeCredential(credentials.zcodefeedbackclientid, { env, home: windowsHome(env) }))
    .catch(() => undefined);
  const body = await fetchPayload(`https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=${encodeURIComponent(appVersion)}`, {
    headers: {
      Authorization: `Bearer ${candidate.token}`,
      Accept: "application/json",
      "User-Agent": `ZCode/${appVersion}`,
      "HTTP-Referer": "https://zcode.z.ai/",
      "X-ZCode-App-Version": appVersion,
      "X-Platform": "win32",
      "X-Release-Channel": "stable",
      "X-Os-Category": "win32",
      ...(deviceMid ? { "X-Device-Mid": deviceMid } : {}),
    },
  }, { fetchImpl, timeoutMs: 10_000 });
  return parseZCodeBilling(body, now);
}

async function parseZAIQuota(body, { fetchImpl, now, subscription = true, headers } = {}) {
  let planName;
  let subscriptionResetAt;
  if (subscription) {
    const details = await fetchPayload("https://api.z.ai/api/biz/subscription/list", { headers }, { fetchImpl, timeoutMs: 10_000 }).catch(() => undefined);
    planName = clean(details?.data?.[0]?.productName);
    subscriptionResetAt = timestamp(details?.data?.[0]?.next_renew_time ?? details?.data?.[0]?.nextRenewTime);
  }
  return parseZAIUsage(body, { now, planName, subscriptionResetAt });
}

export function parseOpenRouterUsage(creditsBody, keyBody, now = Date.now()) {
  const credits = creditsBody?.data ?? creditsBody;
  const key = keyBody?.data ?? keyBody;
  let creditsWindow;
  const totalCredits = numeric(credits?.total_credits);
  const totalUsage = numeric(credits?.total_usage);
  if (totalCredits >= 0 && totalUsage >= 0) {
    const remaining = Math.max(0, totalCredits - totalUsage);
    creditsWindow = balanceWindow(remaining, "USD", totalCredits > 0 ? totalUsage / totalCredits * 100 : 100);
  }
  let keyWindow;
  const limit = numeric(key?.limit);
  const rawUsage = numeric(key?.usage);
  const rawRemaining = numeric(key?.limit_remaining);
  if (limit > 0 && (rawUsage !== undefined || rawRemaining !== undefined)) {
    const used = Math.max(0, rawUsage ?? (limit - (rawRemaining ?? limit)));
    const remaining = Math.max(0, rawRemaining ?? (limit - used));
    const cadence = String(key?.limit_reset || "").toLowerCase();
    const windowMinutes = cadence === "daily" ? 1_440 : cadence === "weekly" ? 10_080 : cadence === "monthly" ? 43_200 : 0;
    keyWindow = balanceWindow(remaining, "USD", used / limit * 100);
    keyWindow.windowMinutes = windowMinutes;
  }
  const primary = keyWindow ?? creditsWindow;
  if (!primary) throw new Error("OpenRouter returned no usable credits or key limit");
  const canPublishCreditsWindow = keyWindow && creditsWindow && keyWindow.windowMinutes !== creditsWindow.windowMinutes;
  const scopedWindows = keyWindow && creditsWindow && !canPublishCreditsWindow ? [{
    scopeID: "openrouter_credits",
    displayName: "Credits",
    window: creditsWindow,
    observedAt: now,
  }] : undefined;
  const planName = key?.is_management_key === true ? "Management"
    : typeof key?.is_free_tier === "boolean" ? (key.is_free_tier ? "Free Tier" : "Pay As You Go") : undefined;
  return quota("openrouter", [primary, ...(canPublishCreditsWindow ? [creditsWindow] : [])], {
    now,
    planName,
    remainingBalance: primary.remainingBalance,
    scopedWindows,
  });
}

async function collectOpenRouter(secret, { fetchImpl, now }) {
  const headers = fetchHeaders(secret);
  const credits = await fetchPayload("https://openrouter.ai/api/v1/credits", { headers }, { fetchImpl });
  const key = await fetchPayload("https://openrouter.ai/api/v1/key", { headers }, { fetchImpl }).catch(() => undefined);
  return parseOpenRouterUsage(credits, key, now);
}

async function collectDeepSeek(secret, { fetchImpl, now }) {
  const body = await fetchPayload("https://api.deepseek.com/user/balance", { headers: fetchHeaders(secret) }, { fetchImpl });
  const rows = Array.isArray(body?.balance_infos) ? body.balance_infos : [];
  const row = rows.find((item) => (numeric(item.total_balance) ?? 0) > 0) || rows[0];
  if (!row) throw new Error("DeepSeek returned no balance row");
  const amount = Math.max(0, numeric(row.total_balance) ?? 0);
  const currencyCode = String(row.currency || "USD").toUpperCase();
  const remainingBalance = { amount, currencyCode };
  return quota("deepseek", [balanceWindow(amount, currencyCode, body.is_available === false || amount <= 0 ? 100 : 0)], { now, planName: "Pay As You Go", remainingBalance });
}

export function parseKimiUsage(body, now = Date.now()) {
  const entries = body?.limits ?? body?.data?.limits ?? [];
  const parsed = [];
  for (const [order, entry] of entries.entries()) {
    const detail = entry?.detail || entry;
    const used = firstNumber(detail, ["used", "usedAmount", "used_amount", "usage"]);
    const limit = firstNumber(detail, ["limit", "total", "quota", "amount"]);
    const remaining = firstNumber(detail, ["remaining", "left", "remain"]);
    let percent = limit > 0 && used !== undefined ? used / limit * 100 : limit > 0 && remaining !== undefined ? (limit - remaining) / limit * 100 : firstNumber(detail, ["percent", "usedPercent", "used_percent", "ratio", "usedRatio", "used_ratio"]);
    if (percent === undefined) continue;
    if (percent <= 1) percent *= 100;
    const window = entry.window || {};
    const duration = firstNumber(window, ["duration", "windowDuration", "window_duration", "size", "value"]);
    const unit = String(window.timeUnit ?? window.time_unit ?? window.unit ?? "").toUpperCase();
    const multiplier = unit.includes("MINUTE") ? 1 : unit.includes("HOUR") ? 60 : unit.includes("DAY") ? 1_440 : unit.includes("WEEK") ? 10_080 : unit.includes("SECOND") ? 1 / 60 : undefined;
    const windowMinutes = duration !== undefined && multiplier ? Math.trunc(duration * multiplier) : 300;
    const resetsAt = resetTime(detail.resetTime ?? detail.reset_time ?? window.resetTime);
    let name;
    for (const source of [entry, detail]) {
      for (const key of ["name", "title", "label", "displayName", "display_name"]) {
        name ||= clean(source?.[key]);
      }
    }
    parsed.push({ order, name, window: { usedPercent: clamp(percent), windowMinutes, ...(resetsAt ? { resetsAt } : {}) } });
  }
  parsed.sort((left, right) => left.window.windowMinutes - right.window.windowMinutes || left.order - right.order);
  if (!parsed.length) throw new Error("Kimi returned no usable quota window");
  const shortest = parsed[0].window.windowMinutes;
  const longest = parsed.at(-1).window.windowMinutes;
  const busiestIndex = (minutes) => {
    let best = parsed.findIndex((item) => item.window.windowMinutes === minutes);
    for (const [index, item] of parsed.entries()) {
      if (item.window.windowMinutes === minutes && item.window.usedPercent > parsed[best].window.usedPercent) best = index;
    }
    return best;
  };
  const siblingCount = (minutes) => parsed.filter((item) => item.window.windowMinutes === minutes).length;
  const primaryIndex = busiestIndex(shortest);
  const secondaryIndex = longest === shortest ? -1 : busiestIndex(longest);
  const primaryItem = parsed[primaryIndex];
  const primary = { ...primaryItem.window, ...(siblingCount(shortest) > 1 ? { poolName: primaryItem.name || durationLabel(shortest) } : {}) };
  const secondaryItem = secondaryIndex >= 0 ? parsed[secondaryIndex] : undefined;
  const secondary = secondaryItem ? { ...secondaryItem.window, ...(siblingCount(longest) > 1 ? { poolName: secondaryItem.name || durationLabel(longest) } : {}) } : undefined;
  const scopedWindows = [];
  const seen = new Set();
  for (const [index, item] of parsed.entries()) {
    if (index === primaryIndex || index === secondaryIndex) continue;
    const name = item.name || durationLabel(item.window.windowMinutes);
    scopedWindows.push({
      scopeID: kimiScopeID(name, seen),
      displayName: name,
      window: item.window,
      observedAt: now,
    });
  }
  return quota("kimi", [primary, ...(secondary ? [secondary] : [])], { now, scopedWindows });
}

async function collectKimi(secret, { fetchImpl, now }) {
  let body;
  if (secret.split(".").length === 3) {
    let payload = {};
    try { payload = JSON.parse(Buffer.from(secret.split(".")[1], "base64url").toString("utf8")); } catch {}
    const headers = {
      Authorization: `Bearer ${secret}`,
      Cookie: `kimi-auth=${secret}`,
      "Content-Type": "application/json",
      Accept: "application/json",
      Origin: "https://www.kimi.com",
      Referer: "https://www.kimi.com/code/console",
      "connect-protocol-version": "1",
      "x-msh-platform": "web",
      ...(payload.device_id ? { "x-msh-device-id": String(payload.device_id) } : {}),
      ...(payload.ssid ? { "x-msh-session-id": String(payload.ssid) } : {}),
      ...(payload.sub ? { "x-traffic-id": String(payload.sub) } : {}),
    };
    body = await fetchPayload("https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages", { method: "POST", headers, body: JSON.stringify({ scope: ["FEATURE_CODING"] }) }, { fetchImpl });
  } else {
    body = await fetchPayload("https://api.kimi.com/coding/v1/usages", { headers: fetchHeaders(secret) }, { fetchImpl });
  }
  return parseKimiUsage(body, now);
}

async function kimiLocalCredential(env, now) {
  if (["KIMI_CODE_BASE_URL", "KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST"].some((name) => clean(environmentValue(env, name)))) return undefined;
  const root = clean(environmentValue(env, "KIMI_CODE_HOME")) || join(windowsHome(env), ".kimi-code");
  const object = await readSmallJSON(join(root, "credentials", "kimi-code.json")).catch(() => undefined);
  const token = clean(object?.access_token);
  const expiresAt = timestamp(object?.expires_at);
  if (!token || !expiresAt || expiresAt <= now + 60_000) return undefined;
  const deviceID = await readSmallText(join(root, "device_id")).then(clean).catch(() => undefined);
  return { token, deviceID };
}

async function collectKimiLocal(credential, { fetchImpl, now }) {
  const body = await fetchPayload("https://api.kimi.com/coding/v1/usages", {
    headers: {
      Authorization: `Bearer ${credential.token}`,
      Accept: "application/json",
      "X-Msh-Platform": "kimi_code_cli",
      ...(credential.deviceID ? { "X-Msh-Device-Id": credential.deviceID } : {}),
    },
  }, { fetchImpl });
  return parseKimiUsage(body, now);
}

async function collectMiniMax(secret, { fetchImpl, now }) {
  let lastError;
  for (const host of ["https://api.minimax.io", "https://api.minimaxi.com"]) {
    try {
      const body = await fetchPayload(`${host}/v1/api/openplatform/coding_plan/remains`, { headers: fetchHeaders(secret) }, { fetchImpl });
      const rows = body?.data?.model_remains ?? body?.model_remains ?? [];
      const row = rows.find((item) => item.model_name === "general") || rows[0];
      if (!row) throw new Error("MiniMax returned no Coding Plan quota");
      const windows = [];
      const session = numeric(row.current_interval_remaining_percent);
      const weekly = numeric(row.current_weekly_remaining_percent);
      if (session !== undefined) windows.push({ usedPercent: clamp(100 - session), windowMinutes: 300, ...(resetTime(row.end_time) ? { resetsAt: resetTime(row.end_time) } : {}) });
      if (weekly !== undefined) windows.push({ usedPercent: clamp(100 - weekly), windowMinutes: 10_080, ...(resetTime(row.weekly_end_time) ? { resetsAt: resetTime(row.weekly_end_time) } : {}) });
      return quota("minimax", windows, { now, planName: "Coding Plan" });
    } catch (error) { lastError = error; }
  }
  throw lastError;
}

function mimoMetric(row) {
  if (!row) return undefined;
  const used = numeric(row.used);
  const limit = numeric(row.limit ?? row.total);
  const ratio = numeric(row.percent);
  const percent = used !== undefined && limit > 0 ? used / limit * 100 : ratio !== undefined ? ratio * 100 : undefined;
  return percent === undefined ? undefined : clamp(percent);
}

function mimoDayReset(row, now) {
  for (const key of ["resetTime", "reset_time", "resetAt", "reset_at", "endTime", "end_time"]) {
    const value = timestamp(row?.[key]);
    if (value) return value;
  }
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(new Date(now));
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return Date.parse(`${values.year}-${values.month}-${values.day}T16:00:00Z`);
}

export function parseMiMoUsage(body, now = Date.now()) {
  const payload = body?.data ?? body;
  const month = findNested(body, (object) => String(object.name || "").toLowerCase() === "month_total_token");
  const daily = findNested(body, (object) => String(object.name || "").toLowerCase() === "day_token");
  const monthPercent = mimoMetric(month);
  const dailyPercent = mimoMetric(daily);
  const amount = numeric(payload?.balance);
  const accountBalance = amount !== undefined ? { amount: Math.max(0, amount), currencyCode: String(payload?.currency || "").toUpperCase() } : undefined;
  if (monthPercent !== undefined) {
    const scopedWindows = dailyPercent === undefined ? undefined : [{
      scopeID: "mimo_daily",
      displayName: "Daily",
      window: { usedPercent: dailyPercent, windowMinutes: 1_440, resetsAt: mimoDayReset(daily, now) },
      observedAt: now,
    }];
    return quota("mimo", [{ usedPercent: monthPercent, windowMinutes: 43_200 }], { now, accountBalance, scopedWindows });
  }
  if (accountBalance) {
    return quota("mimo", [balanceWindow(accountBalance.amount, accountBalance.currencyCode, accountBalance.amount > 0 ? 0 : 100)], {
      now,
      planName: "Pay As You Go",
      accountBalance,
      remainingBalance: accountBalance,
    });
  }
  throw new Error("MiMo returned no usable balance or monthly quota");
}

async function collectMiMo(secret, { fetchImpl, now }) {
  const body = await fetchPayload("https://platform.xiaomimimo.com/api/v1/balance", {
    headers: { ...fetchHeaders(secret, "cookie"), Referer: "https://platform.xiaomimimo.com/#/console/balance" },
  }, { fetchImpl });
  return parseMiMoUsage(body, now);
}

function qoderSummary(payload, camel, snake) {
  const container = payload?.[camel] ?? payload?.[snake];
  const summary = container?.quotaSummary ?? container?.quota_summary;
  const used = numeric(summary?.usedValue ?? summary?.used_value);
  const total = numeric(summary?.limitValue ?? summary?.limit_value);
  return used >= 0 && total >= 0 ? { used, total } : undefined;
}

export function parseQoderRPCUsage(result, now = Date.now()) {
  const row = result?.userQuota;
  const used = numeric(row?.used);
  const total = numeric(row?.total);
  if (!(used >= 0) || !(total >= 0)) throw new Error("Qoder local service returned an invalid quota");
  const reported = numeric(result.totalUsagePercentage ?? row.percentage);
  const usedPercent = total === 0 ? 0 : result.isQuotaExceeded === true ? 100 : reported ?? used / total * 100;
  const reset = timestamp(result.expiresAt);
  const resetsAt = reset && reset < 4_102_444_800_000 ? reset : undefined;
  return quota("qoder", [{ usedPercent: clamp(usedPercent), windowMinutes: 43_200, ...(resetsAt ? { resetsAt } : {}) }], {
    now,
    planName: clean(result.userType),
  });
}

export function qoderFrameBody(buffer) {
  const headerEnd = buffer.indexOf("\r\n\r\n");
  if (headerEnd < 0) {
    if (buffer.length > 8_192) throw new Error("Qoder local service returned an invalid frame");
    return undefined;
  }
  const header = buffer.subarray(0, headerEnd).toString("utf8");
  const length = Number(header.split("\r\n").find((line) => line.toLowerCase().startsWith("content-length:"))?.slice("content-length:".length).trim());
  if (!Number.isSafeInteger(length) || length < 0 || length > 4 * 1024 * 1024) throw new Error("Qoder local service returned an invalid frame");
  const body = buffer.subarray(headerEnd + 4);
  return body.length >= length ? body.subarray(0, length) : undefined;
}

function qoderExchange(socketPath, method = "credit/usage") {
  const body = Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: {} }));
  const request = Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    const chunks = [];
    let settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      if (error) reject(error); else resolve(result);
    };
    socket.setTimeout(1_500, () => finish(new Error("Qoder local service timed out")));
    socket.on("connect", () => socket.write(request));
    socket.on("data", (chunk) => {
      chunks.push(chunk);
      try {
        const frame = qoderFrameBody(Buffer.concat(chunks));
        if (!frame) return;
        const message = JSON.parse(frame.toString("utf8"));
        if (message.error) return finish(new Error(clean(message.error.message) || "Qoder local request failed"));
        if (!message.result || typeof message.result !== "object") return finish(new Error("Qoder local service returned no result"));
        finish(undefined, message.result);
      } catch (error) { finish(error); }
    });
    socket.on("error", (error) => finish(error));
    socket.on("end", () => finish(new Error("Qoder local service closed before responding")));
  });
}

async function qoderLocalQuota({ env, now, exchange = qoderExchange }) {
  const appData = clean(environmentValue(env, "APPDATA"));
  const home = windowsHome(env);
  const editions = [
    { directory: "Qoder", override: "QODER_HOME" },
    { directory: "QoderCN", override: "QODER_CN_HOME" },
  ];
  for (const edition of editions) {
    const root = clean(environmentValue(env, edition.override)) || (appData ? join(appData, edition.directory) : join(home, "AppData", "Roaming", edition.directory));
    const info = await readSmallJSON(join(root, "SharedClientCache", ".info.json")).catch(() => undefined);
    const socketPath = clean(info?.ipcServerPath);
    if (!socketPath) continue;
    try { return parseQoderRPCUsage(await exchange(socketPath, "credit/usage"), now); }
    catch {}
  }
  return undefined;
}

async function collectQoder(secret, { env, fetchImpl, now, qoderExchange: exchange }) {
  const local = await qoderLocalQuota({ env, now, exchange });
  if (local) return local;
  if (!secret) throw new Error("Open Qoder to use its local session, or add a Cookie fallback in Data Sources");
  const china = /qoder\.com\.cn/i.test(secret) || /^(cn|china)$/i.test(clean(environmentValue(env, "QODER_SITE")) || "");
  const origin = china ? "https://qoder.com.cn" : "https://qoder.com";
  const body = await fetchPayload(`${origin}/api/v2/me/usages/big_model_credits`, {
    headers: {
      ...fetchHeaders(secret, "cookie"),
      Origin: origin,
      Referer: `${origin}/account/usage`,
      "X-Requested-With": "XMLHttpRequest",
      "Bx-V": "2.5.35",
    },
  }, { fetchImpl });
  const payload = body?.data ?? body;
  return parseQoderUsage(payload, now);
}

export function parseQoderUsage(payload, now = Date.now()) {
  const total = qoderSummary(payload, "totalQuota", "total_quota");
  const shared = qoderSummary(payload, "sharedQuota", "shared_quota");
  const personalPool = total?.total > 0 ? { name: "Personal", scopeID: "qoder_personal", usedPercent: clamp(total.used / total.total * 100) } : undefined;
  const sharedPool = shared?.total > 0 ? { name: "Shared", scopeID: "qoder_shared", usedPercent: clamp(shared.used / shared.total * 100) } : undefined;
  if (!personalPool && !sharedPool) throw new Error("Qoder returned no credits quota");
  if (!personalPool || !sharedPool) {
    const only = personalPool ?? sharedPool;
    return quota("qoder", [{ usedPercent: only.usedPercent, windowMinutes: 43_200 }], { now });
  }
  const [busiest, other] = sharedPool.usedPercent > personalPool.usedPercent
    ? [sharedPool, personalPool]
    : [personalPool, sharedPool];
  return quota("qoder", [{ usedPercent: busiest.usedPercent, windowMinutes: 43_200, poolName: busiest.name }], {
    now,
    scopedWindows: [{
      scopeID: other.scopeID,
      displayName: other.name,
      window: { usedPercent: other.usedPercent, windowMinutes: 43_200 },
      observedAt: now,
    }],
  });
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function hmac(key, value, encoding) {
  return createHmac("sha256", key).update(value).digest(encoding);
}

function volcengineHeaders(accessKeyId, secretAccessKey, url, date) {
  const timestampValue = date.toISOString().replace(/[-:]|\.\d{3}/g, "");
  const dateStamp = timestampValue.slice(0, 8);
  const payloadHash = sha256("");
  const contentType = "application/x-www-form-urlencoded; charset=utf-8";
  const query = [...url.searchParams.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`).join("&");
  const signedHeaders = "content-type;host;x-content-sha256;x-date";
  const canonical = ["POST", url.pathname || "/", query, `content-type:${contentType}`, `host:${url.host}`, `x-content-sha256:${payloadHash}`, `x-date:${timestampValue}`, "", signedHeaders, payloadHash].join("\n");
  const scope = `${dateStamp}/cn-beijing/ark/request`;
  const stringToSign = ["HMAC-SHA256", timestampValue, scope, sha256(canonical)].join("\n");
  const dateKey = hmac(Buffer.from(secretAccessKey), dateStamp);
  const regionKey = hmac(dateKey, "cn-beijing");
  const serviceKey = hmac(regionKey, "ark");
  const signingKey = hmac(serviceKey, "request");
  const signature = hmac(signingKey, stringToSign, "hex");
  return {
    Accept: "application/json",
    "Content-Type": contentType,
    "X-Date": timestampValue,
    "X-Content-Sha256": payloadHash,
    Authorization: `HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  };
}

async function collectVolcengine(secret, { fetchImpl, now }) {
  const separator = secret.indexOf(":");
  if (separator <= 0 || separator === secret.length - 1) throw new Error("Volcengine credential must be AccessKeyId:SecretAccessKey");
  const url = new URL("https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01");
  const body = await fetchPayload(url, {
    method: "POST",
    headers: volcengineHeaders(secret.slice(0, separator), secret.slice(separator + 1), url, new Date(now)),
    body: "",
  }, { fetchImpl });
  return parseVolcengineUsage(body, now);
}

function deterministicPercent(value) {
  if (!value || typeof value !== "object") return undefined;
  if (!Array.isArray(value)) {
    const percent = numeric(value.Percent ?? value.percent);
    if (percent !== undefined) return percent;
    for (const key of Object.keys(value).sort()) {
      const found = deterministicPercent(value[key]);
      if (found !== undefined) return found;
    }
    return undefined;
  }
  for (const child of value) {
    const found = deterministicPercent(child);
    if (found !== undefined) return found;
  }
  return undefined;
}

export function parseVolcengineUsage(body, now = Date.now()) {
  const result = body?.Result ?? body?.result;
  let percent;
  for (const key of ["user_limit", "UserLimit", "userLimit"]) {
    percent ??= numeric(result?.[key]?.Percent ?? result?.[key]?.percent);
  }
  percent ??= deterministicPercent(result);
  if (percent === undefined) throw new Error("Volcengine returned no Coding Plan quota");
  return quota("volcengine", [{ usedPercent: clamp(percent), windowMinutes: 300 }], { now, planName: "Coding Plan" });
}

export function parseOllamaUsage(html, now = Date.now()) {
  if (/sign in/i.test(html) && !/usage/i.test(html)) throw signInRequiredError("Ollama Cloud Cookie was rejected");
  let session;
  let hourly;
  let weekly;
  const pattern = /(Session usage|Hourly usage|Weekly usage)[\s\S]{0,400}?([0-9]+(?:\.[0-9]+)?)\s*%\s*used/gi;
  for (const match of html.matchAll(pattern)) {
    const label = match[1].toLowerCase();
    const window = { usedPercent: clamp(Number(match[2])), windowMinutes: label.startsWith("weekly") ? 10_080 : label.startsWith("hourly") ? 60 : 300 };
    if (label.startsWith("weekly")) weekly ??= window;
    else if (label.startsWith("hourly")) hourly ??= window;
    else session ??= window;
  }
  const primary = session ?? weekly ?? hourly;
  if (!primary) throw new Error("Ollama returned no usable quota window");
  const scopedWindows = hourly && !(session === undefined && weekly === undefined) ? [{
    scopeID: "ollama_hourly",
    displayName: "Hourly",
    window: hourly,
    observedAt: now,
  }] : undefined;
  return quota("ollama", [primary, ...(session && weekly ? [weekly] : [])], { now, scopedWindows });
}

async function collectOllama(secret, { fetchImpl, now }) {
  const html = await fetchPayload("https://ollama.com/settings", { headers: { Cookie: secret, Accept: "text/html,application/xhtml+xml" } }, { fetchImpl, text: true });
  return parseOllamaUsage(html, now);
}

const COLLECTORS = {
  zai: collectZAI,
  openrouter: collectOpenRouter,
  deepseek: collectDeepSeek,
  kimi: collectKimi,
  minimax: collectMiniMax,
  mimo: collectMiMo,
  qoder: collectQoder,
  volcengine: collectVolcengine,
  ollama: collectOllama,
};

export async function collectManualProvider(providerID, { env = process.env, storedSecret, now = Date.now(), fetchImpl = fetch, qoderExchange, zaiRegion } = {}) {
  if (providerID === "qoder") {
    const secret = await resolveManualSecret(providerID, { env, storedSecret });
    return collectQoder(secret, { env, now, fetchImpl, qoderExchange });
  }
  if (providerID === "kimi") {
    const local = await kimiLocalCredential(env, now);
    if (local) return collectKimiLocal(local, { fetchImpl, now });
  }
  if (providerID === "zai") {
    let localError;
    for (const candidate of await zcodeCandidates(env)) {
      try { return await collectZCodeCandidate(candidate, { fetchImpl, now, env }); }
      catch (error) { localError ||= error; }
    }
    const secret = await resolveManualSecret(providerID, { env, storedSecret });
    if (secret) return collectZAI(secret, { now, fetchImpl, zaiRegion });
    if (localError) throw localError;
  }
  const secret = await resolveManualSecret(providerID, { env, storedSecret });
  if (!secret) throw new Error(`${providerDefinition(providerID)?.credentialKind || "Credential"} is not configured on this PC`);
  const collector = COLLECTORS[providerID];
  if (!collector) throw new Error("Unsupported local credential provider");
  return collector(secret, { env, now, fetchImpl });
}
