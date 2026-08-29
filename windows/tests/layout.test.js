import assert from "node:assert/strict";
import test from "node:test";
import { moveItem, normalizeOrder, readStoredOrder, writeStoredOrder } from "../src/layout.js";

test("Layout normalization removes stale and duplicate providers while adding new ones", () => {
  assert.deepEqual(
    normalizeOrder(["codex", "codex", "removed", "claude"], ["claude", "codex", "cursor"]),
    ["codex", "claude", "cursor"],
  );
});

test("Moving a card uses the destination's current slot", () => {
  assert.deepEqual(moveItem(["claude", "codex", "cursor"], "claude", "cursor"), ["codex", "cursor", "claude"]);
  assert.deepEqual(moveItem(["claude", "codex", "cursor"], "cursor", "claude"), ["cursor", "claude", "codex"]);
});

test("Layout order persists with a versioned payload and recovers from invalid data", () => {
  const values = new Map();
  const storage = {
    getItem: (key) => values.get(key),
    setItem: (key, value) => values.set(key, value),
  };
  writeStoredOrder(storage, "layout", ["codex", "claude"]);
  assert.deepEqual(readStoredOrder(storage, "layout", ["claude", "codex"]), ["codex", "claude"]);
  values.set("layout", "not-json");
  assert.deepEqual(readStoredOrder(storage, "layout", ["claude", "codex"]), ["claude", "codex"]);
});
