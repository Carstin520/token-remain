import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { parseClaudeUsage } from "../electron/collectors/claude.js";
import {
  codexModelScopedWindows,
  codexWireScopeBase,
  collectCodex,
  parseCodexSessionSnapshots,
  parseCodexUsage,
  resolveCodexHome,
} from "../electron/collectors/codex.js";

const now = Date.UTC(2026, 7, 2, 10, 0, 0);

test("Claude parser normalizes official session, weekly and scoped windows", () => {
  const quota = parseClaudeUsage({
    five_hour: { utilization: 43, resets_at: "2026-08-02T12:00:00Z" },
    seven_day: { utilization: 18.5, resets_at: "2026-08-08T10:00:00Z" },
    seven_day_fable: { utilization: 7, resets_at: "2026-08-08T10:00:00Z" },
  }, { now, subscriptionType: "max", rateLimitTier: "default_20x" });

  assert.equal(quota.providerID, "claude");
  assert.equal(quota.planName, "Max 20x");
  assert.deepEqual(quota.windows.map((window) => window.windowMinutes), [300, 10080]);
  assert.equal(quota.windows[0].usedPercent, 43);
  assert.equal(quota.scopedWindows[0].scopeID, "fable");
});

test("Claude parser keeps structured scoped limits and converts extra-usage cents", () => {
  const quota = parseClaudeUsage({
    limits: [
      { kind: "session", percent: 35, resets_at: "2026-08-02T12:00:00Z" },
      { kind: "weekly_all", percent: 20, resets_at: "2026-08-08T10:00:00Z" },
      { kind: "weekly_scoped", percent: 72, resets_at: "2026-08-07T10:00:00Z", scope: { model: { id: null, display_name: "Fable" } } },
      { kind: "weekly_scoped", percent: 20, scope: { model: { id: "all_models", display_name: "Current week (all models)" } } },
    ],
    extra_usage: { is_enabled: true, used_credits: "1250", monthly_limit: 5000 },
  }, { now });

  assert.deepEqual(quota.windows.map((window) => window.usedPercent), [35, 20]);
  assert.deepEqual(quota.scopedWindows.map((scope) => scope.scopeID), ["fable"]);
  assert.deepEqual(quota.extraUsage, { spentUSD: 12.5, monthlyLimitUSD: 50 });
});

test("Codex parser classifies windows by duration instead of response slot", () => {
  const quota = parseCodexUsage({
    plan_type: "prolite",
    rate_limit: {
      primary_window: { used_percent: 62, limit_window_seconds: 604800, reset_after_seconds: 3600 },
      secondary_window: { used_percent: 12, limit_window_seconds: 18000, reset_at: now / 1000 + 7200 },
    },
  }, now);

  assert.equal(quota.providerID, "codex");
  assert.equal(quota.planName, "Pro 5x");
  assert.deepEqual(quota.windows.map((window) => window.windowMinutes), [300, 10080]);
  assert.equal(quota.windows[0].usedPercent, 12);
  assert.equal(quota.windows[1].usedPercent, 62);
});

test("Codex parser keeps the authoritative banked reset-credit count", () => {
  const quota = parseCodexUsage({
    rate_limit: { primary_window: { used_percent: 12, limit_window_seconds: 18_000 } },
    rate_limit_reset_credits: { available_count: "3.9", applicable_available_count: 1 },
  }, now);
  assert.deepEqual(quota.codexResetCredits, { availableCount: 3 });
  assert.equal(parseCodexUsage({ rate_limit: { primary_window: { used_percent: 12 } } }, now).codexResetCredits, undefined);
});

