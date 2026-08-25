import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  HOST_ROUTE_TABLE,
  WINDOWS_HOST_REROUTE_PROVIDER_IDS,
  classifyHostRoute,
  detectHostAppRoute,
  normalizedBaseURL,
  parseCodexRoutingConfiguration,
} from "../electron/host-routing.js";
import { collectProvider } from "../electron/providers/index.js";

function response(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    json: async () => body,
  };
}

test("Host route classification mirrors every known macOS ID and domain", () => {
  for (const route of HOST_ROUTE_TABLE) {
    for (const id of route.ids) {
      assert.deepEqual(classifyHostRoute({ providerID: id }), {
        providerID: route.providerID,
        displayName: route.displayName,
      });
    }
    for (const domain of route.domains) {
      assert.deepEqual(classifyHostRoute({
        providerID: "unrelated",
        baseURL: `https://api.${domain}/v1`,
      }), {
        providerID: route.providerID,
        displayName: route.displayName,
      });
    }
  }
});

test("Concrete unknown and loopback hosts stay generic and deceptive suffixes do not impersonate known providers", () => {
  assert.deepEqual(classifyHostRoute({ providerID: "deepseek-proxy", baseURL: "https://relay.example.com/v1" }), {
    providerID: "thirdParty",
    displayName: "relay.example.com",
  });
  assert.equal(classifyHostRoute({ baseURL: "https://api.deepseek.com.evil.example/v1" }).providerID, "thirdParty");
  assert.deepEqual(classifyHostRoute({ providerID: "deepseek", baseURL: "http://127.0.0.1:8080/v1" }), {
    providerID: "thirdParty",
    displayName: "127.0.0.1",
  });
  assert.deepEqual(classifyHostRoute({ baseURL: "http://localhost:11434/v1" }), {
    providerID: "thirdParty",
    displayName: "localhost",
  });
  assert.equal(normalizedBaseURL("https://user:secret@relay.example.com/v1"), undefined);
});

test("Codex TOML parser reads documented routing keys, quotes, booleans, and comments", () => {
  const parsed = parseCodexRoutingConfiguration(`
    model_provider = "deepseek" # selected provider
    preferred_auth_method = "apikey"
    [model_providers."deepseek"]
    base_url = "https://api.deepseek.com/v1"
    env_key = "DEEPSEEK_API_KEY"
    [model_providers.openai_http]
    requires_openai_auth = true
  `);
  assert.equal(parsed.modelProvider, "deepseek");
  assert.equal(parsed.preferredAuthMethod, "apikey");
  assert.deepEqual(parsed.providers.deepseek, {
    requiresOpenAIAuth: false,
    baseURL: "https://api.deepseek.com/v1",
    environmentKey: "DEEPSEEK_API_KEY",
  });
  assert.equal(parsed.providers.openai_http.requiresOpenAIAuth, true);
});

test("Claude settings.local env overrides settings.json for route detection", async () => {
  const home = await mkdtemp(join(tmpdir(), "tokenremain-host-route-"));
  try {
    const directory = join(home, ".claude");
    await mkdir(directory);
    await writeFile(join(directory, "settings.json"), JSON.stringify({ env: { ANTHROPIC_BASE_URL: "https://api.anthropic.com" } }));
    await writeFile(join(directory, "settings.local.json"), JSON.stringify({ env: {
      ANTHROPIC_BASE_URL: "https://api.deepseek.com/anthropic",
      ANTHROPIC_AUTH_TOKEN: "settings-key",
    } }));

    const route = await detectHostAppRoute("claude", { env: {}, home });
    assert.equal(route.sourceProviderID, "deepseek");
    assert.equal(route.displayName, "DeepSeek API");
    assert.equal(route.credential, "settings-key");
    assert.equal(route.routeIdentifier, "claude|deepseek|api.deepseek.com");
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("Known compatible host routes reroute the quota fetch and preserve the host card identity", async () => {
  assert.deepEqual([...WINDOWS_HOST_REROUTE_PROVIDER_IDS], ["deepseek", "openrouter", "zai", "kimi", "minimax"]);
  let request;
  const quota = await collectProvider("claude", {
    env: {
      ANTHROPIC_BASE_URL: "https://api.deepseek.com/anthropic",
      ANTHROPIC_AUTH_TOKEN: "route-secret",
    },
    fetchImpl: async (url, options) => {
      request = { url: String(url), authorization: options.headers.Authorization };
      return response({ is_available: true, balance_infos: [{ total_balance: "12.50", currency: "USD" }] });
    },
  });

  assert.deepEqual(request, { url: "https://api.deepseek.com/user/balance", authorization: "Bearer route-secret" });
  assert.equal(quota.providerID, "claude");
  assert.deepEqual(quota.attribution, {
    displayName: "DeepSeek API",
    routeIdentifier: "claude|deepseek|api.deepseek.com",
  });
  assert.doesNotMatch(JSON.stringify(quota), /route-secret/);
});

test("Unknown Codex relays are labeling-only and keep the host's official reading", async () => {
  const home = await mkdtemp(join(tmpdir(), "tokenremain-codex-route-"));
  try {
    await writeFile(join(home, "auth.json"), JSON.stringify({
      tokens: { access_token: `header.${Buffer.from(JSON.stringify({ exp: 4_102_444_800 })).toString("base64url")}.signature` },
    }));
    let requestedURL;
    const quota = await collectProvider("codex", {
      home,
      env: { CODEX_HOME: home, OPENAI_BASE_URL: "http://localhost:11434/v1" },
      now: Date.parse("2026-08-26T10:00:00Z"),
      fetchImpl: async (url) => {
        requestedURL = String(url);
        return response({ rate_limit: { primary_window: { used_percent: 23, limit_window_seconds: 18_000 } } });
      },
    });

    assert.equal(requestedURL, "https://chatgpt.com/backend-api/wham/usage");
    assert.equal(quota.providerID, "codex");
    assert.equal(quota.windows[0].usedPercent, 23);
    assert.deepEqual(quota.attribution, {
      displayName: "localhost",
      routeIdentifier: "codex|thirdparty|localhost",
    });
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
