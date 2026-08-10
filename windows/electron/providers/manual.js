import { createDecipheriv, createHash, createHmac } from "node:crypto";
import net from "node:net";
import { join } from "node:path";
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

async function collectZAI(secret, { fetchImpl, now }) {
  const headers = fetchHeaders(secret);
  const body = await fetchPayload("https://api.z.ai/api/monitor/usage/quota/limit", { headers }, { fetchImpl, timeoutMs: 12_000 });
  if (body?.success === false && String(body.msg || "").toLowerCase().includes("coding plan")) throw new Error("Z.ai account has no Coding Plan");
  const limits = body?.data?.limits ?? body?.limits;
  if (!Array.isArray(limits)) throw new Error("Z.ai returned no quota limits");
  const windows = [];
  for (const entry of limits) {
    if ((entry.type ?? entry.name) !== "TOKENS_LIMIT") continue;
    const unit = numeric(entry.unit);
    const count = numeric(entry.number);
    const perUnit = unit === 3 ? 60 : unit === 4 ? 1_440 : unit === 6 ? 10_080 : unit === 5 ? 43_200 : undefined;
    const percentage = numeric(entry.percentage);
    if (!perUnit || !(count > 0) || percentage === undefined) continue;
    windows.push({ usedPercent: clamp(percentage), windowMinutes: Math.trunc(perUnit * count), ...(resetTime(entry.nextResetTime) ? { resetsAt: resetTime(entry.nextResetTime) } : {}) });
  }
  windows.sort((left, right) => left.windowMinutes - right.windowMinutes);
  const subscription = await fetchPayload("https://api.z.ai/api/biz/subscription/list", { headers }, { fetchImpl, timeoutMs: 10_000 }).catch(() => undefined);
  return quota("zai", windows.slice(0, 2), { now, planName: clean(subscription?.data?.[0]?.productName) });
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

function parseZCodeBilling(body, now) {
  const balances = body?.data?.balances;
  if (!Array.isArray(balances)) throw new Error("ZCode returned no plan balance");
  const windows = balances.flatMap((balance) => {
    const total = numeric(balance.total_units);
    const used = numeric(balance.used_units);
    if (!(total > 0) || !(used >= 0)) return [];
    const resetsAt = timestamp(balance.period_end ?? balance.expires_at);
    return [{ total, window: { usedPercent: clamp(used / total * 100), windowMinutes: 43_200, ...(resetsAt ? { resetsAt } : {}) } }];
  }).sort((left, right) => right.total - left.total);
  if (!windows.length) throw new Error("ZCode returned no usable plan balance");
  const planID = clean(balances[0]?.plan_id);
  const tier = planID?.match(/\b(lite|start|pro|max|team|enterprise)\b/i)?.[1];
  return quota("zai", windows.slice(0, 2).map((item) => item.window), { now, planName: tier ? `ZCode ${titleCase(tier)}` : "ZCode" });
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
  if (body?.success === false && String(body.msg || "").toLowerCase().includes("coding plan")) throw new Error("Z.ai account has no Coding Plan");
  const limits = body?.data?.limits ?? body?.limits;
  if (!Array.isArray(limits)) throw new Error("Z.ai returned no quota limits");
  const windows = [];
  for (const entry of limits) {
    if ((entry.type ?? entry.name) !== "TOKENS_LIMIT") continue;
    const unit = numeric(entry.unit);
    const count = numeric(entry.number);
    const perUnit = unit === 3 ? 60 : unit === 4 ? 1_440 : unit === 6 ? 10_080 : unit === 5 ? 43_200 : undefined;
    const percentage = numeric(entry.percentage);
    if (!perUnit || !(count > 0) || percentage === undefined) continue;
    windows.push({ usedPercent: clamp(percentage), windowMinutes: Math.trunc(perUnit * count), ...(timestamp(entry.nextResetTime) ? { resetsAt: timestamp(entry.nextResetTime) } : {}) });
  }
  windows.sort((left, right) => left.windowMinutes - right.windowMinutes);
  let planName;
  if (subscription) {
    const details = await fetchPayload("https://api.z.ai/api/biz/subscription/list", { headers }, { fetchImpl, timeoutMs: 10_000 }).catch(() => undefined);
    planName = clean(details?.data?.[0]?.productName);
  }
  return quota("zai", windows.slice(0, 2), { now, planName });
}

async function collectOpenRouter(secret, { fetchImpl, now }) {
  const headers = fetchHeaders(secret);
  const body = await fetchPayload("https://openrouter.ai/api/v1/credits", { headers }, { fetchImpl });
  const credits = Math.max(0, numeric(body?.data?.total_credits) ?? 0);
  const usage = Math.max(0, numeric(body?.data?.total_usage) ?? 0);
  if (!(credits > 0)) throw new Error("OpenRouter account has no prepaid credits");
  const remaining = Math.max(0, credits - usage);
  const metadata = await fetchPayload("https://openrouter.ai/api/v1/key", { headers }, { fetchImpl }).catch(() => undefined);
  const planName = typeof metadata?.data?.is_free_tier === "boolean" ? (metadata.data.is_free_tier ? "Free Tier" : "Pay As You Go") : undefined;
  const remainingBalance = { amount: remaining, currencyCode: "USD" };
  return quota("openrouter", [{ ...balanceWindow(remaining, "USD", usage / credits * 100) }], { now, planName, remainingBalance });
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

function kimiWindows(body) {
  const entries = body?.limits ?? body?.data?.limits ?? [];
  const windows = [];
  for (const entry of entries) {
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
    const windowMinutes = duration > 0 && multiplier ? Math.max(1, Math.trunc(duration * multiplier)) : 300;
    const resetsAt = resetTime(detail.resetTime ?? detail.reset_time ?? window.resetTime);
    windows.push({ usedPercent: clamp(percent), windowMinutes, ...(resetsAt ? { resetsAt } : {}) });
  }
  return windows.sort((left, right) => left.windowMinutes - right.windowMinutes).slice(0, 2);
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
  return quota("kimi", kimiWindows(body), { now });
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
  return quota("kimi", kimiWindows(body), { now });
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

async function collectMiMo(secret, { fetchImpl, now }) {
  const body = await fetchPayload("https://platform.xiaomimimo.com/api/v1/balance", {
    headers: { ...fetchHeaders(secret, "cookie"), Referer: "https://platform.xiaomimimo.com/#/console/balance" },
  }, { fetchImpl });
  const row = findNested(body, (object) => String(object.name || "").toLowerCase() === "month_total_token");
  if (!row) throw new Error("MiMo returned no monthly quota");
  const used = numeric(row.used);
  const limit = numeric(row.limit ?? row.total);
  let percent = numeric(row.percent);
  if (percent === undefined && used !== undefined && limit > 0) percent = used / limit * 100;
  if (percent === undefined) throw new Error("MiMo returned an invalid monthly quota");
  if (percent <= 1 && (used ?? 2) <= 1) percent *= 100;
  return quota("mimo", [{ usedPercent: clamp(percent), windowMinutes: 43_200 }], { now });
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
  const total = qoderSummary(payload, "totalQuota", "total_quota");
  const shared = qoderSummary(payload, "sharedQuota", "shared_quota");
  if (!total || total.total + (shared?.total || 0) <= 0) throw new Error("Qoder returned no credits quota");
  const used = total.used + (shared?.used || 0);
  const limit = total.total + (shared?.total || 0);
  return quota("qoder", [{ usedPercent: clamp(used / limit * 100), windowMinutes: 43_200 }], { now });
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
  const result = body?.Result ?? body?.result;
  const row = findNested(result, (object) => numeric(object.Percent ?? object.percent) !== undefined);
  const percent = numeric(row?.Percent ?? row?.percent);
  if (percent === undefined) throw new Error("Volcengine returned no Coding Plan quota");
  return quota("volcengine", [{ usedPercent: clamp(percent), windowMinutes: 300 }], { now, planName: "Coding Plan" });
}

async function collectOllama(secret, { fetchImpl, now }) {
  const html = await fetchPayload("https://ollama.com/settings", { headers: { Cookie: secret, Accept: "text/html,application/xhtml+xml" } }, { fetchImpl, text: true });
  if (/sign in/i.test(html) && !/usage/i.test(html)) throw new Error("Ollama Cloud Cookie was rejected");
  const windows = [];
  const pattern = /(Session usage|Hourly usage|Weekly usage)[\s\S]{0,400}?([0-9]+(?:\.[0-9]+)?)\s*%\s*used/gi;
  for (const match of html.matchAll(pattern)) {
    const label = match[1].toLowerCase();
    windows.push({ usedPercent: clamp(Number(match[2])), windowMinutes: label.startsWith("weekly") ? 10_080 : label.startsWith("hourly") ? 60 : 300 });
  }
  windows.sort((left, right) => left.windowMinutes - right.windowMinutes);
  return quota("ollama", windows.slice(0, 2), { now });
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

export async function collectManualProvider(providerID, { env = process.env, storedSecret, now = Date.now(), fetchImpl = fetch, qoderExchange } = {}) {
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
    if (secret) return collectZAI(secret, { env, now, fetchImpl });
    if (localError) throw localError;
  }
  const secret = await resolveManualSecret(providerID, { env, storedSecret });
  if (!secret) throw new Error(`${providerDefinition(providerID)?.credentialKind || "Credential"} is not configured on this PC`);
  const collector = COLLECTORS[providerID];
  if (!collector) throw new Error("Unsupported local credential provider");
  return collector(secret, { env, now, fetchImpl });
}
