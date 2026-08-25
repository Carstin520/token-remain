import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";
import {
  ccusageArguments,
  ccusageBinaryPath,
  collectLocalUsage,
  aggregateLocalUsageHistories,
  mergeDailyUsageHistories,
  parseCCUsageSnapshot,
} from "../electron/local-usage.js";
import { usageDayTotals, usageProviderIDs } from "../src/usage-history.js";
import { buildTodayUsage } from "../src/overview-model.js";
import { buildUsageDigest } from "../src/popover-model.js";
import { usageTrendModel } from "../src/trends-model.js";

const NOW = new Date(2026, 7, 10, 12, 0, 0).getTime();

function report() {
  return JSON.stringify({ daily: [{
    period: "2026-08-10",
    agents: [
      { agent: "claude", totalTokens: 300, totalCost: 1.5 },
      { agent: "codex", totalTokens: 100, totalCost: 0.5 },
      { agent: "gemini", totalTokens: 40, totalCost: 0.1 },
      {
        agent: "openclaw",
        totalTokens: 50,
        totalCost: 0,
        modelsUsed: ["new-model"],
        modelBreakdowns: [{
          modelName: "new-model",
          cost: 0,
          inputTokens: 25,
          outputTokens: 25,
          cacheCreationTokens: 0,
          cacheReadTokens: 0,
        }],
      },
    ],
  }] });
}

test("Windows ccusage parser keeps every local agent and marks missing prices", () => {
  const history = parseCCUsageSnapshot(report(), NOW);
  assert.equal(history.sourceDay, "2026-08-10");
  assert.deepEqual(history.days[0].agents.map((agent) => agent.id), ["claude", "codex", "openclaw", "gemini"]);
  assert.equal(history.days[0].claudeTokens, 300);
  assert.equal(history.days[0].codexTokens, 100);
  assert.deepEqual(history.days[0].agents.find((agent) => agent.id === "openclaw").unpricedModels, ["new-model"]);
  assert.deepEqual(history.days[0].agents.find((agent) => agent.id === "openclaw").models, [{
    id: "new-model",
    inputTokens: 25,
    outputTokens: 25,
    cacheTokens: 0,
    cost: 0,
    constituentCount: 1,
  }]);
  assert.equal(usageDayTotals(history.days[0]).tokens, 490);
  assert.equal(usageDayTotals(history.days[0]).cost, undefined);
  assert.deepEqual(usageProviderIDs(history), ["claude", "codex", "openclaw", "gemini"]);
});

test("retained model history is capped at seven named rows plus one other rollup", () => {
  const models = Array.from({ length: 10 }, (_, index) => ({
    modelName: `model-${index + 1}`,
    cost: index + 1,
    inputTokens: (10 - index) * 100,
    outputTokens: (10 - index) * 10,
    cacheCreationTokens: index,
    cacheReadTokens: index * 2,
  }));
  const history = parseCCUsageSnapshot(JSON.stringify({ daily: [{
    period: "2026-08-10",
    agents: [{ agent: "codex", totalTokens: 6_160, totalCost: 55, modelBreakdowns: models }],
  }] }), NOW);
  const retained = history.days[0].agents[0].models;
  assert.equal(retained.length, 8);
  assert.deepEqual(retained.slice(0, 7).map((model) => model.id), [
    "model-1", "model-2", "model-3", "model-4", "model-5", "model-6", "model-7",
  ]);
  assert.deepEqual(retained[7], {
    id: "other",
    inputTokens: 600,
    outputTokens: 60,
    cacheTokens: 72,
    cost: 27,
    constituentCount: 3,
  });
});

