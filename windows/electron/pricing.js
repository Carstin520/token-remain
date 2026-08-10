import { mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const PUBLIC_PRICING_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";
export const PRICING_REFRESH_INTERVAL_MS = 6 * 60 * 60 * 1000;
export const PRICING_RETRY_INTERVAL_MS = 60 * 60 * 1000;
export const MAXIMUM_PRICING_BYTES = 8 * 1024 * 1024;
export const MINIMUM_VALID_PRICE_COUNT = 100;

const CACHE_SCHEMA_VERSION = 1;
const MAXIMUM_PRICE_COUNT = 20_000;
const MAXIMUM_MODEL_NAME_LENGTH = 512;
const MAXIMUM_USER_CONFIGURATION_BYTES = 1024 * 1024;

export class PublicPricingService {
  constructor({ cacheDirectory, fetchImpl, environment = process.env, homeDirectory = homedir() }) {
    this.cacheDirectory = cacheDirectory;
    this.fetchImpl = fetchImpl;
    this.environment = environment;
    this.homeDirectory = homeDirectory;
    this.cachePath = join(cacheDirectory, "ccusage-public-pricing-v1.json");
    this.attemptPath = join(cacheDirectory, "ccusage-pricing-attempt-v1.json");
    this.runtimeConfigPath = join(cacheDirectory, "ccusage-runtime-config-v1.json");
    this.loaded = false;
    this.cache = undefined;
    this.lastAttemptAt = undefined;
    this.lastError = undefined;
    this.refreshPromise = undefined;
  }

  async configurationPath(now = Date.now()) {
    await this.load();
    await this.refreshIfNeeded(now);
    if (!this.cache) return undefined;
    const userConfiguration = await discoverUserConfiguration({
      environment: this.environment,
      homeDirectory: this.homeDirectory,
    });
    const runtime = mergeRuntimeConfiguration(this.cache.pricingOverrides, userConfiguration);
    await writeIfChanged(this.runtimeConfigPath, JSON.stringify(runtime));
    return this.runtimeConfigPath;
  }

  getStatus() {
    return {
      source: PUBLIC_PRICING_URL,
      capturedAt: this.cache?.fetchedAt,
      modelCount: this.cache ? Object.keys(this.cache.pricingOverrides).length : 0,
      refreshIntervalHours: PRICING_REFRESH_INTERVAL_MS / 3_600_000,
      fallback: this.cache ? "cached-public-table" : "ccusage-embedded-table",
      error: this.lastError,
    };
  }

  async load() {
    if (this.loaded) return;
    this.loaded = true;
    const attempt = await readBoundedJSON(this.attemptPath, 1024);
    if (Number.isFinite(attempt?.attemptedAt)) this.lastAttemptAt = attempt.attemptedAt;
    const cached = await readBoundedJSON(this.cachePath, MAXIMUM_PRICING_BYTES);
    if (isValidStoredPricing(cached)) this.cache = cached;
  }

  async refreshIfNeeded(now) {
    if (this.cache && isFresh(this.cache.fetchedAt, now)) return;
    if (Number.isFinite(this.lastAttemptAt) && now >= this.lastAttemptAt && now - this.lastAttemptAt < PRICING_RETRY_INTERVAL_MS) return;
    if (!this.refreshPromise) {
      this.refreshPromise = this.refresh(now).finally(() => { this.refreshPromise = undefined; });
    }
    await this.refreshPromise;
  }

  async refresh(now) {
    try {
      await writeIfChanged(this.attemptPath, JSON.stringify({ attemptedAt: now }));
      this.lastAttemptAt = now;
    } catch (error) {
      this.lastError = publicError(error);
      return;
    }

    try {
      const headers = { Accept: "application/json", "User-Agent": "TokenRemain public-pricing-refresh" };
      if (this.cache?.eTag) headers["If-None-Match"] = this.cache.eTag;
      if (this.cache?.lastModified) headers["If-Modified-Since"] = this.cache.lastModified;
      const response = await this.fetchImpl(PUBLIC_PRICING_URL, { method: "GET", headers });
      validatePricingResponse(response);

      if (response.status === 304) {
        if (!this.cache) throw new Error("Pricing server returned 304 without a local cache");
        this.cache = {
          ...this.cache,
          fetchedAt: now,
          eTag: response.headers?.get?.("etag") || this.cache.eTag,
          lastModified: response.headers?.get?.("last-modified") || this.cache.lastModified,
        };
      } else {
        const declaredLength = Number(response.headers?.get?.("content-length"));
        if (Number.isFinite(declaredLength) && declaredLength > MAXIMUM_PRICING_BYTES) throw new Error("Public pricing table is too large");
        const data = Buffer.from(await response.arrayBuffer());
        if (data.length > MAXIMUM_PRICING_BYTES) throw new Error("Public pricing table is too large");
        const pricingOverrides = parsePublicPricing(data);
        if (!isValidPricingSet(pricingOverrides)) throw new Error("Public pricing table failed validation");
        this.cache = {
          schemaVersion: CACHE_SCHEMA_VERSION,
          fetchedAt: now,
          eTag: response.headers?.get?.("etag") || undefined,
          lastModified: response.headers?.get?.("last-modified") || undefined,
          pricingOverrides,
        };
      }
      await writeIfChanged(this.cachePath, JSON.stringify(this.cache));
      this.lastError = undefined;
    } catch (error) {
      // Local usage stays available with the last validated table, or with
      // ccusage's embedded table on a first-run offline PC.
      this.lastError = publicError(error);
    }
  }
}

export function parsePublicPricing(input) {
  const raw = JSON.parse(Buffer.isBuffer(input) ? input.toString("utf8") : String(input));
  if (!raw || Array.isArray(raw) || typeof raw !== "object") throw new Error("Invalid public pricing table");
  const entries = Object.entries(raw);
  if (entries.length > MAXIMUM_PRICE_COUNT) throw new Error("Public pricing table has too many rows");
  const result = {};
  for (const [model, value] of entries) {
    if (!isValidModelName(model) || !value || Array.isArray(value) || typeof value !== "object") continue;
    const price = {
      inputCostPerToken: value.input_cost_per_token,
      outputCostPerToken: value.output_cost_per_token,
      cacheCreationInputTokenCost: optionalCost(value.cache_creation_input_token_cost),
      cacheReadInputTokenCost: optionalCost(value.cache_read_input_token_cost),
      inputCostPerTokenAbove200kTokens: optionalCost(value.input_cost_per_token_above_200k_tokens),
      outputCostPerTokenAbove200kTokens: optionalCost(value.output_cost_per_token_above_200k_tokens),
      cacheCreationInputTokenCostAbove200kTokens: optionalCost(value.cache_creation_input_token_cost_above_200k_tokens),
      cacheReadInputTokenCostAbove200kTokens: optionalCost(value.cache_read_input_token_cost_above_200k_tokens),
      maxInputTokens: optionalInteger(value.max_input_tokens, 1, 100_000_000),
      fastMultiplier: optionalCost(value.provider_specific_entry?.fast, 100),
    };
    if (isValidPrice(price)) result[model] = withoutUndefined(price);
  }
  return result;
}

export function mergeRuntimeConfiguration(pricingOverrides, userConfiguration) {
  const root = userConfiguration && !Array.isArray(userConfiguration) && typeof userConfiguration === "object"
    ? structuredClone(userConfiguration)
    : {};
  const expanded = expandPricingOverrides(pricingOverrides);
  const defaults = root.defaults && !Array.isArray(root.defaults) && typeof root.defaults === "object"
    ? { ...root.defaults }
    : {};
  const userOverrides = defaults.pricingOverrides;
  if (userOverrides && !Array.isArray(userOverrides) && typeof userOverrides === "object") {
    for (const [model, userValue] of Object.entries(userOverrides)) {
      expanded[model] = expanded[model] && userValue && !Array.isArray(userValue) && typeof userValue === "object"
        ? { ...expanded[model], ...userValue }
        : userValue;
    }
  }
  if (defaults.mode === undefined) defaults.mode = "calculate";
  defaults.pricingOverrides = expanded;
  return {
    ...root,
    $schema: root.$schema || "https://ccusage.com/config-schema.json",
    defaults,
  };
}

export function isFresh(fetchedAt, now = Date.now()) {
  return Number.isFinite(fetchedAt) && now >= fetchedAt - 5 * 60_000 && now - fetchedAt < PRICING_REFRESH_INTERVAL_MS;
}

function expandPricingOverrides(pricingOverrides) {
  const expanded = structuredClone(pricingOverrides || {});
  for (const [model, price] of Object.entries(pricingOverrides || {})) {
    if (model.includes("/")) continue;
    for (const alias of modelAliases(model)) if (expanded[alias] === undefined) expanded[alias] = price;
  }
  return expanded;
}

function modelAliases(model) {
  const parts = normalizeModelName(model).split("-");
  if (parts.length < 4 || parts[0] !== "claude" || !["opus", "sonnet", "haiku"].includes(parts[1]) || !/^\d+$/.test(parts[2]) || !/^\d+$/.test(parts[3])) return [];
  const suffix = parts.slice(4).join("-");
  const tail = suffix ? `-${suffix}` : "";
  const version = `${parts[2]}.${parts[3]}`;
  return [
    `claude-${parts[1]}-${version}${tail}`,
    `claude-${version}-${parts[1]}${tail}`,
    `claude-${version}-${parts[1]}-thinking${tail}`,
  ];
}

function normalizeModelName(value) {
  return String(value).trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

function isValidStoredPricing(value) {
  return value?.schemaVersion === CACHE_SCHEMA_VERSION
    && Number.isFinite(value.fetchedAt)
    && isValidPricingSet(value.pricingOverrides);
}

function isValidPricingSet(values) {
  if (!values || Array.isArray(values) || typeof values !== "object") return false;
  const keys = Object.keys(values);
  return keys.length >= MINIMUM_VALID_PRICE_COUNT
    && keys.length <= MAXIMUM_PRICE_COUNT
    && keys.some((key) => key.startsWith("claude-") && isValidPrice(values[key]))
    && keys.some((key) => key.startsWith("gpt-") && isValidPrice(values[key]));
}

function isValidPrice(value) {
  return value
    && validCost(value.inputCostPerToken)
    && validCost(value.outputCostPerToken)
    && [
      value.cacheCreationInputTokenCost,
      value.cacheReadInputTokenCost,
      value.inputCostPerTokenAbove200kTokens,
      value.outputCostPerTokenAbove200kTokens,
      value.cacheCreationInputTokenCostAbove200kTokens,
      value.cacheReadInputTokenCostAbove200kTokens,
    ].every((item) => item === undefined || validCost(item))
    && (value.maxInputTokens === undefined || Number.isInteger(value.maxInputTokens))
    && (value.fastMultiplier === undefined || validCost(value.fastMultiplier, 100));
}

function validCost(value, maximum = 1) {
  return Number.isFinite(value) && value >= 0 && value <= maximum;
}

function optionalCost(value, maximum = 1) {
  return validCost(value, maximum) ? value : undefined;
}

function optionalInteger(value, minimum, maximum) {
  return Number.isInteger(value) && value >= minimum && value <= maximum ? value : undefined;
}

function isValidModelName(value) {
  return typeof value === "string" && value.length > 0 && value.length <= MAXIMUM_MODEL_NAME_LENGTH && !/[\u0000-\u001f\u007f]/.test(value);
}

function validatePricingResponse(response) {
  if (response?.status !== 200 && response?.status !== 304) throw new Error(`Public pricing refresh returned HTTP ${response?.status || "unknown"}`);
  const finalURL = new URL(response.url || PUBLIC_PRICING_URL);
  const expected = new URL(PUBLIC_PRICING_URL);
  if (finalURL.protocol !== "https:" || finalURL.host !== expected.host || finalURL.pathname !== expected.pathname) {
    throw new Error("Public pricing response came from an unexpected source");
  }
}

async function discoverUserConfiguration({ environment, homeDirectory }) {
  const candidates = [];
  if (environment.CLAUDE_CONFIG_DIR) {
    for (const directory of environment.CLAUDE_CONFIG_DIR.split(",").map((value) => value.trim()).filter(Boolean)) {
      candidates.push(join(directory, "ccusage.json"));
    }
  } else {
    candidates.push(join(homeDirectory, ".config", "claude", "ccusage.json"));
    candidates.push(join(homeDirectory, ".claude", "ccusage.json"));
  }
  for (const candidate of candidates) {
    const value = await readBoundedJSON(candidate, MAXIMUM_USER_CONFIGURATION_BYTES);
    if (value && !Array.isArray(value) && typeof value === "object") return value;
  }
  return undefined;
}

async function readBoundedJSON(path, maximumBytes) {
  try {
    const metadata = await stat(path);
    if (!metadata.isFile() || metadata.size > maximumBytes) return undefined;
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    return undefined;
  }
}

async function writeIfChanged(path, contents) {
  const data = Buffer.from(contents, "utf8");
  try {
    const existing = await readFile(path);
    if (existing.equals(data)) return;
  } catch {}
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.next`;
  await writeFile(temporary, data, { mode: 0o600 });
  await rename(temporary, path);
}

function withoutUndefined(value) {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined));
}

function publicError(error) {
  return (error instanceof Error ? error.message : String(error)).replace(/[\r\n\t]+/g, " ").slice(0, 240);
}
