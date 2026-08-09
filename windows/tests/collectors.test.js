import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { parseClaudeUsage } from "../electron/collectors/claude.js";
import { collectCodex, parseCodexUsage, resolveCodexHome } from "../electron/collectors/codex.js";

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

test("Provider percentages are bounded at the privacy boundary", () => {
  const claude = parseClaudeUsage({ five_hour: { utilization: 180 } }, { now });
  const codex = parseCodexUsage({ rate_limit: { primary_window: { used_percent: -5 } } }, now);
  assert.equal(claude.windows[0].usedPercent, 100);
  assert.equal(codex.windows[0].usedPercent, 0);
});

test("Codex home expands Windows user-profile and tilde overrides", () => {
  assert.equal(resolveCodexHome({ CODEX_HOME: "%USERPROFILE%\\.codex-alt", USERPROFILE: "C:\\Users\\Ada" }, "C:\\Users\\Ada"), "C:\\Users\\Ada\\.codex-alt");
  assert.equal(resolveCodexHome({ CODEX_HOME: "~/.codex-alt" }, "/Users/ada"), "/Users/ada/.codex-alt");
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
