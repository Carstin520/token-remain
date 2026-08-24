// Layout state for the popover's widget stack: which widgets show, in what
// order, which are hidden, and which provider cards stay expanded (pinned).
//
// The state is deliberately content-free — only widget IDs and boolean-like
// flags are ever persisted, never quota numbers, feed text, or telemetry. The
// caller decides which provider IDs are usable at runtime and passes them in;
// this module owns the two built-in widgets that always trail them.

export const LOCAL_USAGE_WIDGET_ID = "localUsage";
export const AI_FEED_WIDGET_ID = "aiFeed";
export const BUILTIN_WIDGET_IDS = [LOCAL_USAGE_WIDGET_ID, AI_FEED_WIDGET_ID];

export const POPOVER_LAYOUT_KEY = "tokenremain.windows.popoverLayout.v1";

/// Full widget ID list in stable default order: the caller's usable provider
/// IDs first (their order is the default ranking), then Local Usage, then the
/// AI feed.
export function popoverWidgetIDs(providerIDs = []) {
  const ids = [];
  for (const id of Array.isArray(providerIDs) ? providerIDs : []) {
    if (typeof id === "string" && id && !ids.includes(id) && !BUILTIN_WIDGET_IDS.includes(id)) {
      ids.push(id);
    }
  }
  return [...ids, ...BUILTIN_WIDGET_IDS];
}

export function defaultLayout(providerIDs = []) {
  return { order: popoverWidgetIDs(providerIDs), hidden: [], pinned: [] };
}

/// Repairs any stored shape against what is actually available right now:
/// unknown and duplicate IDs are dropped, newly available IDs are appended in
/// default position, and pins that no longer make sense (hidden widgets,
/// Local Usage, non-widgets) are removed.
export function normalizeLayout(layout, providerIDs = []) {
  const available = popoverWidgetIDs(providerIDs);
  const availableSet = new Set(available);
  const order = [];
  for (const id of Array.isArray(layout?.order) ? layout.order : []) {
    if (availableSet.has(id) && !order.includes(id)) order.push(id);
  }
  for (const id of available) {
    if (!order.includes(id)) order.push(id);
  }
  const hidden = [];
  for (const id of Array.isArray(layout?.hidden) ? layout.hidden : []) {
    if (availableSet.has(id) && !hidden.includes(id)) hidden.push(id);
  }
  const pinned = [];
  for (const id of Array.isArray(layout?.pinned) ? layout.pinned : []) {
    if (canPinWidget(id) && availableSet.has(id) && !hidden.includes(id) && !pinned.includes(id)) {
      pinned.push(id);
    }
  }
  return { order, hidden, pinned };
}

/// The widgets the popover should actually render, in order.
export function visibleWidgetIDs(layout) {
  const hidden = new Set(layout?.hidden || []);
  return (layout?.order || []).filter((id) => !hidden.has(id));
}

export function isWidgetHidden(layout, id) {
  return Boolean(layout?.hidden?.includes(id));
}

export function isWidgetPinned(layout, id) {
  return Boolean(layout?.pinned?.includes(id));
}

/// Pinned IDs worth restoring when the popover is shown, read from a raw
/// (possibly foreign) layout shape. Unlike normalizeLayout, this does not
/// filter against the currently available providers: provider snapshots arrive
/// asynchronously, and a pin must survive that gap so the card reopens
/// expanded once its data lands. Only non-empty string IDs pass, hidden
/// widgets stay collapsed, and unpinnable widgets never restore.
export function restorablePinnedIDs(layout) {
  const hidden = new Set(Array.isArray(layout?.hidden) ? layout.hidden : []);
  const pinned = [];
  for (const id of Array.isArray(layout?.pinned) ? layout.pinned : []) {
    if (typeof id === "string" && id && canPinWidget(id) && !hidden.has(id) && !pinned.includes(id)) {
      pinned.push(id);
    }
  }
  return pinned;
}

