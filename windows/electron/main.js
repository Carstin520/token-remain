import { app, BrowserWindow, clipboard, ipcMain, Menu, nativeImage, net, safeStorage, screen, shell, Tray } from "electron";
import { hostname, release } from "node:os";
import { join } from "node:path";
import { fetchCuratedFeed, isAllowedPostURL } from "./feed.js";
import { ccusageBinaryPath, collectLocalUsage, mergeDailyUsageHistories } from "./local-usage.js";
import {
  clampPopoverHeight,
  isRect,
  POPOVER_INITIAL_HEIGHT,
  POPOVER_WIDTH,
  prefersAcrylic,
  resolveFloatingPopoverBounds,
  resolvePopoverBounds,
} from "./popover-placement.js";
import { PublicPricingService } from "./pricing.js";
import { MANUAL_PROVIDER_IDS, normalizeProviderIDs, PROVIDER_CATALOG, PROVIDER_ID_SET } from "./providers/catalog.js";
import { detectLocalProviders } from "./providers/detection.js";
import { collectEnabledProviders } from "./providers/index.js";
import { StateStore } from "./state-store.js";
import { makeSnapshot } from "./sync/crypto.js";
import { exchangeSnapshot, pairWithMac } from "./sync/client.js";
import { mergeLocalFirstProviders, mergeProviders } from "../src/provider-meta.js";
import { activateLanguage, tr } from "../src/i18n.js";

const REFRESH_INTERVAL_MS = 60_000;
/// A tray double-click arrives as click + double-click. Holding the popover
/// toggle for this long lets the second click cancel it, so opening the
/// dashboard never flashes the popover first.
const TRAY_DOUBLE_CLICK_GRACE_MS = 250;
/// Clicking the tray while the popover is open blurs it before the click event
/// arrives. Within this window the click counts as the dismissal instead of
/// immediately reopening what the user just closed.
const TRAY_REOPEN_GUARD_MS = 320;
/// Lets the renderer finish the short retract animation before the native
/// window is hidden. Keeping this below the tray guard makes repeated clicks
/// feel immediate without flashing the popover back open.
const POPOVER_EXIT_ANIMATION_MS = 180;
const DASHBOARD_SECTIONS = new Set(["overview", "limits", "trends", "devices", "dataSources", "settings"]);
const MAX_POPOVER_CONTENT_HEIGHT = 4_000;
const FLOATING_WIDGET_WIDTH = 80;
const FLOATING_WIDGET_HEIGHT = 80;

let mainWindow;
let popoverWindow;
let floatingWidgetWindow;
let store;
let refreshPromise;
let refreshTimer;
let tray;
let isQuitting = false;
let trayToggleTimer;
let popoverHiddenAt = 0;
let popoverHideTimer;
let popoverClosing = false;
let popoverContentHeight = POPOVER_INITIAL_HEIGHT;
let popoverAnchorBounds;
let popoverAnchorKind = "tray";
let floatingBoundsSaveTimer;
let pricingService;

if (!app.requestSingleInstanceLock()) app.quit();

app.on("second-instance", () => {
  if (app.isReady()) openDashboard();
});

app.whenReady().then(async () => {
  app.setAppUserModelId("com.jamesli.tokenremain.windows");
  store = new StateStore({ userDataPath: app.getPath("userData"), safeStorage });
  await store.load();
  activateLanguage(store.state.preferences?.language, app.getLocale());
  scanInstalledProviders();
  pricingService = new PublicPricingService({
    cacheDirectory: join(app.getPath("userData"), "pricing"),
    fetchImpl: (url, options) => net.fetch(url, options),
  });
  registerIPC();
  createWindow();
  createPopoverWindow();
  createTray();
  if (store.state.preferences?.floatingWidgetEnabled) showFloatingWidget();
  await refreshAll();
  refreshTimer = setInterval(refreshAll, REFRESH_INTERVAL_MS);
});

app.on("activate", () => {
  if (!mainWindow || mainWindow.isDestroyed()) createWindow();
});

app.on("window-all-closed", () => {
  if (process.platform !== "win32") app.quit();
});

