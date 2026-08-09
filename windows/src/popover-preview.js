// Dev-only stand-in for the preload's tokenRemain bridge so /popover.html can
// be exercised in Vite without Electron. Every action records what it was
// asked to do instead of navigating, quitting, or resizing anything, and the
// latest recordings are published on globalThis.__tokenRemainPopoverPreview
// for manual and automated verification. Production builds never create this:
// popover.jsx only calls createPopoverPreviewAPI() behind import.meta.env.DEV.

const MINUTE_MS = 60_000;
const HOUR_MS = 3_600_000;
const DAY_MS = 86_400_000;
const HISTORY_DAYS = 32;

function dayKey(timestamp) {
  return new Date(timestamp).toISOString().slice(0, 10);
}

/// A realistic but obviously synthetic snapshot in the exact shape the preload
/// serves: Claude with both quota windows healthy-ish, Codex almost depleted
/// so the high-risk strip and red meter render, a month of daily usage, and
/// two AI Feed stories that survive feed curation.
export function buildPreviewState(now) {
  const days = Array.from({ length: HISTORY_DAYS }, (_, index) => {
    const offset = HISTORY_DAYS - 1 - index;
    // Deterministic wobble so the trend bars vary without Math.random.
    const wobble = (index * 7) % 5;
    return {
      day: dayKey(now - offset * DAY_MS),
      claudeTokens: 3_600_000 + wobble * 850_000,
      claudeCost: 2.9 + wobble * 0.6,
      codexTokens: 9_800_000 + wobble * 2_400_000,
      codexCost: 7.1 + wobble * 1.8,
    };
  });
  return {
    sourceInstanceID: "00000000-preview-preview-000000000000",
    deviceName: "Preview PC (synthetic)",
    appVersion: "0.0.0-preview",
    launchAtLogin: false,
    floatingWidgetEnabled: false,
    lastUpdatedAt: now - 90_000,
    isRefreshing: false,
    notices: {},
    providers: [
      {
        providerID: "claude",
        capturedAt: now - 2 * MINUTE_MS,
        planName: "Max 20x (preview)",
        windows: [
          { usedPercent: 41, windowMinutes: 300, resetsAt: now + 2 * HOUR_MS + 40 * MINUTE_MS },
          { usedPercent: 23, windowMinutes: 10_080, resetsAt: now + 4 * DAY_MS + 6 * HOUR_MS },
        ],
        // One model-scoped weekly cap so the expanded card's scoped-window row
        // renders in preview. Deliberately not a Fable scope: those never show
        // in the popup.
        scopedWindows: [
          {
            scopeID: "opus",
            displayName: "Opus",
            window: { usedPercent: 57, windowMinutes: 10_080, resetsAt: now + 4 * DAY_MS + 6 * HOUR_MS },
          },
        ],
      },
      {
        providerID: "codex",
        capturedAt: now - 9 * MINUTE_MS,
        planName: "Pro (preview)",
        windows: [
          { usedPercent: 94, windowMinutes: 300, resetsAt: now + 52 * MINUTE_MS },
        ],
      },
    ],
    dailyUsageHistory: { sourceDay: dayKey(now), capturedAt: now - 3 * MINUTE_MS, days },
    trending: [
      {
        id: "preview-story-1",
        username: "OpenAI",
        displayName: "OpenAI (preview)",
        publishedAt: now - 3 * HOUR_MS,
        url: "https://example.invalid/preview/token-reset",
        priority: "token_reset",
        tier: "primary",
        text: "Synthetic preview: Codex weekly usage limits now reset at fixed UTC times on all plans.",
        metrics: { replies: 420, reposts: 610, likes: 8_400 },
      },
      {
        id: "preview-story-2",
        username: "AnthropicAI",
        displayName: "Anthropic (preview)",
        publishedAt: now - 9 * HOUR_MS,
        url: "https://example.invalid/preview/major-update",
        priority: "major_update",
        tier: "primary",
        text: "Synthetic preview: Claude Code update rolling out with lower token overhead per agent session.",
        metrics: { replies: 260, reposts: 480, likes: 5_900 },
      },
    ],
    feedLoading: false,
    feedUpdatedAt: now - 4 * MINUTE_MS,
    sync: {
      paired: true,
      macURL: "http://preview-mac.local:47831/",
      deviceName: "Preview Mac (synthetic)",
      lastSyncAt: now - MINUTE_MS,
      encryption: "AES-256-GCM",
    },
  };
}

export function createPopoverPreviewAPI({ now = Date.now(), globalObject = globalThis } = {}) {
  let state = buildPreviewState(now);
  const stateListeners = new Set();
  const shownListeners = new Set();
  const visibilityListeners = new Set();

  // Bounded verification surface: only the latest of each recording, plus a
  // live read of the (fully synthetic) state.
  const debug = {
    preview: true,
    copiedText: undefined,
    lastAction: undefined,
    requestedHeight: undefined,
    get state() { return state; },
  };
  globalObject.__tokenRemainPopoverPreview = debug;

  const emitState = (next) => {
    state = next;
    for (const listener of stateListeners) listener(state);
  };
  const record = (type, detail) => {
    debug.lastAction = detail === undefined ? { type } : { type, detail };
  };
  const subscribe = (listeners, listener, fireNow) => {
    listeners.add(listener);
    // Fire after subscription so the popover's shown/visibility effects run in
    // preview exactly as they do when the tray opens the real window.
    if (fireNow) queueMicrotask(() => { if (listeners.has(listener)) fireNow(listener); });
    return () => listeners.delete(listener);
  };

  return {
    getState: async () => state,
    refresh: async () => {
      emitState({ ...state, isRefreshing: false, lastUpdatedAt: Math.max(Date.now(), state.lastUpdatedAt + 1) });
      record("refresh");
    },
    copyText: async (text) => {
      debug.copiedText = String(text);
      record("copyText");
      // Clipboard permission is not guaranteed in a plain browser tab; the
      // recording above is the source of truth, so failures stay silent.
      try { await globalThis.navigator?.clipboard?.writeText?.(String(text)); }
      catch { /* preview records instead */ }
    },
    setLaunchAtLogin: async (value) => {
      emitState({ ...state, launchAtLogin: Boolean(value) });
      record("setLaunchAtLogin", Boolean(value));
    },
    setFloatingWidgetEnabled: async (value) => {
      emitState({ ...state, floatingWidgetEnabled: Boolean(value) });
      record("setFloatingWidgetEnabled", Boolean(value));
    },
    relaunch: async () => record("relaunch"),
    quit: async () => record("quit"),
    openDashboard: async (section) => record("openDashboard", section),
    openExternal: async (url) => record("openExternal", String(url)),
    hidePopover: () => record("hidePopover"),
    resizePopover: (height) => {
      debug.requestedHeight = height;
      record("resizePopover", height);
    },
    onStateChanged: (listener) => subscribe(stateListeners, listener),
    onPopoverShown: (listener) => subscribe(shownListeners, listener, (fire) => fire()),
    onPopoverVisibility: (listener) => subscribe(visibilityListeners, listener, (fire) => fire(true)),
  };
}
