import assert from "node:assert/strict";
import test from "node:test";
import { mergeProviders, PROVIDER_ORDER, providerMeta } from "../src/provider-meta.js";

test("All providers published by the Mac have Windows presentation metadata", () => {
  assert.equal(PROVIDER_ORDER.length, 19);
  for (const providerID of PROVIDER_ORDER) {
    const meta = providerMeta(providerID);
    assert.ok(meta.name);
    assert.ok(meta.icon);
    assert.ok(meta.color);
  }
});

test("Provider merge keeps every synced provider and prefers the newest capture", () => {
  const remote = [
    { providerID: "cursor", capturedAt: 20, windows: [] },
    { providerID: "claude", capturedAt: 10, windows: [] },
    { providerID: "future-provider", capturedAt: 30, windows: [] },
  ];
  const local = [
    { providerID: "claude", capturedAt: 40, windows: [{ usedPercent: 1 }] },
    { providerID: "codex", capturedAt: 15, windows: [] },
  ];
  const merged = mergeProviders(local, remote);
  assert.deepEqual(merged.map((provider) => provider.providerID), ["claude", "codex", "cursor", "future-provider"]);
  assert.equal(merged[0].capturedAt, 40);
});
