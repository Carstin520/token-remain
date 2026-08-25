// Dev-only stand-in for the preload's tokenRemain bridge so /popover.html can
// be exercised in Vite without Electron. Every action records what it was
// asked to do instead of navigating, quitting, or resizing anything, and the
// latest recordings are published on globalThis.__tokenRemainPopoverPreview
// for manual and automated verification. Production builds never create this:
// popover.jsx only calls createPopoverPreviewAPI() behind import.meta.env.DEV.

const WALLPAPER_ID = "dev-acrylic-wallpaper";

/// Two deliberately opposite desktops. The popover has to stay cohesive over
/// both: a bright one is what makes a too-transparent surface unreadable, a dark
/// one is what makes a too-opaque card read as a black slab.
const PREVIEW_WALLPAPERS = {
  bright: `
      radial-gradient(58% 44% at 79% 11%, rgba(255, 255, 255, .96), rgba(255, 255, 255, 0) 70%),
      radial-gradient(72% 52% at 18% 24%, #e2f2fb, rgba(226, 242, 251, 0) 72%),
      radial-gradient(92% 58% at 52% 97%, #2f7fae, rgba(47, 127, 174, 0) 70%),
      linear-gradient(168deg, #c3e5f7 0%, #91cce9 34%, #57a6cf 62%, #2a6f9c 100%)`,
  dark: `
      radial-gradient(48% 38% at 83% 79%, rgba(122, 88, 192, .55), rgba(122, 88, 192, 0) 72%),
      radial-gradient(58% 44% at 13% 87%, rgba(26, 122, 142, .46), rgba(26, 122, 142, 0) 70%),
      radial-gradient(70% 54% at 45% 5%, rgba(72, 86, 132, .5), rgba(72, 86, 132, 0) 74%),
      linear-gradient(170deg, #0b0f1a 0%, #131a2b 44%, #090c14 100%)`,
};

/// DEV-only stand-in for the DWM acrylic backdrop. Chromium cannot produce the
/// system material in a plain tab, so the simulation puts a blurred wallpaper
/// *behind* the document. The popover's own
/// translucent layers then composite over a blurred desktop exactly the way
/// they do on a real Windows 11 machine, which is the only way to judge them by
/// eye. Production never reaches this: popover.jsx calls it behind
/// import.meta.env.DEV, so the whole thing is dropped from the build.
export function installAcrylicPreviewBackdrop({ globalObject = globalThis } = {}) {
  const doc = globalObject.document;
  if (!doc?.body || doc.getElementById(WALLPAPER_ID)) return undefined;
  const requested = new URLSearchParams(globalObject.location?.search || "").get("wallpaper");
  const wallpaper = requested === "dark" ? "dark" : "bright";
  const style = doc.createElement("style");
  // Inset past the viewport so the blur radius has real pixels to sample at the
  // edges instead of fading the wallpaper out into the transparent canvas.
  style.textContent = `
    #${WALLPAPER_ID} {
      position: fixed;
      z-index: -1;
      inset: -48px;
      filter: blur(26px) saturate(1.08);
      pointer-events: none;
    }
    #${WALLPAPER_ID}[data-wallpaper="bright"] { background: ${PREVIEW_WALLPAPERS.bright}; }
    #${WALLPAPER_ID}[data-wallpaper="dark"] { background: ${PREVIEW_WALLPAPERS.dark}; }
  `;
  const node = doc.createElement("div");
  node.id = WALLPAPER_ID;
  node.dataset.wallpaper = wallpaper;
  doc.head.append(style);
  doc.body.prepend(node);
  return wallpaper;
}

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
    reducedMotion: false,
    floatingWidgetEnabled: false,
    backgroundDepth: 0,
    showFableQuota: true,
    showCodexSparkQuota: false,
    showAntigravityThirdPartyQuota: false,
    languagePreference: "system",
    popoverGlassStyle: "frosted",
    popoverBackdropOpacity: 0.62,
    systemLocale: "en",
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
        extraUsage: { spentUSD: 12.5, monthlyLimitUSD: 50 },
        scopedWindows: [
          {
            scopeID: "fable",
            displayName: "Fable",
            window: { usedPercent: 72, windowMinutes: 10_080, resetsAt: now + 3 * DAY_MS + 4 * HOUR_MS },
          },
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
        codexResetCredits: { availableCount: 2 },
        scopedWindows: [{
          scopeID: "codex_bengalfox",
          displayName: "GPT-5.3-Codex-Spark",
          window: { usedPercent: 35, windowMinutes: 10_080, resetsAt: now + 5 * DAY_MS },
        }],
      },
    ],
    dailyUsageHistory: { sourceDay: dayKey(now), capturedAt: now - 3 * MINUTE_MS, days },
    localUsage: {
      hasLocal: true,
      hasRemote: true,
      capturedAt: now - 3 * MINUTE_MS,
      source: "This PC + paired Mac",
      pricing: { capturedAt: now - HOUR_MS, modelCount: 2_742, refreshIntervalHours: 6 },
    },
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
  const parameters = new URLSearchParams(globalObject.location?.search || "");
  const language = parameters.get("lang");
  // `glass` and `opacity` stand in for the two appearance preferences so a
  // reviewer can land straight on the combination they want to look at instead
  // of driving the panel by hand for every screenshot.
  const opacity = Number.parseFloat(parameters.get("opacity"));
  state = {
    ...state,
    backgroundDepth: Number.isFinite(Number.parseFloat(parameters.get("depth")))
      ? Math.min(1, Math.max(0, Number.parseFloat(parameters.get("depth"))))
      : state.backgroundDepth,
    languagePreference: language || "system",
    systemLocale: parameters.get("systemLocale") || globalObject.navigator?.language || "en",
    popoverGlassStyle: parameters.get("glass") === "clear" ? "clear" : state.popoverGlassStyle,
    popoverBackdropOpacity: Number.isFinite(opacity) ? opacity : state.popoverBackdropOpacity,
  };
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
    setLanguage: async (value) => {
      emitState({ ...state, languagePreference: value });
      record("setLanguage", value);
    },
    setPopoverGlassStyle: async (value) => {
      emitState({ ...state, popoverGlassStyle: value });
      record("setPopoverGlassStyle", value);
    },
    setPopoverBackdropOpacity: async (value) => {
      emitState({ ...state, popoverBackdropOpacity: value });
      record("setPopoverBackdropOpacity", value);
    },
    relaunch: async () => record("relaunch"),
    quit: async () => record("quit"),
    openDashboard: async (section) => record("openDashboard", section),
    openExternal: async (url) => record("openExternal", String(url)),
    openCodexUsage: async (url) => record("openCodexUsage", String(url)),
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
