import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const HOST_ROUTE_TABLE = Object.freeze([
  { providerID: "deepseek", displayName: "DeepSeek API", ids: ["deepseek"], domains: ["deepseek.com"] },
  { providerID: "openrouter", displayName: "OpenRouter API", ids: ["openrouter"], domains: ["openrouter.ai"] },
  { providerID: "zai", displayName: "Z.ai API", ids: ["zai", "z.ai", "bigmodel", "zhipu"], domains: ["z.ai", "bigmodel.cn", "zhipuai.cn"] },
  { providerID: "kimi", displayName: "Kimi API", ids: ["kimi", "moonshot"], domains: ["kimi.com", "moonshot.cn"] },
  { providerID: "minimax", displayName: "MiniMax API", ids: ["minimax"], domains: ["minimax.io", "minimaxi.com"] },
  { providerID: "mimo", displayName: "MiMo API", ids: ["mimo", "xiaomi"], domains: ["xiaomi.com"] },
]);

// MiMo's host route token is not the console cookie its existing Windows
// balance collector requires. Known routes with compatible collectors are
// re-fetched; MiMo and generic relays retain the host reading with labeling.
export const WINDOWS_HOST_REROUTE_PROVIDER_IDS = new Set(["deepseek", "openrouter", "zai", "kimi", "minimax"]);

function environmentValue(env, name) {
  if (typeof env[name] === "string") return env[name];
  const key = Object.keys(env).find((candidate) => candidate.toLowerCase() === name.toLowerCase());
  return key ? env[key] : undefined;
}

function normalized(value) {
  const text = typeof value === "string" ? value.trim() : "";
  return text || undefined;
}

function expandPath(value, env, home) {
  const text = normalized(value);
  if (!text) return undefined;
  if (text === "~") return home;
  if (text.startsWith("~/") || text.startsWith("~\\")) return join(home, text.slice(2));
  return text.replace(/%([^%]+)%/g, (_match, name) => environmentValue(env, name) || `%${name}%`);
}

async function readSmallText(path, maximumBytes = 2 * 1024 * 1024) {
  const data = await readFile(path);
  if (data.length > maximumBytes) throw new Error("Host routing config is unexpectedly large");
  return data.toString("utf8");
}

async function readJSON(path) {
  try { return JSON.parse(await readSmallText(path)); } catch { return undefined; }
}

export function normalizedBaseURL(value) {
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname || url.username || url.password) return undefined;
    url.hash = "";
    return url;
  } catch {
    return undefined;
  }
}

function hostMatches(host, domain) {
  return host === domain || host.endsWith(`.${domain}`);
}

function officialClaudeURL(url) {
  const host = url?.hostname.toLowerCase();
  return Boolean(host && hostMatches(host, "anthropic.com"));
}

function officialCodexURL(url) {
  const host = url?.hostname.toLowerCase();
  return Boolean(host && (hostMatches(host, "openai.com") || hostMatches(host, "chatgpt.com")));
}

export function classifyHostRoute({ providerID, baseURL } = {}) {
  const url = baseURL instanceof URL ? baseURL : normalizedBaseURL(baseURL);
  const host = url?.hostname.toLowerCase() || "";
  const id = normalized(providerID)?.toLowerCase() || "";
  if (host) {
    if (hostMatches(host, "openai.com") && id.includes("openai")) {
      return { providerID: "thirdParty", displayName: "OpenAI API" };
    }
    if (hostMatches(host, "anthropic.com") && id.includes("anthropic")) {
      return { providerID: "thirdParty", displayName: "Anthropic API" };
    }
    for (const route of HOST_ROUTE_TABLE) {
      if (route.domains.some((domain) => hostMatches(host, domain))) {
        return { providerID: route.providerID, displayName: route.displayName };
      }
    }
    return { providerID: "thirdParty", displayName: host };
  }
  const known = HOST_ROUTE_TABLE.find((route) => route.ids.includes(id));
  if (known) return { providerID: known.providerID, displayName: known.displayName };
  const fallback = normalized(providerID)?.slice(0, 64);
  return { providerID: "thirdParty", displayName: fallback ? `${fallback} API` : "Third-party API" };
}