app.on("before-quit", () => {
  isQuitting = true;
  clearInterval(refreshTimer);
  clearTimeout(trayToggleTimer);
  clearTimeout(popoverHideTimer);
  clearTimeout(floatingBoundsSaveTimer);
});

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1180,
    height: 780,
    minWidth: 920,
    minHeight: 640,
    backgroundColor: "#101116",
    title: "TokenRemain",
    icon: iconPath(),
    show: false,
    ...(process.platform === "win32" ? {
      titleBarStyle: "hidden",
      titleBarOverlay: { color: "#101114", symbolColor: "#a7abb4", height: 32 },
    } : {}),
    webPreferences: {
      preload: join(import.meta.dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      devTools: !app.isPackaged,
    },
  });
  mainWindow.setMenu(null);
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  mainWindow.webContents.on("will-navigate", (event) => event.preventDefault());
  mainWindow.on("close", (event) => {
    if (process.platform === "win32" && !isQuitting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });
  mainWindow.loadFile(join(import.meta.dirname, "../dist/index.html"));
  mainWindow.once("ready-to-show", () => mainWindow.show());
}

/// The Watch complication's circular remaining-rings surface, adapted as a
/// small always-on-top Windows shortcut. The renderer is alpha-transparent;
/// only the circular rings and their subtle glass hit target are painted.
function createFloatingWidgetWindow() {
  if (floatingWidgetWindow && !floatingWidgetWindow.isDestroyed()) return floatingWidgetWindow;
  floatingWidgetWindow = new BrowserWindow({
    ...floatingWidgetBounds(),
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    resizable: false,
    maximizable: false,
    minimizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: false,
    title: "TokenRemain Floating Shortcut",
    icon: iconPath(),
    webPreferences: {
      preload: join(import.meta.dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      devTools: !app.isPackaged,
    },
  });
  floatingWidgetWindow.setMenu(null);
  floatingWidgetWindow.setAlwaysOnTop(true, "floating");
  floatingWidgetWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  floatingWidgetWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  floatingWidgetWindow.webContents.on("will-navigate", (event) => event.preventDefault());
  floatingWidgetWindow.webContents.on("context-menu", () => {
    Menu.buildFromTemplate([
      { label: tr("Open Quick View"), click: () => openPopover(floatingWidgetWindow?.getBounds(), "floating") },
      { label: tr("Open Dashboard"), click: () => openDashboard("overview") },
      { type: "separator" },
      { label: tr("Hide Floating Shortcut"), click: () => { setFloatingWidgetEnabled(false).catch(() => {}); } },
    ]).popup({ window: floatingWidgetWindow });
  });
  floatingWidgetWindow.on("moved", scheduleFloatingBoundsSave);
  floatingWidgetWindow.on("close", (event) => {
    if (isQuitting) return;
    event.preventDefault();
    setFloatingWidgetEnabled(false).catch(() => {});
  });
  floatingWidgetWindow.loadFile(join(import.meta.dirname, "../dist/floating.html"));
  return floatingWidgetWindow;
}

function floatingWidgetBounds() {
  const stored = store.state.preferences?.floatingWidgetBounds;
  const candidate = isRect(stored)
    ? { x: stored.x, y: stored.y, width: FLOATING_WIDGET_WIDTH, height: FLOATING_WIDGET_HEIGHT }
    : undefined;
  if (candidate) {
    const workArea = screen.getDisplayMatching(candidate).workArea;
    const overlaps = candidate.x < workArea.x + workArea.width
      && candidate.x + candidate.width > workArea.x
      && candidate.y < workArea.y + workArea.height
      && candidate.y + candidate.height > workArea.y;
    if (overlaps) return candidate;
  }
  const workArea = screen.getPrimaryDisplay().workArea;
  return {
    x: workArea.x + workArea.width - FLOATING_WIDGET_WIDTH - 18,
    y: workArea.y + 72,
    width: FLOATING_WIDGET_WIDTH,
    height: FLOATING_WIDGET_HEIGHT,
  };
}

function scheduleFloatingBoundsSave() {
  clearTimeout(floatingBoundsSaveTimer);
  floatingBoundsSaveTimer = setTimeout(() => {
    const bounds = floatingWidgetWindow?.getBounds();
    if (bounds) store.setFloatingWidgetBounds(bounds).catch(() => {});
  }, 250);
}

function showFloatingWidget() {
  const window = createFloatingWidgetWindow();
  window.showInactive();
  window.setAlwaysOnTop(true, "floating");
}

async function setFloatingWidgetEnabled(enabled) {
  await store.setFloatingWidgetEnabled(enabled);
  if (enabled) showFloatingWidget();
  else if (floatingWidgetWindow && !floatingWidgetWindow.isDestroyed()) floatingWidgetWindow.hide();
  updateTrayContextMenu();
  notifyRenderer();
  return publicState();
}

/// The tray popover: one reused window that is hidden, never destroyed, so a
/// click always paints the cached state instead of booting a renderer.
function createPopoverWindow() {
  const acrylic = prefersAcrylic(process.platform, release());
  popoverWindow = new BrowserWindow({
    width: POPOVER_WIDTH,
    height: POPOVER_INITIAL_HEIGHT,
    show: false,
    frame: false,
    resizable: false,
    movable: false,
    maximizable: false,
    minimizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: true,
    acceptFirstMouse: true,
    transparent: true,
    // The renderer owns the rounded opaque fallback; the native window stays
    // transparent so its corners and scale animation never reveal a black box.
    backgroundColor: "#00000000",
    ...(acrylic ? { backgroundMaterial: "acrylic" } : {}),
    title: "TokenRemain",
    icon: iconPath(),
    webPreferences: {
      preload: join(import.meta.dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      devTools: !app.isPackaged,
    },
  });
  popoverWindow.setMenu(null);
  popoverWindow.setAlwaysOnTop(true, "pop-up-menu");
  popoverWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  popoverWindow.webContents.on("will-navigate", (event) => event.preventDefault());
  popoverWindow.on("blur", () => {
    if (popoverWindow.webContents.isDevToolsOpened()) return;
    hidePopover({ dismissedByClick: true });
  });
  popoverWindow.on("close", (event) => {
    if (isQuitting) return;
    event.preventDefault();
    hidePopover();
  });
  popoverWindow.loadFile(
    join(import.meta.dirname, "../dist/popover.html"),
    acrylic ? { search: "material=acrylic" } : undefined,
  );
}

function showPopover(anchorBounds, anchorKind = "tray") {
  if (!popoverWindow || popoverWindow.isDestroyed()) createPopoverWindow();
  clearTimeout(popoverHideTimer);
  popoverHideTimer = undefined;
  popoverClosing = false;
  popoverAnchorKind = anchorKind;
  popoverAnchorBounds = usableTrayBounds(anchorBounds) || usableTrayBounds(tray?.getBounds?.());
  positionPopover();
  popoverWindow.show();
  popoverWindow.setAlwaysOnTop(true, "pop-up-menu");
  popoverWindow.focus();
  publishPopoverVisibility(true);
  popoverWindow.webContents.send("popover:shown");
}

function openPopover(anchorBounds, anchorKind) {
  const explicitAnchor = usableTrayBounds(anchorBounds);
  if (explicitAnchor) {
    showPopover(explicitAnchor, anchorKind || "tray");
    return;
  }
  const floatingAnchor = floatingWidgetWindow?.isVisible()
    ? usableTrayBounds(floatingWidgetWindow.getBounds())
    : undefined;
  if (floatingAnchor) showPopover(floatingAnchor, "floating");
  else showPopover(usableTrayBounds(tray?.getBounds?.()), "tray");
}

function hidePopover(options = {}) {
  if (!popoverWindow || popoverWindow.isDestroyed() || !popoverWindow.isVisible()) return;
  if (options.dismissedByClick) popoverHiddenAt = Date.now();
  if (popoverClosing) return;
  popoverClosing = true;
  publishPopoverVisibility(false);
  const finish = () => {
    popoverHideTimer = undefined;
    if (popoverWindow && !popoverWindow.isDestroyed()) popoverWindow.hide();
    popoverClosing = false;
  };
  if (options.immediate) finish();
  else popoverHideTimer = setTimeout(finish, POPOVER_EXIT_ANIMATION_MS);
}

function togglePopover(trayBounds) {
  const dismissedByThisClick = Date.now() - popoverHiddenAt < TRAY_REOPEN_GUARD_MS;
  if (dismissedByThisClick) return;
  if (popoverWindow?.isVisible() && !popoverClosing) hidePopover();
  else showPopover(trayBounds);
}

function togglePopoverFromFloating() {
  const dismissedByThisClick = Date.now() - popoverHiddenAt < TRAY_REOPEN_GUARD_MS;
  if (dismissedByThisClick) return;
  if (popoverWindow?.isVisible() && !popoverClosing) hidePopover();
  else showPopover(usableTrayBounds(floatingWidgetWindow?.getBounds?.()), "floating");
}

function publishPopoverVisibility(visible) {
  for (const target of [popoverWindow, floatingWidgetWindow]) {
    if (target && !target.isDestroyed()) target.webContents.send("popover:visibility", Boolean(visible));
  }
}

/// Keeps the popover next to its current tray or floating anchor and inside the
/// anchor display's work area, at whatever height the content currently needs.
function positionPopover() {
  if (!popoverWindow || popoverWindow.isDestroyed()) return;
  const display = popoverDisplay();
  const common = {
    display,
    width: POPOVER_WIDTH,
    height: clampPopoverHeight(popoverContentHeight, display),
  };
  const bounds = popoverAnchorKind === "floating"
    ? resolveFloatingPopoverBounds({ ...common, anchorBounds: popoverAnchorBounds })
    : resolvePopoverBounds({ ...common, trayBounds: popoverAnchorBounds });
  const current = popoverWindow.getBounds();
  if (current.x === bounds.x && current.y === bounds.y && current.width === bounds.width && current.height === bounds.height) return;
  popoverWindow.setBounds({ x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height });
}

function popoverDisplay() {
  const anchor = popoverAnchorBounds;
  const point = anchor
    ? { x: Math.round(anchor.x + anchor.width / 2), y: Math.round(anchor.y + anchor.height / 2) }
    : screen.getCursorScreenPoint();
  return screen.getDisplayNearestPoint(point);
}

/// Windows reports an empty or off-screen rectangle when the icon sits in the
/// collapsed overflow area; those anchors are dropped so placement falls back
/// to the work-area corner next to the taskbar.
function usableTrayBounds(bounds) {
  return isRect(bounds) && bounds.width > 0 && bounds.height > 0 ? bounds : undefined;
}

function createTray() {
  const image = nativeImage.createFromPath(iconPath()).resize({ width: 20, height: 20 });
  tray = new Tray(image);
  tray.setToolTip("TokenRemain");
  updateTrayContextMenu();
  tray.on("click", (_event, trayBounds) => {
    cancelTrayToggle();
    trayToggleTimer = setTimeout(() => {
      trayToggleTimer = undefined;
      togglePopover(trayBounds);
    }, TRAY_DOUBLE_CLICK_GRACE_MS);
  });
  tray.on("double-click", () => openDashboard("overview"));
}

function updateTrayContextMenu() {
  if (!tray) return;
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: tr("Open Quick View"), click: () => openPopover(usableTrayBounds(tray.getBounds()), "tray") },
    { label: tr("Open Dashboard"), click: () => openDashboard("overview") },
    { label: tr("Show Floating Shortcut"), type: "checkbox", checked: Boolean(store.state.preferences?.floatingWidgetEnabled), click: (item) => { setFloatingWidgetEnabled(item.checked).catch(() => {}); } },
    { label: tr("Refresh now"), click: () => { refreshAll().catch(() => {}); } },
    { label: tr("Settings"), click: () => openDashboard("settings") },
    { type: "separator" },
    { label: tr("Quit"), click: () => { isQuitting = true; app.quit(); } },
  ]));
}