test("Codex local model pools retain both session and weekly windows", () => {
  const resetsAt = now / 1000 + 86_400;
  const text = [
    {
      timestamp: "2026-08-02T09:55:00.000Z",
      payload: { type: "token_count", rate_limits: {
        limit_id: "codex",
        plan_type: "prolite",
        primary: { used_percent: 31, window_minutes: 300, resets_at: resetsAt },
        secondary: { used_percent: 22, window_minutes: 10_080, resets_at: resetsAt },
      } },
    },
    {
      timestamp: "2026-08-02T09:56:00.000Z",
      payload: { type: "token_count", rate_limits: {
        limit_id: "codex_bengalfox",
        limit_name: "GPT-5.3-Codex-Spark",
        primary: { used_percent: 95, window_minutes: 300, resets_at: resetsAt },
        secondary: { used_percent: 44, window_minutes: 10_080, resets_at: resetsAt },
      } },
    },
  ].map(JSON.stringify).join("\n");
  const scoped = codexModelScopedWindows(parseCodexSessionSnapshots(text), now);
  assert.deepEqual(scoped.map((scope) => scope.scopeID), ["codex_bengalfox_session", "codex_bengalfox_weekly"]);
  assert.deepEqual(scoped.map((scope) => scope.displayName), ["GPT-5.3-Codex-Spark", "GPT-5.3-Codex-Spark"]);
  assert.deepEqual(scoped.map((scope) => scope.window.usedPercent), [95, 44]);
  assert.deepEqual(scoped.map((scope) => scope.window.windowMinutes), [300, 10_080]);
});

test("Codex model snapshots survive missing resets and long IDs remain distinct", () => {
  const text = [
    { timestamp: "2026-08-02T09:55:00.000Z", payload: { type: "token_count", rate_limits: { limit_id: "codex", primary: { used_percent: 31, window_minutes: 300 } } } },
    { timestamp: "2026-08-02T09:56:00.000Z", payload: { type: "token_count", rate_limits: { limit_id: "codex_bengalfox_pro_extended_alpha", limit_name: "GPT-5.3-Codex-Spark-Alpha", primary: { used_percent: 9, window_minutes: 300 }, secondary: { used_percent: 40, window_minutes: 10_080 } } } },
    { timestamp: "2026-08-02T09:57:00.000Z", payload: { type: "token_count", rate_limits: { limit_id: "codex_bengalfox_pro_extended_beta", limit_name: "GPT-5.3-Codex-Spark-Beta", primary: { used_percent: 77, window_minutes: 300 }, secondary: { used_percent: 58, window_minutes: 10_080 } } } },
  ].map(JSON.stringify).join("\n");
  const scoped = codexModelScopedWindows(parseCodexSessionSnapshots(text), now);
  assert.equal(scoped.length, 4);
  assert.deepEqual(scoped.map((scope) => scope.scopeID), [
    "codex_bengalfox_071fde96_session",
    "codex_bengalfox_071fde96_weekly",
    "codex_bengalfox_563343ac_session",
    "codex_bengalfox_563343ac_weekly",
  ]);
  assert.equal(codexWireScopeBase("codex_bengalfox_pro_extended_alpha"), "codex_bengalfox_071fde96");
  assert.equal(codexWireScopeBase("codex_bengalfox_pro_extended_beta"), "codex_bengalfox_563343ac");
  assert.ok(scoped.every((scope) => scope.window.resetsAt === undefined));
});

test("Provider percentages are bounded at the privacy boundary", () => {
  const claude = parseClaudeUsage({ five_hour: { utilization: 180 } }, { now });
  const codex = parseCodexUsage({ rate_limit: { primary_window: { used_percent: -5 } } }, now);
  assert.equal(claude.windows[0].usedPercent, 100);
  assert.equal(codex.windows[0].usedPercent, 0);
});

test("Codex home expands Windows user-profile and tilde overrides", () => {
  assert.equal(resolveCodexHome({ CODEX_HOME: "%USERPROFILE%\\.codex-alt", USERPROFILE: "C:\\Users\\Ada" }, "C:\\Users\\Ada"), "C:\\Users\\Ada\\.codex-alt");
  assert.equal(resolveCodexHome({ CODEX_HOME: "~/.codex-alt" }, "/Users/ada"), join("/Users/ada", ".codex-alt"));
});

test("Codex collector accepts an injected Windows network fetch", async () => {
  const token = `x.${Buffer.from(JSON.stringify({ exp: Math.trunc(Date.now() / 1000) + 3600 })).toString("base64url")}.x`;
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return new Response(JSON.stringify({
      plan_type: "prolite",
      rate_limit: { primary_window: { used_percent: 32, limit_window_seconds: 18_000 } },
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-codex-"));
  try {
    await writeFile(join(directory, "auth.json"), JSON.stringify({ tokens: { access_token: token, account_id: "acct" } }));
    const quota = await collectCodex({ env: { CODEX_HOME: directory }, fetchImpl });
    assert.equal(quota.providerID, "codex");
    assert.equal(calls.length, 1);
    assert.equal(calls[0].options.headers["ChatGPT-Account-Id"], "acct");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
