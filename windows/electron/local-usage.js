import { execFile } from "node:child_process";
import { join } from "node:path";
import { withLegacyFields } from "../src/usage-history.js";

export { mergeDailyUsageHistories } from "../src/usage-history.js";

const MAXIMUM_OUTPUT_BYTES = 8 * 1024 * 1024;
const MAXIMUM_DAYS = 30;
const MAXIMUM_AGENTS_PER_DAY = 32;
const MAXIMUM_TOKENS = 1_000_000_000_000_000;
const MAXIMUM_COST = 1_000_000;

export function ccusageBinaryPath({
  platform = process.platform,
  arch = process.arch,
  packaged = false,
  appPath,
  resourcesPath = process.resourcesPath,
}) {
  if (!["win32", "darwin", "linux"].includes(platform) || !["x64", "arm64"].includes(arch)) {
    throw new Error(`ccusage is not available for ${platform}-${arch}`);
  }
  const suffix = platform === "win32" ? ".exe" : "";
  const packageName = `ccusage-${platform}-${arch}`;
  const root = packaged
    ? join(resourcesPath, "app.asar.unpacked", "node_modules", "@ccusage", packageName)
    : join(appPath, "node_modules", "@ccusage", packageName);
  return join(root, "bin", `ccusage${suffix}`);
}

export function ccusageArguments({ since, timezone, pricingConfigurationPath }) {
  const args = ["daily", "--json", "--by-agent", "--offline", "--no-color", "--timezone", timezone, "--since", since];
  if (pricingConfigurationPath) args.push("--config", pricingConfigurationPath);
  return args;
}

export async function collectLocalUsage({
  binaryPath,
  pricingConfigurationPath,
  now = Date.now(),
  timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
  execFileImpl = execute,
}) {
  const since = localDayKey(shiftLocalDays(now, -(MAXIMUM_DAYS - 1)));
  const stdout = await execFileImpl(binaryPath, ccusageArguments({ since, timezone, pricingConfigurationPath }));
  return parseCCUsageSnapshot(stdout, now);
}

export function parseCCUsageSnapshot(input, now = Date.now()) {
  const payload = JSON.parse(Buffer.isBuffer(input) ? input.toString("utf8") : String(input));
  if (!payload || !Array.isArray(payload.daily)) throw new Error("ccusage returned an invalid daily report");
  const minimumDay = localDayKey(shiftLocalDays(now, -(MAXIMUM_DAYS - 1)));
  const maximumDay = localDayKey(now);
  const byDay = new Map();
  for (const row of payload.daily) {
    if (!validDayKey(row?.period) || row.period < minimumDay || row.period > maximumDay || !Array.isArray(row.agents)) continue;
    const agents = row.agents.slice(0, MAXIMUM_AGENTS_PER_DAY).flatMap(normalizeAgent);
    byDay.set(row.period, makeDay(row.period, agents));
  }
  const days = [...byDay.values()].sort((left, right) => left.day.localeCompare(right.day)).slice(-MAXIMUM_DAYS);
  return {
    sourceDay: localDayKey(now),
    capturedAt: now,
    days,
  };
}

function normalizeAgent(agent) {
  const id = normalizeAgentID(agent?.agent);
  const tokens = boundedInteger(agent?.totalTokens, MAXIMUM_TOKENS);
  const cost = boundedNumber(agent?.totalCost, MAXIMUM_COST);
  if (!id || (tokens === 0 && cost === 0)) return [];
  const modelRows = Array.isArray(agent.modelBreakdowns) ? agent.modelBreakdowns : [];
  let unpricedModels = modelRows.flatMap((row) => {
    const modelTokens = [row?.inputTokens, row?.outputTokens, row?.cacheCreationTokens, row?.cacheReadTokens]
      .reduce((total, value) => total + boundedInteger(value, MAXIMUM_TOKENS), 0);
    const name = validModelName(row?.modelName) ? row.modelName : undefined;
    return modelTokens > 0 && boundedNumber(row?.cost, MAXIMUM_COST) === 0 && name && name !== "<synthetic>" ? [name] : [];
  });
  if (!unpricedModels.length && tokens > 0 && cost === 0 && !modelRows.length && Array.isArray(agent.modelsUsed)) {
    unpricedModels = agent.modelsUsed.filter(validModelName);
  }
  return [{ id, tokens, cost, unpricedModels: [...new Set(unpricedModels)].sort() }];
}

function normalizeStoredAgent(agent) {
  const id = normalizeAgentID(agent?.id);
  const tokens = boundedInteger(agent?.tokens, MAXIMUM_TOKENS);
  const cost = boundedNumber(agent?.cost, MAXIMUM_COST);
  if (!id || (tokens === 0 && cost === 0)) return [];
  const unpricedModels = Array.isArray(agent.unpricedModels) ? agent.unpricedModels.filter(validModelName).slice(0, 32) : [];
  return [{ id, tokens, cost, unpricedModels }];
}

function makeDay(day, agents) {
  const normalizedAgents = agents.flatMap(normalizeStoredAgent).sort((left, right) => right.tokens - left.tokens || left.id.localeCompare(right.id));
  return withLegacyFields(day, normalizedAgents);
}

function execute(path, args) {
  return new Promise((resolve, reject) => {
    execFile(path, args, {
      windowsHide: true,
      timeout: 30_000,
      maxBuffer: MAXIMUM_OUTPUT_BYTES,
      encoding: "utf8",
      env: { ...process.env, NO_COLOR: "1" },
    }, (error, stdout, stderr) => {
      if (error) {
        const detail = String(stderr || error.message).replace(/[\r\n\t]+/g, " ").trim().slice(0, 240);
        reject(new Error(error.killed ? "Local ccusage scan timed out" : `Local ccusage scan failed: ${detail}`));
        return;
      }
      resolve(stdout);
    });
  });
}

function normalizeAgentID(value) {
  const result = String(value || "").trim().toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-|-$/g, "");
  return /^[a-z0-9][a-z0-9._-]{0,63}$/.test(result) ? result : undefined;
}

function validModelName(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 512 && !/[\u0000-\u001f\u007f]/.test(value);
}

function boundedInteger(value, maximum) {
  return Number.isSafeInteger(value) && value >= 0 ? Math.min(value, maximum) : 0;
}

function boundedNumber(value, maximum) {
  return Number.isFinite(value) && value >= 0 ? Math.min(value, maximum) : 0;
}

function validDayKey(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = Date.parse(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed) && new Date(parsed).toISOString().slice(0, 10) === value;
}

function localDayKey(value) {
  const date = new Date(value);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function shiftLocalDays(value, offset) {
  const date = new Date(value);
  date.setDate(date.getDate() + offset);
  return date.getTime();
}