function cancelTrayToggle() {
  clearTimeout(trayToggleTimer);
  trayToggleTimer = undefined;
}

function openDashboard(section) {
  cancelTrayToggle();
  hidePopover();
  if (!mainWindow || mainWindow.isDestroyed()) createWindow();
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
  if (section) sendToDashboard("navigate:section", section);
}

function sendToDashboard(channel, payload) {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (!mainWindow.webContents.isLoading()) {
    mainWindow.webContents.send(channel, payload);
    return;
  }
  mainWindow.webContents.once("did-finish-load", () => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(channel, payload);
  });
}

function iconPath() {
  return app.isPackaged
    ? join(process.resourcesPath, "appicon.png")
    : join(import.meta.dirname, "../../site/assets/brand/appicon-mac.png");
}

function registerIPC() {
  ipcMain.handle("state:get", () => publicState());
  ipcMain.handle("usage:refresh", () => refreshAll());
  ipcMain.handle("onboarding:complete", async (_event, providerIDs) => {
    await store.completeOnboarding(normalizeProviderIDs(providerIDs));
    await refreshAfterMutation();
    return publicState();
  });
  ipcMain.handle("providers:rescan", async () => {
    scanInstalledProviders();
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("providers:set-enabled", async (_event, providerID, enabled) => {
    assertProviderID(providerID);
    await store.setProviderEnabled(providerID, Boolean(enabled));
    await refreshAfterMutation();
    return publicState();
  });
  ipcMain.handle("providers:set-credential", async (_event, providerID, value) => {
    assertProviderID(providerID);
    if (!MANUAL_PROVIDER_IDS.has(providerID)) throw new Error("This provider uses its own local sign-in");
    await store.setProviderSecret(providerID, boundedString(value, 32 * 1024, "Credential"));
    if (!store.state.enabledProviders.includes(providerID)) await store.setProviderEnabled(providerID, true);
    scanInstalledProviders();
    await refreshAfterMutation();
    return publicState();
  });
  ipcMain.handle("providers:clear-credential", async (_event, providerID) => {
    assertProviderID(providerID);
    if (!MANUAL_PROVIDER_IDS.has(providerID)) throw new Error("This provider uses its own local sign-in");
    await store.clearProviderSecret(providerID);
    scanInstalledProviders();
    await refreshAfterMutation();
    return publicState();
  });
  ipcMain.handle("sync:pair", async (_event, input) => {
    const macURL = boundedString(input?.macURL, 512, "Mac address");
    const pairingCode = boundedString(input?.pairingCode, 128, "Pairing code");
    const paired = await pairWithMac({
      macURL,
      pairingCode,
      sourceInstanceID: store.state.sourceInstanceID,
      deviceName: hostname(),
    });
    await store.setPairedMac(paired);
    await refreshAll();
    return publicState();
  });
  ipcMain.handle("sync:disconnect", async () => {
    await store.disconnect();
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("feed:open", async (_event, value) => {
    if (!isAllowedPostURL(value)) throw new Error("This feed link is not allowed");
    await shell.openExternal(value, { activate: true });
    return true;
  });
  ipcMain.handle("settings:set-launch-at-login", (_event, value) => {
    app.setLoginItemSettings({ openAtLogin: Boolean(value) });
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-floating-widget", (_event, value) => setFloatingWidgetEnabled(Boolean(value)));
  ipcMain.handle("settings:set-language", async (_event, value) => {
    await store.setLanguage(value);
    activateLanguage(store.state.preferences?.language, app.getLocale());
    updateTrayContextMenu();
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("popup:open", () => {
    openPopover();
    return publicState();
  });
  ipcMain.handle("popup:toggle-from-floating", (event) => {
    if (event.sender !== floatingWidgetWindow?.webContents) throw new Error("This action is only available from the floating shortcut");
    togglePopoverFromFloating();
    return true;
  });
  ipcMain.handle("app:relaunch", () => {
    isQuitting = true;
    app.relaunch();
    app.quit();
  });
  ipcMain.handle("app:quit", () => {
    isQuitting = true;
    app.quit();
  });
  ipcMain.handle("dashboard:open", (_event, section) => {
    openDashboard(DASHBOARD_SECTIONS.has(section) ? section : undefined);
    return true;
  });
  ipcMain.handle("clipboard:copy-text", (event, text) => {
    // Clipboard writes are reserved for the tray popover; every other window
    // (including the dashboard) is rejected.
    if (!popoverWindow || popoverWindow.isDestroyed() || event.sender !== popoverWindow.webContents) {
      throw new Error("Copy is only available from the popover");
    }
    clipboard.writeText(boundedString(text, 8192, "Copy text"));
    return true;
  });
  ipcMain.on("popover:hide", (event) => {
    if (event.sender === popoverWindow?.webContents) hidePopover();
  });
  ipcMain.on("popover:resize", (event, contentHeight) => {
    if (event.sender !== popoverWindow?.webContents) return;
    const requested = Number(contentHeight);
    if (!Number.isFinite(requested) || requested <= 0) return;
    popoverContentHeight = Math.min(MAX_POPOVER_CONTENT_HEIGHT, Math.ceil(requested));
    positionPopover();
  });
}

async function refreshAll() {
  if (refreshPromise) return refreshPromise;
  refreshPromise = performRefresh().finally(() => { refreshPromise = undefined; });
  return refreshPromise;
}

/// A first-launch click can race the refresh started during app boot. Wait for
/// that read to settle, then run once with the newly selected providers instead
/// of returning the now-obsolete in-flight result.
async function refreshAfterMutation() {
  const inFlight = refreshPromise;
  if (inFlight) await inFlight;
  return refreshAll();
}

async function performRefresh() {
  store.state.isRefreshing = true;
  store.state.feedLoading = !store.state.trending?.length;
  notifyRenderer();
  // Electron's net stack follows the Windows system proxy. Node's global
  // fetch does not, which made a valid Codex login look like a quota timeout.
  const windowsFetch = (url, options) => net.fetch(url, options);
  const enabledProviders = store.state.onboardingCompleted ? store.state.enabledProviders : [];
  const results = await Promise.allSettled([
    collectEnabledProviders(enabledProviders, {
      fetchImpl: windowsFetch,
      getStoredSecret: (providerID) => store.getProviderSecret(providerID),
    }),
    fetchCuratedFeed(),
    collectWindowsLocalUsage(),
  ]);
  const providerResult = results[0];
  const providers = providerResult.status === "fulfilled" ? providerResult.value.providers : [];
  const notices = providerResult.status === "fulfilled"
    ? Object.fromEntries(Object.entries(providerResult.value.notices).map(([providerID, message]) => [providerID, publicError(message)]))
    : { local: publicError(providerResult.reason) };
  // A transient network failure must not erase the last successful provider
  // snapshot. Its notice and captured-at age tell the UI that it is stale.
  const retained = (store.state.providers || []).filter((provider) => enabledProviders.includes(provider.providerID));
  store.state.providers = mergeProviders(providers, retained);
  store.state.notices = notices;

  const feedResult = results[1];
  if (feedResult.status === "fulfilled") {
    store.state.trending = feedResult.value;
    store.state.feedUpdatedAt = Date.now();
    delete store.state.feedError;
  } else {
    store.state.feedError = publicError(feedResult.reason);
  }
  store.state.feedLoading = false;

  const localUsageResult = results[2];
  if (localUsageResult.status === "fulfilled") {
    store.setLocalDailyUsageHistory(localUsageResult.value);
    store.state.lastLocalUsageAt = Date.now();
    delete store.state.localUsageError;
  } else {
    store.state.localUsageError = publicError(localUsageResult.reason);
  }

  try {
    const paired = store.getPairedMac();
    if (paired) {
      store.state.sequence = Math.min(Number.MAX_SAFE_INTEGER, (store.state.sequence || 0) + 1);
      const snapshot = makeSnapshot({
        sourceInstanceID: store.state.sourceInstanceID,
        sequence: store.state.sequence,
        providers: store.state.providers,
      });
      const remoteSnapshot = await exchangeSnapshot({
        ...paired,
        expectedSourceInstanceID: paired.serverSourceInstanceID,
        lastRemoteSequence: paired.lastRemoteSequence,
        snapshot,
      });
      store.setRemoteSnapshot(remoteSnapshot);
      store.state.pairedMac.lastRemoteSequence = remoteSnapshot.sequence;
      store.state.lastSyncAt = Date.now();
      delete store.state.syncError;
    }
  } catch (error) {
    store.state.syncError = publicError(error);
  }
  scanInstalledProviders();
  store.recordQuotaUsage(mergeLocalFirstProviders(store.state.providers || [], store.state.remoteSnapshot?.providers || []));
  store.state.lastUpdatedAt = Date.now();
  store.state.isRefreshing = false;
  await store.save();
  updateTrayTooltip();
  notifyRenderer();
  return publicState();
}

/// Mirrors the Mac menu-bar readout in the Windows tray tooltip:
/// "Claude 57% · Codex 37%" for the providers with live quota.
function updateTrayTooltip() {
  if (!tray) return;
  const summaries = publicState().providers.flatMap((provider) => {
    const rolling = (provider.windows || []).filter((window) => window.windowMinutes > 0);
    const window = rolling.reduce(
      (current, candidate) => (!current || candidate.windowMinutes < current.windowMinutes ? candidate : current),
      undefined,
    ) || provider.windows?.[0];
    if (!window || !Number.isFinite(window.usedPercent)) return [];
    const name = provider.providerID.charAt(0).toUpperCase() + provider.providerID.slice(1);
    return [`${name} ${Math.round(Math.min(100, Math.max(0, 100 - window.usedPercent)))}%`];
  });
  tray.setToolTip(summaries.length ? `TokenRemain — ${summaries.slice(0, 4).join(" · ")}` : "TokenRemain");
}

function publicState() {
  const paired = store?.state?.pairedMac;
  const localDailyUsageHistory = store?.state?.localDailyUsageHistory;
  const remoteDailyUsageHistory = store?.state?.remoteSnapshot?.dailyUsageHistory;
  const dailyUsageHistory = mergeDailyUsageHistories(localDailyUsageHistory, remoteDailyUsageHistory);
  const pricing = pricingService?.getStatus();
  const providerDetections = store?.state?.providerDetections || [];
  const enabledProviders = normalizeProviderIDs(store?.state?.enabledProviders);
  return {
    sourceInstanceID: store?.state?.sourceInstanceID,
    deviceName: hostname(),
    appVersion: app.getVersion(),
    launchAtLogin: Boolean(app.getLoginItemSettings().openAtLogin),
    floatingWidgetEnabled: Boolean(store?.state?.preferences?.floatingWidgetEnabled),
    languagePreference: store?.state?.preferences?.language || "system",
    systemLocale: app.getLocale(),
    onboarding: {
      completed: Boolean(store?.state?.onboardingCompleted),
      detections: providerDetections,
    },
    providerCatalog: PROVIDER_CATALOG.map((definition) => {
      const detection = providerDetections.find((item) => item.providerID === definition.id);
      return {
        id: definition.id,
        access: definition.access,
        product: definition.product,
        localSessionFirst: Boolean(definition.localSessionFirst),
        credentialKind: definition.credentialKind,
        installed: Boolean(detection?.installed),
        configured: Boolean(detection?.configured),
        detail: detection?.detail,
        enabled: enabledProviders.includes(definition.id),
      };
    }),
    enabledProviders,
    providers: mergeLocalFirstProviders(store?.state?.providers || [], store?.state?.remoteSnapshot?.providers || []),
    localProviders: store?.state?.providers || [],
    notices: store?.state?.notices || {},
    lastUpdatedAt: store?.state?.lastUpdatedAt,
    isRefreshing: Boolean(store?.state?.isRefreshing),
    dailyUsageHistory,
    localUsage: {
      hasLocal: Boolean(localDailyUsageHistory),
      hasRemote: Boolean(remoteDailyUsageHistory),
      capturedAt: dailyUsageHistory?.capturedAt,
      source: localDailyUsageHistory && remoteDailyUsageHistory
        ? "This PC + paired Mac"
        : localDailyUsageHistory ? "This PC" : remoteDailyUsageHistory ? "Paired Mac" : undefined,
      error: store?.state?.localUsageError,
      pricing,
    },
    quotaUsageHistory: store?.state?.quotaUsageHistory,
    trending: store?.state?.trending || [],
    feedLoading: Boolean(store?.state?.feedLoading),
    feedError: store?.state?.feedError,
    feedUpdatedAt: store?.state?.feedUpdatedAt,
    sync: {
      paired: Boolean(paired),
      macURL: paired?.baseURL,
      deviceName: paired?.deviceName,
      lastSyncAt: store?.state?.lastSyncAt,
      error: store?.state?.syncError,
      encryption: paired ? "AES-256-GCM" : undefined,
    },
  };
}

function scanInstalledProviders() {
  store.state.providerDetections = detectLocalProviders({
    hasStoredSecret: (providerID) => store.hasProviderSecret(providerID),
  });
  return store.state.providerDetections;
}

function assertProviderID(providerID) {
  if (!PROVIDER_ID_SET.has(providerID)) throw new Error("Unsupported provider");
}

async function collectWindowsLocalUsage() {
  const pricingConfigurationPath = await pricingService.configurationPath();
  return collectLocalUsage({
    binaryPath: ccusageBinaryPath({
      packaged: app.isPackaged,
      appPath: app.getAppPath(),
      resourcesPath: process.resourcesPath,
    }),
    pricingConfigurationPath,
  });
}

/// One refresh loop feeds both surfaces: the dashboard and the tray popover
/// always render the same snapshot.
function notifyRenderer() {
  const state = publicState();
  for (const target of [mainWindow, popoverWindow, floatingWidgetWindow]) {
    if (target && !target.isDestroyed()) target.webContents.send("state:changed", state);
  }
}

function boundedString(value, maximumBytes, label) {
  const text = String(value || "").trim();
  if (!text || Buffer.byteLength(text) > maximumBytes) throw new Error(`${label} is missing or too long`);
  return text;
}

function publicError(error) {
  const message = error instanceof Error ? error.message : String(error);
  return message.replace(/[\r\n\t]+/g, " ").slice(0, 240);
}
