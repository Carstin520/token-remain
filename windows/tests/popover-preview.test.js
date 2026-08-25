import assert from "node:assert/strict";
import test from "node:test";
import { buildPopoverModel } from "../src/popover-model.js";
import { buildPreviewState, createPopoverPreviewAPI } from "../src/popover-preview.js";

const NOW = Date.parse("2026-08-08T12:00:00Z");

function makeAPI() {
  const globalObject = {};
  const api = createPopoverPreviewAPI({ now: NOW, globalObject });
  return { api, debug: globalObject.__tokenRemainPopoverPreview };
}

function flushMicrotasks() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

test("preview state renders a full popover model", () => {
  const model = buildPopoverModel(buildPreviewState(NOW), { now: NOW });
  const ids = model.quota.map((card) => card.id).sort();
  assert.deepEqual(ids, ["claude", "codex"]);
  const claude = model.quota.find((card) => card.id === "claude");
  assert.equal(claude.windows.length, 2);
  // Both pools have activity, so Auto shows them without explicit overrides.
  assert.equal(claude.scopedWindows.length, 2);
  assert.deepEqual(claude.scopedWindows.map((scope) => scope.key), ["scope-fable", "scope-opus"]);
  assert.equal(claude.scopedWindows[1].title, "Opus · 7 d window");
  assert.equal(claude.detailRows[0].value, "$12.50 spent / $50.00");
  const codex = model.quota.find((card) => card.id === "codex");
  assert.deepEqual(codex.scopedWindows.map((scope) => scope.key), ["scope-codex_bengalfox"]);
  assert.equal(codex.detailRows[0].value, "2 available");
  assert.equal(codex.level, "high");
  assert.equal(model.risk.level, "high");
  assert.ok(model.usage.today.hasData);
  assert.ok(model.usage.yesterday.hasData);
  assert.ok(model.usage.last30Days.hasData);
  assert.equal(model.feed.items.length, 2);
});

test("subscriptions fire shown and visibility after subscribing and clean up", async () => {
  const { api } = makeAPI();
  let shown = 0;
  let visible;
  const offShown = api.onPopoverShown(() => { shown += 1; });
  const offVisible = api.onPopoverVisibility((value) => { visible = value; });
  const offUnsubscribed = api.onPopoverShown(() => { shown += 100; });
  offUnsubscribed();
  await flushMicrotasks();
  assert.equal(shown, 1);
  assert.equal(visible, true);
  assert.equal(typeof offShown, "function");
  offShown();
  offVisible();
});

test("refresh advances lastUpdatedAt through state listeners", async () => {
  const { api } = makeAPI();
  const seen = [];
  const off = api.onStateChanged((state) => seen.push(state));
  const before = (await api.getState()).lastUpdatedAt;
  await api.refresh();
  assert.equal(seen.length, 1);
  assert.ok(seen[0].lastUpdatedAt > before);
  assert.equal(seen[0].isRefreshing, false);
  off();
  await api.refresh();
  assert.equal(seen.length, 1);
});

test("setLaunchAtLogin flips the flag and notifies", async () => {
  const { api, debug } = makeAPI();
  let latest;
  api.onStateChanged((state) => { latest = state; });
  assert.equal((await api.getState()).launchAtLogin, false);
  await api.setLaunchAtLogin(true);
  assert.equal(latest.launchAtLogin, true);
  assert.deepEqual(debug.lastAction, { type: "setLaunchAtLogin", detail: true });
});

test("actions and copies are recorded, bounded to the latest", async () => {
  const { api, debug } = makeAPI();
  await api.copyText("first summary");
  await api.copyText("second summary");
  assert.equal(debug.copiedText, "second summary");
  await api.openDashboard("trends");
  assert.deepEqual(debug.lastAction, { type: "openDashboard", detail: "trends" });
  await api.openExternal("https://example.invalid/post");
  await api.relaunch();
  await api.quit();
  api.hidePopover();
  assert.deepEqual(debug.lastAction, { type: "hidePopover" });
  api.resizePopover(420);
  assert.equal(debug.requestedHeight, 420);
  assert.deepEqual(debug.lastAction, { type: "resizePopover", detail: 420 });
  assert.equal(debug.state.deviceName, "Preview PC (synthetic)");
});