/// Local Usage is a digest, not a provider card — it has no expanded form, so
/// it can never be pinned.
export function canPinWidget(id) {
  return id !== LOCAL_USAGE_WIDGET_ID;
}

/// Moves a widget one slot up (-1) or down (+1); at a boundary or for an
/// unknown ID the layout comes back unchanged.
export function moveWidget(layout, id, direction) {
  const order = layout?.order || [];
  const from = order.indexOf(id);
  const to = from + (direction < 0 ? -1 : 1);
  if (from < 0 || to < 0 || to >= order.length) return { ...layout, order: [...order] };
  const next = [...order];
  next.splice(to, 0, ...next.splice(from, 1));
  return { ...layout, order: next };
}

/// Moves a widget one slot up (-1) or down (+1) relative to the *visible*
/// stack, hopping over hidden widgets so a move always produces a change the
/// user can see. At a visible boundary or for a hidden/unknown ID the layout
/// comes back unchanged.
export function moveVisibleWidget(layout, id, direction) {
  const visible = visibleWidgetIDs(layout);
  const from = visible.indexOf(id);
  const to = from + (direction < 0 ? -1 : 1);
  if (from < 0 || to < 0 || to >= visible.length) return { ...layout, order: [...(layout?.order || [])] };
  const order = (layout?.order || []).filter((entry) => entry !== id);
  const anchor = order.indexOf(visible[to]);
  order.splice(direction < 0 ? anchor : anchor + 1, 0, id);
  return { ...layout, order };
}

/// Applies a complete visible-stack order (as a drag reorder emits) to the
/// layout. The supplied IDs are validated against what is actually visible —
/// unknown, hidden, and duplicate entries are dropped, and any visible widget
/// the input omits keeps its current relative position. Hidden widgets never
/// move: only the existing visible slots are refilled in the new order.
export function reorderVisibleWidgets(layout, nextVisibleOrder) {
  const visible = visibleWidgetIDs(layout);
  const visibleSet = new Set(visible);
  const requested = [];
  for (const id of Array.isArray(nextVisibleOrder) ? nextVisibleOrder : []) {
    if (visibleSet.has(id) && !requested.includes(id)) requested.push(id);
  }
  for (const id of visible) {
    if (!requested.includes(id)) requested.push(id);
  }
  let slot = 0;
  const order = (layout?.order || []).map((id) => (visibleSet.has(id) ? requested[slot++] : id));
  return { ...layout, order };
}

export function setWidgetHidden(layout, id, wantHidden) {
  if (!layout?.order?.includes(id)) return layout;
  const hidden = (layout.hidden || []).filter((entry) => entry !== id);
  if (wantHidden) hidden.push(id);
  // A hidden widget has nothing to keep expanded, so hiding drops its pin.
  const pinned = wantHidden ? (layout.pinned || []).filter((entry) => entry !== id) : layout.pinned || [];
  return { ...layout, hidden, pinned };
}

export function toggleWidgetPinned(layout, id) {
  if (!canPinWidget(id) || !layout?.order?.includes(id) || isWidgetHidden(layout, id)) return layout;
  const pinned = (layout.pinned || []).filter((entry) => entry !== id);
  if (!isWidgetPinned(layout, id)) pinned.push(id);
  return { ...layout, pinned };
}

/// The stored layout, repaired against today's available providers. Any parse
/// failure or foreign shape degrades to the default layout.
export function readStoredLayout(storage, providerIDs = [], key = POPOVER_LAYOUT_KEY) {
  if (!storage) return defaultLayout(providerIDs);
  try {
    return normalizeLayout(JSON.parse(storage.getItem(key) || "null"), providerIDs);
  } catch {
    return defaultLayout(providerIDs);
  }
}

export function writeStoredLayout(storage, layout, key = POPOVER_LAYOUT_KEY) {
  if (!storage) return;
  storage.setItem(key, JSON.stringify({
    version: 1,
    order: layout?.order || [],
    hidden: layout?.hidden || [],
    pinned: layout?.pinned || [],
  }));
}
