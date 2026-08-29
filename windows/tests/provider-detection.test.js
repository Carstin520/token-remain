import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";
import { PROVIDER_CATALOG, PROVIDER_IDS } from "../electron/providers/catalog.js";
import { detectLocalProviders, resolveProviderDesktopAppPath } from "../electron/providers/detection.js";
import { LOCAL_PROVIDER_IDS } from "../electron/providers/index.js";
import { PROVIDER_ORDER } from "../src/provider-meta.js";

test("Every displayed provider has exactly one Windows-local adapter", () => {
  assert.deepEqual(PROVIDER_IDS, PROVIDER_ORDER);
  assert.deepEqual(LOCAL_PROVIDER_IDS, PROVIDER_ORDER);
  assert.equal(PROVIDER_CATALOG.length, 19);
  assert.ok(PROVIDER_CATALOG.every((provider) => ["local-session", "local-credential"].includes(provider.access)));
});

test("Windows scan detects installed apps and preconfigured local credentials", () => {
  const home = join("C:", "Users", "test");
  const roaming = join("C:", "Windows", "AppData", "Roaming");
  const local = join("C:", "Windows", "AppData", "Local");
  const programFiles = join("C:", "Windows", "Program Files");
  const tools = join("C:", "tools");
  const system = join("C:", "Windows", "System32");
  const existing = new Set([
    join(home, ".claude"),
    join(home, ".codex"),
    join(roaming, "Cursor"),
    join(local, "Programs", "Windsurf"),
    join(tools, "grok.exe"),
    join(programFiles, "Antigravity"),
    join(tools, "opencode.cmd"),
    join(local, "Programs", "Kiro"),
    join(home, ".zcode"),
    join(home, ".kimi-code"),
    join(roaming, "Qoder"),
  ]);
  const detections = detectLocalProviders({
    platform: "win32",
    env: {
      USERPROFILE: home,
      APPDATA: roaming,
      LOCALAPPDATA: local,
      PROGRAMFILES: programFiles,
      PATH: `${tools};${system}`,
      OPENROUTER_API_KEY: "configured-in-environment",
    },
    exists: (path) => existing.has(path),
    readDirectory: (path) => path.endsWith(join(".vscode", "extensions")) ? ["github.copilot-1.2.3"] : [],
    hasStoredSecret: (providerID) => providerID === "deepseek",
  });
  const byID = new Map(detections.map((provider) => [provider.providerID, provider]));

  for (const id of ["claude", "codex", "cursor", "copilot", "windsurf", "grok", "antigravity", "opencode", "kiro", "openrouter", "deepseek", "zai", "kimi", "qoder"]) {
    assert.equal(byID.get(id).installed, true, `${id} should be detected`);
  }
  assert.equal(byID.get("zai").installed, true);
  assert.equal(byID.get("zai").configured, false);
  assert.equal(byID.get("zai").access, "local-credential");
  assert.match(byID.get("zai").detail, /Detected ZCode/);
});

test("desktop-app launch paths come only from allow-listed Claude and Codex install locations", () => {
  const local = join("C:", "Users", "test", "AppData", "Local");
  const roaming = join("C:", "Users", "test", "AppData", "Roaming");
  const claude = join(local, "Programs", "Claude", "Claude.exe");
  const codex = join(roaming, "Codex", "app-1.12.3", "Codex.exe");
  const existing = new Set([claude, codex]);
  const options = {
    platform: "win32",
    env: { LOCALAPPDATA: local, APPDATA: roaming },
    exists: (path) => existing.has(path),
    readDirectory: (path) => path === join(roaming, "Codex") ? ["app-1.9.0", "app-1.12.3"] : [],
  };

  assert.equal(resolveProviderDesktopAppPath("claude", options), claude);
  assert.equal(resolveProviderDesktopAppPath("codex", options), codex);
  assert.equal(resolveProviderDesktopAppPath("cursor", options), undefined);
  assert.equal(resolveProviderDesktopAppPath(claude, options), undefined, "renderer paths are never accepted as input");
  assert.equal(resolveProviderDesktopAppPath("claude", { ...options, platform: "darwin" }), undefined);
});
