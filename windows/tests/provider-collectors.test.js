import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  openCodeQuota,
  parseAntigravityUsage,
  parseCodeiumUsage,
  parseCopilotUsage,
  parseCursorUsage,
  parseGrokUsage,
  parseKiroUsage,
} from "../electron/providers/local-session.js";
import {
  collectManualProvider,
  parseKimiUsage,
  parseMiMoUsage,
  parseOllamaUsage,
  parseOpenRouterUsage,
  parseQoderUsage,
  parseVolcengineUsage,
  parseZAIUsage,
  parseZCodeBilling,
} from "../electron/providers/manual.js";

const NOW = Date.parse("2026-08-10T08:00:00Z");

function response(payload, { contentType = "application/json" } = {}) {
  return {
    ok: true,
    status: 200,
    headers: { get: (name) => name.toLowerCase() === "content-length" ? String(JSON.stringify(payload).length) : contentType },
    json: async () => payload,
    text: async () => String(payload),
  };
}

test("Automatic Windows adapters normalize their native quota shapes", () => {
  const cursor = parseCursorUsage({ enabled: true, planUsage: { totalPercentUsed: 24 }, billingCycleStart: NOW, billingCycleEnd: NOW + 30 * 86_400_000 }, { now: NOW, planName: "pro" });
  assert.equal(cursor.providerID, "cursor");
  assert.equal(cursor.windows[0].usedPercent, 24);

  const copilot = parseCopilotUsage({ quota_reset_date: "2026-09-01", copilot_plan: "pro", quota_snapshots: { premium_interactions: { entitlement: 300, remaining: 225 } } }, NOW);
  assert.equal(copilot.providerID, "copilot");
  assert.equal(copilot.windows[0].usedPercent, 25);

  for (const id of ["devin", "windsurf"]) {
    const codeium = parseCodeiumUsage(id, { userStatus: { planStatus: { planInfo: { planName: "Pro" }, dailyQuotaRemainingPercent: 72, weeklyQuotaRemainingPercent: 64 } } }, NOW);
    assert.equal(codeium.providerID, id);
    assert.deepEqual(codeium.windows.map((window) => window.usedPercent), [28, 36]);
  }

  const grok = parseGrokUsage({ config: { creditUsagePercent: 31, currentPeriod: { start: NOW, end: NOW + 7 * 86_400_000 } } }, { now: NOW, planName: "SuperGrok" });
  assert.equal(grok.providerID, "grok");
  assert.equal(grok.windows[0].windowMinutes, 10_080);

  const antigravity = parseAntigravityUsage({ groups: [{ buckets: [{ bucketId: "gemini-5h", remainingFraction: 0.65 }, { bucketId: "gemini-weekly", remainingFraction: 0.8 }, { bucketId: "3p-weekly", remainingFraction: 0.7 }] }] }, NOW);
  assert.equal(antigravity.providerID, "antigravity");
  assert.deepEqual(antigravity.windows.map((window) => Math.round(window.usedPercent)), [35, 20]);
  assert.equal(antigravity.scopedWindows[0].displayName, "Claude / Third-party");
  assert.equal(Math.round(antigravity.scopedWindows[0].window.usedPercent), 30);

  const opencode = openCodeQuota([{ ms: NOW - 60_000, cost: 3 }, { ms: NOW - 3 * 86_400_000, cost: 6 }], NOW);
  assert.equal(opencode.providerID, "opencode");
  assert.deepEqual(opencode.windows.map((window) => window.usedPercent), [25, 10]);

  const kiro = parseKiroUsage("Plan: Kiro Pro\n████░░ 40%\nresets on 2026-09-01", NOW);
  assert.equal(kiro.providerID, "kiro");
  assert.equal(kiro.windows[0].usedPercent, 40);
});