function externalRoute(hostProvider, { providerID, baseURL, credential }) {
  const classified = classifyHostRoute({ providerID, baseURL });
  const host = baseURL?.hostname.toLowerCase();
  const providerRouteKey = normalized(providerID)?.toLowerCase().slice(0, 64);
  const routeIdentifier = [
    hostProvider.toLowerCase(),
    classified.providerID.toLowerCase(),
    host || providerRouteKey || "unknown",
  ].join("|");
  return {
    hostProvider,
    external: true,
    sourceProviderID: classified.providerID,
    displayName: classified.displayName,
    routeIdentifier,
    baseURL: baseURL?.toString(),
    credential,
    attribution: { displayName: classified.displayName, routeIdentifier },
    rerouteProviderID: WINDOWS_HOST_REROUTE_PROVIDER_IDS.has(classified.providerID)
      ? classified.providerID
      : undefined,
  };
}

function officialRoute(hostProvider) {
  return { hostProvider, external: false };
}

function stripTOMLComment(line) {
  let quote;
  let escaped = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character === "\\" && quote === '"') {
      escaped = true;
      continue;
    }
    if (character === '"' || character === "'") quote = quote === undefined ? character : quote === character ? undefined : quote;
    else if (character === "#" && quote === undefined) return line.slice(0, index);
  }
  return line;
}

