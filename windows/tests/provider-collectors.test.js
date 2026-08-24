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
import { collectManualProvider } from "../electron/providers/manual.js";

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