test("Cursor and Copilot split same-cycle pools with the busiest one primary", () => {
  const cursor = parseCursorUsage({
    enabled: true,
    planUsage: { autoPercentUsed: 1.93, apiPercentUsed: 91.07, totalPercentUsed: 12.7 },
    billingCycleStart: 1_782_000_000_000,
    billingCycleEnd: 1_784_592_000_000,
  }, { now: NOW, planName: "pro" });
  assert.equal(cursor.windows[0].usedPercent, 91.07);
  assert.equal(cursor.windows[0].poolName, "Other Models");
  assert.equal(cursor.scopedWindows[0].scopeID, "cursor_auto");
  assert.equal(cursor.scopedWindows[0].displayName, "Cursor Models");
  assert.equal(cursor.scopedWindows[0].window.usedPercent, 1.93);
  assert.equal(cursor.scopedWindows[0].window.windowMinutes, cursor.windows[0].windowMinutes);
  assert.equal(cursor.scopedWindows[0].observedAt, NOW);

  const loneCursor = parseCursorUsage({ enabled: true, planUsage: { autoPercentUsed: 30, totalPercentUsed: 12 } }, { now: NOW });
  assert.equal(loneCursor.windows[0].usedPercent, 30);
  assert.equal(loneCursor.windows[0].poolName, "Cursor Models");
  assert.equal(loneCursor.scopedWindows, undefined);

  const copilot = parseCopilotUsage({
    copilot_plan: "free",
    quota_reset_date: "2026-09-01",
    quota_snapshots: {
      chat: { entitlement: 50, remaining: 10 },
      completions: { entitlement: 2000, remaining: 1500 },
    },
  }, NOW);
  assert.equal(copilot.windows[0].usedPercent, 80);
  assert.equal(copilot.windows[0].poolName, "Chat");
  assert.equal(copilot.scopedWindows[0].scopeID, "copilot_completions");
  assert.equal(copilot.scopedWindows[0].displayName, "Completions");
  assert.equal(copilot.scopedWindows[0].window.usedPercent, 25);
  assert.equal(copilot.scopedWindows[0].window.resetsAt, copilot.windows[0].resetsAt);
});

test("Copilot paid overage count becomes estimated extra usage", () => {
  const quota = parseCopilotUsage({
    copilot_plan: "copilot_pro",
    quota_snapshots: {
      premium_interactions: {
        entitlement: 300,
        remaining: 0,
        overage_permitted: true,
        overage_count: 25,
      },
    },
  }, NOW);
  assert.deepEqual(quota.extraUsage, { spentUSD: 1 });
  assert.equal(parseCopilotUsage({
    quota_snapshots: { premium_interactions: { entitlement: 300, remaining: 30, overage_permitted: false, overage_count: 3 } },
  }, NOW).extraUsage, undefined);
});

test("Qoder and ZCode keep every independent billing-cycle pool", () => {
  const qoder = parseQoderUsage({
    totalQuota: { quotaSummary: { usedValue: 100, limitValue: 100 } },
    sharedQuota: { quotaSummary: { usedValue: 0, limitValue: 1000 } },
  }, NOW);
  assert.equal(qoder.windows[0].usedPercent, 100);
  assert.equal(qoder.windows[0].poolName, "Personal");
  assert.equal(qoder.scopedWindows[0].scopeID, "qoder_shared");
  assert.equal(qoder.scopedWindows[0].displayName, "Shared");
  assert.equal(qoder.scopedWindows[0].window.usedPercent, 0);

  const zcode = parseZCodeBilling({ code: 0, data: { balances: [
    { show_name: "GLM-5-Turbo", plan_id: "zcode-v3-pro-plan", total_units: 50, used_units: 10, period_end: 1_800_600_000 },
    { show_name: "GLM-5.2", plan_id: "zcode-v3-max-plan", total_units: 200, used_units: 150, period_end: 1_800_700_000 },
    { show_name: "GLM-5V", plan_id: "zcode-v3-pro-plan", total_units: 100, used_units: 5 },
  ] } }, NOW);
  assert.equal(zcode.windows[0].usedPercent, 75);
  assert.equal(zcode.windows[0].poolName, "GLM-5.2");
  assert.equal(zcode.windows[0].windowMinutes, 43_200);
  assert.equal(zcode.windows[0].resetsAt, 1_800_700_000_000);
  assert.equal(zcode.planName, "ZCode Max");
  assert.deepEqual(zcode.scopedWindows.map((scope) => scope.scopeID), ["zcode_glm_5_turbo", "zcode_glm_5v"]);
  assert.deepEqual(zcode.scopedWindows.map((scope) => scope.window.usedPercent), [20, 5]);
});

