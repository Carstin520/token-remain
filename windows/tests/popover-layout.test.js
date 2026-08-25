import assert from "node:assert/strict";
import test from "node:test";
import {
  AI_FEED_WIDGET_ID,
  LOCAL_USAGE_WIDGET_ID,
  POPOVER_LAYOUT_KEY,
  defaultLayout,
  moveVisibleWidget,
  moveWidget,
  normalizeLayout,
  reorderVisibleWidgets,
  restorablePinnedIDs,
  popoverWidgetIDs,
  readStoredLayout,
  setWidgetHidden,
  toggleWidgetPinned,
  visibleWidgetIDs,
  writeStoredLayout,
} from "../src/popover-layout.js";

const providers = ["claude", "codex", "copilot"];

function memoryStorage(initial = {}) {
  const map = new Map(Object.entries(initial));
  return {
    getItem: (key) => (map.has(key) ? map.get(key) : null),
    setItem: (key, value) => map.set(key, value),
    dump: () => Object.fromEntries(map),
  };
}

test("default order is usable providers, then localUsage, then aiFeed", () => {
  assert.deepEqual(popoverWidgetIDs(providers), ["claude", "codex", "copilot", LOCAL_USAGE_WIDGET_ID, AI_FEED_WIDGET_ID]);
  assert.deepEqual(defaultLayout(providers), {
    order: ["claude", "codex", "copilot", LOCAL_USAGE_WIDGET_ID, AI_FEED_WIDGET_ID],
    hidden: [],
    pinned: [],
  });
});

test("normalization drops unknown and duplicate IDs and appends missing ones", () => {
  const layout = normalizeLayout({
    order: ["codex", "ghost", "codex", AI_FEED_WIDGET_ID, "claude"],
    hidden: ["copilot", "ghost", "copilot"],
    pinned: ["claude", "claude", "ghost"],
  }, providers);
  assert.deepEqual(layout.order, ["codex", AI_FEED_WIDGET_ID, "claude", "copilot", LOCAL_USAGE_WIDGET_ID]);
  assert.deepEqual(layout.hidden, ["copilot"]);
  assert.deepEqual(layout.pinned, ["claude"]);
});

test("restorable pins survive providers that have not loaded yet", () => {
  // The shown handler runs before provider snapshots arrive; a claude pin must
  // not be dropped just because no provider list exists at that moment.
  assert.deepEqual(restorablePinnedIDs({ order: [], hidden: [], pinned: ["claude", AI_FEED_WIDGET_ID] }), ["claude", AI_FEED_WIDGET_ID]);
});

test("restorable pins keep sanitization: strings only, no hidden, no localUsage, no duplicates", () => {
  assert.deepEqual(restorablePinnedIDs({
    hidden: ["codex"],
    pinned: ["claude", "claude", "codex", LOCAL_USAGE_WIDGET_ID, 42, null, { id: "x" }, ""],
  }), ["claude"]);
});

test("restorable pins degrade corrupt shapes to no pins", () => {
  for (const corrupt of [undefined, null, 42, "junk", [], { pinned: "nope" }, { pinned: {}, hidden: 7 }]) {
    assert.deepEqual(restorablePinnedIDs(corrupt), []);
  }
});

test("normalization repairs corrupt shapes to the default layout", () => {
  for (const corrupt of [undefined, null, 42, "junk", [], { order: "nope", hidden: 7, pinned: {} }]) {
    assert.deepEqual(normalizeLayout(corrupt, providers), defaultLayout(providers));
  }
});

test("normalization strips pins on hidden widgets and on localUsage", () => {
  const layout = normalizeLayout({
    order: popoverWidgetIDs(providers),
    hidden: ["codex"],
    pinned: ["codex", LOCAL_USAGE_WIDGET_ID, AI_FEED_WIDGET_ID],
  }, providers);
  assert.deepEqual(layout.pinned, [AI_FEED_WIDGET_ID]);
});

test("readStoredLayout survives corrupt storage and missing keys", () => {
  assert.deepEqual(readStoredLayout(undefined, providers), defaultLayout(providers));
  assert.deepEqual(readStoredLayout(memoryStorage(), providers), defaultLayout(providers));
  const corrupt = memoryStorage({ [POPOVER_LAYOUT_KEY]: "{not json" });
  assert.deepEqual(readStoredLayout(corrupt, providers), defaultLayout(providers));
});

test("write/read round trip persists only IDs and layout flags", () => {
  const storage = memoryStorage();
  const layout = toggleWidgetPinned(setWidgetHidden(defaultLayout(providers), "copilot", true), "claude");
  writeStoredLayout(storage, layout);
  assert.deepEqual(readStoredLayout(storage, providers), layout);
  const stored = JSON.parse(storage.dump()[POPOVER_LAYOUT_KEY]);
  assert.deepEqual(Object.keys(stored).sort(), ["hidden", "order", "pinned", "version"]);
  for (const value of [...stored.order, ...stored.hidden, ...stored.pinned]) {
    assert.equal(typeof value, "string");
  }
});