test("Local ccusage invocation is offline and receives the app-owned price table", async () => {
  let invocation;
  const history = await collectLocalUsage({
    binaryPath: "C:\\TokenRemain\\ccusage.exe",
    pricingConfigurationPath: "C:\\TokenRemain\\pricing.json",
    timezone: "Asia/Shanghai",
    now: NOW,
    execFileImpl: async (path, args) => {
      invocation = { path, args };
      return report();
    },
  });
  assert.equal(history.days.length, 1);
  assert.equal(invocation.path, "C:\\TokenRemain\\ccusage.exe");
  assert.deepEqual(invocation.args, ccusageArguments({
    since: "2026-07-12",
    timezone: "Asia/Shanghai",
    pricingConfigurationPath: "C:\\TokenRemain\\pricing.json",
  }));
  assert.ok(invocation.args.includes("--offline"));
  assert.ok(invocation.args.includes("--by-agent"));
  assert.ok(!invocation.args.join(" ").includes("npx"));
});

test("Packaged helper resolves to the architecture-specific unpacked executable", () => {
  assert.equal(
    ccusageBinaryPath({ platform: "win32", arch: "x64", packaged: true, resourcesPath: "C:\\App\\resources" }),
    join("C:\\App\\resources", "app.asar.unpacked", "node_modules", "@ccusage", "ccusage-win32-x64", "bin", "ccusage.exe"),
  );
  assert.equal(
    ccusageBinaryPath({ platform: "win32", arch: "arm64", packaged: false, appPath: "C:\\repo\\windows" }),
    join("C:\\repo\\windows", "node_modules", "@ccusage", "ccusage-win32-arm64", "bin", "ccusage.exe"),
  );
});

test("This PC and paired Mac histories merge without dropping future agent IDs", () => {
  const local = parseCCUsageSnapshot(report(), NOW);
  const remote = {
    sourceDay: "2026-08-10",
    capturedAt: NOW - 1_000,
    days: [{ day: "2026-08-10", claudeTokens: 20, claudeCost: 0.2, codexTokens: 80, codexCost: 0.8 }],
  };
  const merged = mergeDailyUsageHistories(local, remote);
  const byID = new Map(merged.days[0].agents.map((agent) => [agent.id, agent]));
  assert.equal(byID.get("claude").tokens, 320);
  assert.equal(byID.get("codex").tokens, 180);
  assert.equal(byID.get("gemini").tokens, 40);
  assert.equal(merged.days[0].claudeTokens, 320);
  assert.equal(merged.days[0].codexTokens, 180);
});

test("disabled sources disappear from today, digests, trends, and the merged Mac-sync aggregate", () => {
  const local = {
    sourceDay: "2026-08-10",
    capturedAt: NOW,
    days: [{ day: "2026-08-10", agents: [
      { id: "claude", tokens: 300, cost: 1.5, unpricedModels: [] },
      { id: "codex", tokens: 100, cost: 0.5, unpricedModels: [] },
    ] }],
  };
  const remote = {
    sourceDay: "2026-08-10",
    capturedAt: NOW - 1_000,
    days: [{ day: "2026-08-10", claudeTokens: 20, claudeCost: 0.2, codexTokens: 80, codexCost: 0.8 }],
  };
  const visible = aggregateLocalUsageHistories(local, remote, ["codex"]);
  assert.deepEqual(visible.days[0].agents.map((agent) => agent.id), ["claude"]);
  assert.equal(visible.days[0].codexTokens, 0);
  assert.deepEqual(local.days[0].agents.map((agent) => agent.id), ["claude", "codex"]);

  const today = buildTodayUsage(visible, NOW);
  assert.equal(today.totalTokens, 320);
  assert.deepEqual(today.entries.map((entry) => entry.id), ["claude"]);

  const digest = buildUsageDigest(visible, NOW);
  assert.equal(digest.today.tokens, 320);
  assert.deepEqual(digest.entries.map((entry) => entry.id), ["claude"]);

  const trend = usageTrendModel(visible, { range: 7, metric: "tokens", providerIDs: usageProviderIDs(visible) });
  assert.deepEqual(trend.providerIDs, ["claude"]);
  assert.equal(trend.days[0].total, 320);
});