function tomlString(value) {
  if (value.length < 2 || !['"', "'"].includes(value[0]) || value.at(-1) !== value[0]) return undefined;
  const inner = value.slice(1, -1);
  return value[0] === "'" ? inner : inner.replace(/\\"/g, '"').replace(/\\\\/g, "\\");
}

function tomlBoolean(value) {
  if (value.trim() === "true") return true;
  if (value.trim() === "false") return false;
  return undefined;
}

export function parseCodexRoutingConfiguration(text) {
  const result = { providers: {} };
  let providerSection;
  for (const rawLine of String(text).split(/\r?\n/)) {
    const line = stripTOMLComment(rawLine).trim();
    if (!line) continue;
    if (line.startsWith("[") && line.endsWith("]")) {
      const section = line.slice(1, -1).trim();
      const prefix = "model_providers.";
      providerSection = section.startsWith(prefix)
        ? section.slice(prefix.length).trim().replace(/^["']|["']$/g, "")
        : undefined;
      continue;
    }
    const equals = line.indexOf("=");
    if (equals < 0) continue;
    const key = line.slice(0, equals).trim();
    const rawValue = line.slice(equals + 1).trim();
    if (providerSection) {
      const provider = result.providers[providerSection] || { requiresOpenAIAuth: false };
      if (key === "base_url") provider.baseURL = tomlString(rawValue) ?? provider.baseURL;
      else if (key === "env_key") provider.environmentKey = tomlString(rawValue) ?? provider.environmentKey;
      else if (key === "requires_openai_auth") provider.requiresOpenAIAuth = tomlBoolean(rawValue) ?? provider.requiresOpenAIAuth;
      result.providers[providerSection] = provider;
    } else {
      const value = tomlString(rawValue);
      if (key === "model_provider" && value !== undefined) result.modelProvider = value;
      else if (key === "openai_base_url" && value !== undefined) result.openAIBaseURL = value;
      else if (key === "preferred_auth_method" && value !== undefined) result.preferredAuthMethod = value;
    }
  }
  return result;
}

function settingsEnvironment(object) {
  if (!object?.env || typeof object.env !== "object" || Array.isArray(object.env)) return {};
  return Object.fromEntries(Object.entries(object.env).filter(([, value]) => typeof value === "string"));
}

async function claudeRoute({ env, home }) {
  const configurationDirectory = expandPath(environmentValue(env, "CLAUDE_CONFIG_DIR") || join(home, ".claude"), env, home);
  const settings = settingsEnvironment(await readJSON(join(configurationDirectory, "settings.json")));
  Object.assign(settings, settingsEnvironment(await readJSON(join(configurationDirectory, "settings.local.json"))));
  const baseText = normalized(environmentValue(env, "ANTHROPIC_BASE_URL")) ?? normalized(settings.ANTHROPIC_BASE_URL);
  const credential = normalized(environmentValue(env, "ANTHROPIC_AUTH_TOKEN"))
    ?? normalized(environmentValue(env, "ANTHROPIC_API_KEY"))
    ?? normalized(settings.ANTHROPIC_AUTH_TOKEN)
    ?? normalized(settings.ANTHROPIC_API_KEY);
  if (!baseText) {
    return credential
      ? externalRoute("claude", { providerID: "anthropic-api", baseURL: normalizedBaseURL("https://api.anthropic.com"), credential })
      : officialRoute("claude");
  }
  const baseURL = normalizedBaseURL(baseText);
  if (!baseURL) return externalRoute("claude", { providerID: "configured-relay", credential });
  if (officialClaudeURL(baseURL)) {
    return credential
      ? externalRoute("claude", { providerID: "anthropic-api", baseURL, credential })
      : officialRoute("claude");
  }
  return externalRoute("claude", { baseURL, credential });
}

function codexAuthentication(object) {
  return {
    apiKey: normalized(object?.OPENAI_API_KEY) ?? normalized(object?.api_key),
    hasChatGPTAccessToken: Boolean(normalized(object?.tokens?.access_token)),
  };
}

async function codexRoute({ env, home }) {
  const codexHome = expandPath(environmentValue(env, "CODEX_HOME") || join(home, ".codex"), env, home);
  const configuration = parseCodexRoutingConfiguration(await readSmallText(join(codexHome, "config.toml")).catch(() => ""));
  const auth = codexAuthentication(await readJSON(join(codexHome, "auth.json")));
  const providerID = normalized(configuration.modelProvider) || "openai";
  const provider = configuration.providers[providerID];
  const baseText = normalized(environmentValue(env, "OPENAI_BASE_URL"))
    ?? normalized(configuration.openAIBaseURL)
    ?? normalized(provider?.baseURL);
  const baseURL = baseText ? normalizedBaseURL(baseText) : undefined;
  const usesOpenAIAuth = providerID.toLowerCase() === "openai" || provider?.requiresOpenAIAuth === true;
  const providerEnvironmentKey = normalized(provider?.environmentKey);
  const credential = (providerEnvironmentKey ? normalized(environmentValue(env, providerEnvironmentKey)) : undefined)
    ?? (usesOpenAIAuth ? normalized(environmentValue(env, "OPENAI_API_KEY")) ?? auth.apiKey : undefined);
  const prefersAPIKey = usesOpenAIAuth && (providerEnvironmentKey !== undefined
    || configuration.preferredAuthMethod?.toLowerCase() === "apikey"
    || (credential !== undefined && !auth.hasChatGPTAccessToken));
  const hasOfficialOrUnsetBaseURL = baseText === undefined || officialCodexURL(baseURL);
  if (usesOpenAIAuth && !prefersAPIKey && hasOfficialOrUnsetBaseURL) return officialRoute("codex");
  return externalRoute("codex", {
    providerID: baseText && !baseURL ? "configured-relay" : prefersAPIKey ? "openai-api" : providerID,
    baseURL: baseURL || (!baseText && prefersAPIKey ? normalizedBaseURL("https://api.openai.com") : undefined),
    credential,
  });
}

export async function detectHostAppRoute(hostProvider, { env = process.env, home = homedir() } = {}) {
  if (hostProvider === "claude") return claudeRoute({ env, home });
  if (hostProvider === "codex") return codexRoute({ env, home });
  return officialRoute(hostProvider);
}
