import assert from "node:assert/strict";
import test from "node:test";
import {
  detectedLocalUsageSources,
  LOCAL_USAGE_SOURCE_CATALOG,
  localSourceDisplayName,
  normalizeDisabledLocalUsageSources,
} from "../src/local-sources.js";

test("local usage catalog mirrors the 16 macOS source definitions", () => {
  assert.deepEqual(LOCAL_USAGE_SOURCE_CATALOG.map(({ id, displayName }) => [id, displayName]), [
    ["claude", "Claude Code"], ["codex", "Codex"], ["opencode", "OpenCode"], ["amp", "Amp"],
    ["droid", "Droid"], ["codebuff", "Codebuff"], ["hermes", "Hermes Agent"], ["pi", "pi-agent"],
    ["goose", "Goose"], ["openclaw", "OpenClaw"], ["kilo", "Kilo Code"], ["kimi", "Kimi CLI"],
    ["qwen", "Qwen CLI"], ["copilot", "GitHub Copilot CLI"], ["gemini", "Gemini"], ["trae-agent", "Trae Agent"],
  ]);
  assert.equal(localSourceDisplayName(" future_agent-cli "), "Future Agent Cli");
});

test("disabled source preferences accept only canonical well-formed string IDs", () => {
  assert.deepEqual(normalizeDisabledLocalUsageSources([
    " Codex ", "codex", "future_agent", 42, "bad source", "", "-invalid",
  ]), ["codex", "future_agent"]);
  assert.deepEqual(normalizeDisabledLocalUsageSources("codex"), []);
});

test("data-source rows include only agents detected in recent raw history", () => {
  const capturedAt = Date.parse("2026-08-25T10:00:00Z");
  const sources = detectedLocalUsageSources({ capturedAt, days: [{
    day: "2026-08-25",
    agents: [{ id: "gemini", tokens: 20, cost: 0.1 }, { id: "future_agent", tokens: 10, cost: 0 }],
  }] });
  assert.deepEqual(sources, [
    { id: "gemini", displayName: "Gemini", capturedAt },
    { id: "future_agent", displayName: "Future Agent", capturedAt },
  ]);
  assert.ok(!sources.some((source) => source.id === "trae-agent"));
});