test("Kimi, Z.ai, and Ollama retain middle and sibling dimensions", () => {
  const kimi = parseKimiUsage({ limits: [
    { detail: { percent: 55 }, window: { duration: 1, timeUnit: "TIME_UNIT_WEEK" } },
    { name: "Daily quota", detail: { used: 90, limit: 100 }, window: { duration: 1, timeUnit: "TIME_UNIT_DAY" } },
    { name: "Idle pool", detail: { used: 10, limit: 100 }, window: { duration: 300, timeUnit: "TIME_UNIT_MINUTE" } },
    { name: "Busy pool", detail: { used: 70, limit: 100 }, window: { duration: 300, timeUnit: "TIME_UNIT_MINUTE" } },
  ] }, NOW);
  assert.deepEqual(kimi.windows.map((window) => window.windowMinutes), [300, 10_080]);
  assert.equal(kimi.windows[0].usedPercent, 70);
  assert.equal(kimi.windows[0].poolName, "Busy pool");
  assert.deepEqual(kimi.scopedWindows.map((scope) => scope.displayName), ["Idle pool", "Daily quota"]);
  assert.deepEqual(kimi.scopedWindows.map((scope) => scope.window.windowMinutes), [300, 1_440]);

  const zai = parseZAIUsage({ data: { limits: [
    { type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 10, name: "GLM-5" },
    { type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 60, name: "GLM-5-Air" },
    { type: "TOKENS_LIMIT", unit: 1, number: 1, percentage: 50 },
    { type: "TOKENS_LIMIT", unit: 6, number: 1, percentage: 30 },
    { type: "TIME_LIMIT", unit: 3, number: 1, name: "Web Search", percentage: 5 },
  ] } }, { now: NOW });
  assert.deepEqual(zai.windows.map((window) => window.windowMinutes), [300, 10_080]);
  assert.equal(zai.windows[0].poolName, "GLM-5-Air");
  assert.deepEqual(zai.scopedWindows.map((scope) => scope.window.windowMinutes), [60, 300, 1_440]);
  assert.deepEqual(zai.scopedWindows.map((scope) => scope.displayName), ["Web Search", "GLM-5", "Daily"]);

  for (const html of [
    "<div>Hourly usage</div><div>80% used</div><div>Session usage</div><div>12.5% used</div><div>Weekly usage</div><div>40% used</div>",
    "<div>Session usage</div><div>12.5% used</div><div>Weekly usage</div><div>40% used</div><div>Hourly usage</div><div>80% used</div>",
  ]) {
    const ollama = parseOllamaUsage(html, NOW);
    assert.deepEqual(ollama.windows.map((window) => window.windowMinutes), [300, 10_080]);
    assert.equal(ollama.scopedWindows[0].scopeID, "ollama_hourly");
    assert.equal(ollama.scopedWindows[0].window.usedPercent, 80);
  }
});

test("MiMo daily, OpenRouter lifetime credits, and Volcengine deterministic paths are retained", () => {
  const mimo = parseMiMoUsage({ data: {
    balance: 0,
    currency: "CNY",
    monthUsage: { items: [
      { name: "day_token", used: 95, limit: 100 },
      { name: "month_total_token", used: 850, limit: 1000 },
    ] },
  } }, NOW);
  assert.equal(mimo.windows[0].usedPercent, 85);
  assert.equal(mimo.windows.length, 1);
  assert.deepEqual(mimo.accountBalance, { amount: 0, currencyCode: "CNY" });
  assert.equal(mimo.scopedWindows[0].scopeID, "mimo_daily");
  assert.equal(mimo.scopedWindows[0].window.usedPercent, 95);
  assert.ok(mimo.scopedWindows[0].window.resetsAt > NOW);
  assert.ok(mimo.scopedWindows[0].window.resetsAt - NOW <= 86_400_000);

  const openrouter = parseOpenRouterUsage(
    { data: { total_credits: 20, total_usage: 5 } },
    { data: { limit: 10, usage: 2, is_free_tier: false } },
    NOW,
  );
  assert.equal(openrouter.windows.length, 1);
  assert.equal(openrouter.windows[0].usedPercent, 20);
  assert.equal(openrouter.scopedWindows[0].scopeID, "openrouter_credits");
  assert.equal(openrouter.scopedWindows[0].window.usedPercent, 25);
  assert.deepEqual(openrouter.scopedWindows[0].window.remainingBalance, { amount: 15, currencyCode: "USD" });

  assert.equal(parseVolcengineUsage({ Result: { alpha: { Percent: 12 }, user_limit: { Percent: 66 } } }, NOW).windows[0].usedPercent, 66);
  for (let index = 0; index < 8; index += 1) {
    assert.equal(parseVolcengineUsage({ Result: { zebra_pool: { Percent: 90 }, alpha_pool: { Percent: 10 } } }, NOW).windows[0].usedPercent, 10);
  }
});