test("move respects boundaries and ignores unknown IDs", () => {
  const layout = defaultLayout(providers);
  assert.deepEqual(moveWidget(layout, "claude", -1).order, layout.order);
  assert.deepEqual(moveWidget(layout, AI_FEED_WIDGET_ID, +1).order, layout.order);
  assert.deepEqual(moveWidget(layout, "ghost", +1).order, layout.order);
  assert.deepEqual(
    moveWidget(layout, "codex", -1).order,
    ["codex", "claude", "copilot", LOCAL_USAGE_WIDGET_ID, AI_FEED_WIDGET_ID],
  );
  assert.deepEqual(
    moveWidget(layout, "codex", +1).order,
    ["claude", "copilot", "codex", LOCAL_USAGE_WIDGET_ID, AI_FEED_WIDGET_ID],
  );
});

test("visible-order move hops over hidden widgets and stops at visible edges", () => {
  const layout = setWidgetHidden(defaultLayout(providers), "codex", true);
  // Moving down from claude lands past hidden codex, not uselessly beside it.
  assert.deepEqual(
    moveVisibleWidget(layout, "claude", +1).order,
    ["codex", "copilot", "claude", LOCAL_USAGE_WIDGET_ID, AI_FEED_WIDGET_ID],
  );
  assert.deepEqual(
    moveVisibleWidget(layout, "copilot", -1).order,
    ["copilot", "claude", "codex", LOCAL_USAGE_WIDGET_ID, AI_FEED_WIDGET_ID],
  );
  // Boundaries are the *visible* edges; hidden and unknown IDs never move.
  assert.deepEqual(moveVisibleWidget(layout, "claude", -1).order, layout.order);
  assert.deepEqual(moveVisibleWidget(layout, AI_FEED_WIDGET_ID, +1).order, layout.order);
  assert.deepEqual(moveVisibleWidget(layout, "codex", +1).order, layout.order);
  assert.deepEqual(moveVisibleWidget(layout, "ghost", +1).order, layout.order);
});

test("reorderVisibleWidgets applies a full drag order", () => {
  const layout = defaultLayout(providers);
  const next = reorderVisibleWidgets(layout, [AI_FEED_WIDGET_ID, "codex", "claude", LOCAL_USAGE_WIDGET_ID, "copilot"]);
  assert.deepEqual(next.order, [AI_FEED_WIDGET_ID, "codex", "claude", LOCAL_USAGE_WIDGET_ID, "copilot"]);
  assert.deepEqual(next.hidden, []);
  assert.deepEqual(next.pinned, []);
});

test("reorderVisibleWidgets keeps hidden widgets in their stored slots", () => {
  let layout = defaultLayout(providers);
  layout = setWidgetHidden(layout, "codex", true);
  // Visible: claude, copilot, localUsage, aiFeed. Hidden codex sits at index 1.
  const next = reorderVisibleWidgets(layout, [AI_FEED_WIDGET_ID, LOCAL_USAGE_WIDGET_ID, "copilot", "claude"]);
  assert.deepEqual(next.order, [AI_FEED_WIDGET_ID, "codex", LOCAL_USAGE_WIDGET_ID, "copilot", "claude"]);
  assert.deepEqual(next.hidden, ["codex"]);
  assert.deepEqual(visibleWidgetIDs(next), [AI_FEED_WIDGET_ID, LOCAL_USAGE_WIDGET_ID, "copilot", "claude"]);
});

test("reorderVisibleWidgets survives corrupt, partial, and duplicate input", () => {
  let layout = defaultLayout(providers);
  layout = setWidgetHidden(layout, "copilot", true);
  // Unknown IDs, a hidden ID, and duplicates are dropped; omitted visible
  // widgets keep their current relative order after the requested ones.
  const next = reorderVisibleWidgets(layout, ["ghost", "codex", "copilot", "codex", 42, null]);
  assert.deepEqual(next.order, ["codex", "claude", "copilot", LOCAL_USAGE_WIDGET_ID, AI_FEED_WIDGET_ID]);
  assert.deepEqual(next.hidden, ["copilot"]);

  // Entirely non-array input leaves the visible order unchanged.
  assert.deepEqual(reorderVisibleWidgets(layout, undefined).order, layout.order);
  assert.deepEqual(reorderVisibleWidgets(layout, "claude,codex").order, layout.order);
});

test("hide removes from the visible list and drops the pin; show restores", () => {
  let layout = toggleWidgetPinned(defaultLayout(providers), "codex");
  layout = setWidgetHidden(layout, "codex", true);
  assert.deepEqual(layout.hidden, ["codex"]);
  assert.deepEqual(layout.pinned, []);
  assert.ok(!visibleWidgetIDs(layout).includes("codex"));
  layout = setWidgetHidden(layout, "codex", false);
  assert.deepEqual(layout.hidden, []);
  assert.deepEqual(visibleWidgetIDs(layout), defaultLayout(providers).order);
});

test("pin toggles for providers and the feed but never for localUsage", () => {
  let layout = defaultLayout(providers);
  layout = toggleWidgetPinned(layout, "claude");
  layout = toggleWidgetPinned(layout, AI_FEED_WIDGET_ID);
  assert.deepEqual(layout.pinned, ["claude", AI_FEED_WIDGET_ID]);
  layout = toggleWidgetPinned(layout, "claude");
  assert.deepEqual(layout.pinned, [AI_FEED_WIDGET_ID]);
  assert.deepEqual(toggleWidgetPinned(layout, LOCAL_USAGE_WIDGET_ID).pinned, [AI_FEED_WIDGET_ID]);
  assert.deepEqual(toggleWidgetPinned(layout, "ghost").pinned, [AI_FEED_WIDGET_ID]);
});
