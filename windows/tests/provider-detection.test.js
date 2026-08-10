import assert from "node:assert/strict";
import test from "node:test";
import { PROVIDER_CATALOG, PROVIDER_IDS } from "../electron/providers/catalog.js";
import { detectLocalProviders } from "../electron/providers/detection.js";
import { LOCAL_PROVIDER_IDS } from "../electron/providers/index.js";
import { PROVIDER_ORDER } from "../src/provider-meta.js";

test("Every displayed provider has exactly one Windows-local adapter", () => {
  assert.deepEqual(PROVIDER_IDS, PROVIDER_ORDER);
  assert.deepEqual(LOCAL_PROVIDER_IDS, PROVIDER_ORDER);
  assert.equal(PROVIDER_CATALOG.length, 19);
  assert.ok(PROVIDER_CATALOG.every((provider) => ["local-session", "local-credential"].includes(provider.access)));
});

test("Windows scan detects installed apps and preconfigured local credentials", () => {
  const existing = new Set([
    "/Users/test/.claude",
    "/Users/test/.codex",
    "/Windows/AppData/Roaming/Cursor",
    "/Windows/AppData/Local/Programs/Windsurf",
    "/tools/grok.exe",
    "/Windows/Program Files/Antigravity",
    "/tools/opencode.cmd",
    "/Windows/AppData/Local/Programs/Kiro",
    "/Users/test/.zcode",
    "/Users/test/.kimi-code",
    "/Windows/AppData/Roaming/Qoder",
  ]);
  const detections = detectLocalProviders({
    platform: "win32",
    env: {
      USERPROFILE: "/Users/test",
      APPDATA: "/Windows/AppData/Roaming",
      LOCALAPPDATA: "/Windows/AppData/Local",
      PROGRAMFILES: "/Windows/Program Files",
      PATH: "/tools;/Windows/System32",
      OPENROUTER_API_KEY: "configured-in-environment",
    },
    exists: (path) => existing.has(path),
    readDirectory: (path) => path.endsWith("/.vscode/extensions") ? ["github.copilot-1.2.3"] : [],
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
