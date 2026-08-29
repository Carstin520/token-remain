import assert from "node:assert/strict";
import test from "node:test";
import {
  normalizeLimitsVisibility,
  readLimitsVisibility,
  setProviderVisible,
  writeLimitsVisibility,
} from "../src/limits-layout.js";

const available = ["claude", "codex", "cursor", "grok"];

test("Limits starts with discovered providers and auto-adds new discoveries", () => {
  const initial = normalizeLimitsVisibility(undefined, available, ["claude", "codex"]);
  assert.deepEqual(initial.visible, ["claude", "codex"]);
  const next = normalizeLimitsVisibility(initial, available, ["claude", "codex", "cursor"]);
  assert.deepEqual(next.visible, ["claude", "codex", "cursor"]);
});

test("Removed providers stay hidden even when still discovered", () => {
  const removed = setProviderVisible(
    { visible: ["claude", "codex", "cursor"], hidden: [] },
    "cursor",
    false,
    available,
    ["claude", "codex", "cursor"],
  );
  assert.deepEqual(removed.visible, ["claude", "codex"]);
  assert.deepEqual(removed.hidden, ["cursor"]);
  assert.deepEqual(
    normalizeLimitsVisibility(removed, available, ["claude", "codex", "cursor"]).visible,
    ["claude", "codex"],
  );
});

test("Limits refuses to remove the final visible provider and can restore a provider", () => {
  const final = setProviderVisible({ visible: ["codex"], hidden: ["claude"] }, "codex", false, available, ["codex"]);
  assert.deepEqual(final.visible, ["codex"]);
  const restored = setProviderVisible(final, "claude", true, available, ["codex"]);
  assert.deepEqual(restored.visible, ["codex", "claude"]);
  assert.deepEqual(restored.hidden, []);
});

test("Limits visibility persists as a versioned payload", () => {
  const values = new Map();
  const storage = { getItem: (key) => values.get(key), setItem: (key, value) => values.set(key, value) };
  writeLimitsVisibility(storage, "visibility", { visible: ["codex"], hidden: ["claude"] });
  assert.deepEqual(readLimitsVisibility(storage, "visibility", available, ["codex"]).visible, ["codex"]);
});