test("All local-credential adapters parse provider responses without Mac Sync", async () => {
  const fetchImpl = async (input) => {
    const url = String(input);
    if (url.includes("z.ai/api/monitor")) return response({ data: { limits: [{ type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 22, nextResetTime: NOW + 60_000 }] } });
    if (url.includes("z.ai/api/biz/subscription")) return response({ data: [{ productName: "Coding Pro" }] });
    if (url.endsWith("/credits")) return response({ data: { total_credits: 100, total_usage: 12 } });
    if (url.endsWith("/key")) return response({ data: { is_free_tier: false } });
    if (url.includes("deepseek.com/user/balance")) return response({ is_available: true, balance_infos: [{ total_balance: "18.5", currency: "USD" }] });
    if (url.includes("api.kimi.com/coding/v1/usages")) return response({ limits: [{ detail: { used: 2, limit: 10 }, window: { duration: 5, timeUnit: "HOUR" } }] });
    if (url.includes("coding_plan/remains")) return response({ data: { model_remains: [{ model_name: "general", current_interval_remaining_percent: 75, current_weekly_remaining_percent: 60 }] } });
    if (url.includes("xiaomimimo.com/api/v1/balance")) return response({ data: { quota: { name: "month_total_token", used: 30, limit: 100 } } });
    if (url.includes("qoder.com/api")) return response({ data: { totalQuota: { quotaSummary: { usedValue: 20, limitValue: 100 } }, sharedQuota: { quotaSummary: { usedValue: 5, limitValue: 50 } } } });
    if (url.includes("open.volcengineapi.com")) return response({ Result: { Usage: { Percent: 33 } } });
    if (url.includes("ollama.com/settings")) return response("<div>Session usage 12% used</div><div>Weekly usage 26% used</div>", { contentType: "text/html" });
    throw new Error(`Unexpected URL: ${url}`);
  };

  const credentials = {
    zai: "zai-key",
    openrouter: "openrouter-key",
    deepseek: "deepseek-key",
    kimi: "kimi-key",
    minimax: "minimax-key",
    mimo: "mimo-cookie",
    qoder: "qoder-cookie",
    volcengine: "AKID:SECRET",
    ollama: "ollama-cookie",
  };
  for (const [providerID, storedSecret] of Object.entries(credentials)) {
    const quota = await collectManualProvider(providerID, { storedSecret, env: { USERPROFILE: "/nonexistent" }, now: NOW, fetchImpl });
    assert.equal(quota.providerID, providerID);
    assert.ok(quota.windows.length > 0, `${providerID} should expose a local quota window`);
    assert.ok(quota.windows.every((window) => Number.isFinite(window.usedPercent)));
  }
});

test("Qoder, Kimi, and Z.ai prefer app-owned Windows sessions before manual fallback", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-local-sessions-"));
  try {
    const qoderRoot = join(directory, "Qoder");
    await mkdir(join(qoderRoot, "SharedClientCache"), { recursive: true });
    await writeFile(join(qoderRoot, "SharedClientCache", ".info.json"), JSON.stringify({ ipcServerPath: "\\\\.\\pipe\\qoder-test" }));
    const qoder = await collectManualProvider("qoder", {
      env: { USERPROFILE: directory, QODER_HOME: qoderRoot },
      now: NOW,
      qoderExchange: async (socketPath, method) => {
        assert.equal(socketPath, "\\\\.\\pipe\\qoder-test");
        assert.equal(method, "credit/usage");
        return { userQuota: { used: 30, total: 100, remaining: 70 }, userType: "Pro", expiresAt: "2026-09-01T00:00:00Z" };
      },
      fetchImpl: async () => { throw new Error("Qoder should not use Cookie fallback"); },
    });
    assert.equal(qoder.windows[0].usedPercent, 30);

    const kimiRoot = join(directory, "kimi");
    await mkdir(join(kimiRoot, "credentials"), { recursive: true });
    await writeFile(join(kimiRoot, "credentials", "kimi-code.json"), JSON.stringify({ access_token: "cli-owned-token", expires_at: NOW / 1000 + 3_600 }));
    await writeFile(join(kimiRoot, "device_id"), "existing-device-id\n");
    const kimi = await collectManualProvider("kimi", {
      env: { USERPROFILE: directory, KIMI_CODE_HOME: kimiRoot },
      now: NOW,
      fetchImpl: async (_url, options) => {
        assert.equal(options.headers.Authorization, "Bearer cli-owned-token");
        assert.equal(options.headers["X-Msh-Platform"], "kimi_code_cli");
        assert.equal(options.headers["X-Msh-Device-Id"], "existing-device-id");
        return response({ limits: [{ detail: { used: 4, limit: 10 }, window: { duration: 5, timeUnit: "HOUR" } }] });
      },
    });
    assert.equal(kimi.windows[0].usedPercent, 40);

    const zcodeRoot = join(directory, "zcode");
    await mkdir(join(zcodeRoot, "v2"), { recursive: true });
    await writeFile(join(zcodeRoot, "v2", "config.json"), JSON.stringify({ provider: { "builtin:zai-coding-plan": { options: { apiKey: "zcode-owned-key" } } } }));
    const zai = await collectManualProvider("zai", {
      env: { USERPROFILE: directory, ZCODE_HOME: zcodeRoot, USERNAME: "tester" },
      now: NOW,
      fetchImpl: async (url, options) => {
        assert.match(String(url), /api\.z\.ai\/api\/monitor/);
        assert.equal(options.headers.Authorization, "zcode-owned-key");
        return response({ data: { level: "pro", limits: [{ type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 19 }] } });
      },
    });
    assert.equal(zai.windows[0].usedPercent, 19);
    assert.equal(zai.planName, "ZCode Pro");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
