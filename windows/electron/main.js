import { app, BrowserWindow, clipboard, ipcMain, Menu, nativeImage, net, Notification, powerMonitor, safeStorage, screen, shell, systemPreferences, Tray } from "electron";
import { hostname, release } from "node:os";
import { join } from "node:path";
import { fetchCuratedFeed, isAllowedPostURL } from "./feed.js";
import { isAllowedCodexUsageURL } from "./codex-usage.js";
import { applyDragDelta } from "./floating-drag.js";
import { DASHBOARD_SECTIONS, parseLaunchArgs } from "./launch-args.js";
import { aggregateLocalUsageHistories, ccusageBinaryPath, collectLocalUsage, mergeDailyUsageHistories } from "./local-usage.js";
import { decideProviderNotifications, noticeFromError, selectFeedNotifications, truncateNotificationBody } from "./notification-policy.js";
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
import { ServiceStatusService } from "./service-status.js";
import { readWindowsReducedMotion, resolveReducedMotion } from "./system-motion.js";
import { MANUAL_PROVIDER_IDS, normalizeProviderIDs, PROVIDER_CATALOG, PROVIDER_ID_SET } from "./providers/catalog.js";
import { DESKTOP_APP_PROVIDER_IDS, detectLocalProviders, resolveProviderDesktopAppPath } from "./providers/detection.js";
import { collectEnabledProviders } from "./providers/index.js";
import { nextRefreshDelayMs, providerRetryState } from "./refresh-policy.js";
import { StateStore } from "./state-store.js";
import { pickTrayProviders, renderTrayIcon } from "./tray-icon.js";
import { applyWindowsChrome } from "./windows-chrome.js";
import { makeSnapshot } from "./sync/crypto.js";
import { exchangeSnapshot, pairWithMac } from "./sync/client.js";
import { compareVersionCores, fetchLatestRelease, isAllowedReleaseURL, isDue } from "./update-check.js";
import { mergeLocalFirstProviders, mergeProviders, providerMeta } from "../src/provider-meta.js";
import { activateLanguage, tr, trKey } from "../src/i18n.js";
import { detectedLocalUsageSources } from "../src/local-sources.js";

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
const MAX_POPOVER_CONTENT_HEIGHT = 4_000;
const FLOATING_WIDGET_WIDTH = 80;
const FLOATING_WIDGET_HEIGHT = 80;
const REDUCED_MOTION_POLL_MS = 60_000;
const INSTALLATION_DETECTION_POLL_MS = 5 * 60_000;

let mainWindow;
let popoverWindow;
let floatingWidgetWindow;
let store;
let refreshPromise;
let refreshTimer;
let refreshCadenceAnchorAt;
const providerRetryStates = new Map();
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
let floatingDragSession;
let reducedMotion = false;
let reducedMotionSources = { spi: undefined, electron: undefined };
let reducedMotionTimer;
let installationDetectionTimer;
let installationDetectionPromise;
let pricingService;
let serviceStatusService;
let pendingSecondInstanceLaunchArguments;
const initialLaunchArguments = parseLaunchArgs(process.argv);

if (!app.requestSingleInstanceLock()) app.quit();

app.on("second-instance", (_event, argv) => {
  const arguments_ = parseLaunchArgs(argv);
  if (app.isReady()) handleLaunchArguments(arguments_).catch(() => {});
  else pendingSecondInstanceLaunchArguments = arguments_;
});

app.whenReady().then(async () => {
  app.setAppUserModelId("com.jamesli.tokenremain.windows");
  store = new StateStore({ userDataPath: app.getPath("userData"), safeStorage });
  await store.load();
  if (initialLaunchArguments.resetOnboarding) await store.resetOnboarding();
  const initialMotion = readReducedMotionPreference();
  reducedMotion = initialMotion.value;
  reducedMotionSources = initialMotion.sources;
  activateLanguage(store.state.preferences?.language, app.getLocale());
  const initialDetectionSuggestions = await scanInstalledProviders({ announce: false });
  pricingService = new PublicPricingService({
    cacheDirectory: join(app.getPath("userData"), "pricing"),
    fetchImpl: (url, options) => net.fetch(url, options),
  });
  serviceStatusService = new ServiceStatusService({
    fetchImpl: (url, options) => net.fetch(url, options),
  });
  registerIPC();
  createWindow({
    showOnReady: initialLaunchArguments.target === "dashboard",
    initialSection: initialLaunchArguments.dashboardSection,
  });
  createPopoverWindow({
    openAppearanceOnFirstShow: initialLaunchArguments.target === "popover"
      && initialLaunchArguments.openPopupSettings,
  });
  createTray();
  if (initialDetectionSuggestions.length) openDashboard("limits");
  scheduleInstallationDetection();
  if (initialLaunchArguments.target === "popover") {
    showPopoverWhenReady({ appearanceOpen: initialLaunchArguments.openPopupSettings });
  }
  if (pendingSecondInstanceLaunchArguments) {
    await handleLaunchArguments(pendingSecondInstanceLaunchArguments);
    pendingSecondInstanceLaunchArguments = undefined;
  }
  if (store.state.preferences?.floatingWidgetEnabled) showFloatingWidget();
  powerMonitor.on("resume", () => {
    scheduleAutomaticRefresh();
    refreshReducedMotionPreference();
  });
  powerMonitor.on("user-did-become-active", () => {
    scheduleAutomaticRefresh();
    refreshReducedMotionPreference();
    scanInstalledProviders().catch(() => {}).finally(scheduleInstallationDetection);
  });
  app.on("accessibility-support-changed", refreshReducedMotionPreference);
  if (store.state.preferences?.refreshMinutes !== 0) await refreshAll();
  refreshCadenceAnchorAt = Date.now();
  scheduleAutomaticRefresh();
});

app.on("activate", () => {
  openDashboard("overview");
});

app.on("window-all-closed", () => {
  if (process.platform !== "win32") app.quit();
});

app.on("before-quit", () => {
  isQuitting = true;
  clearTimeout(refreshTimer);
  clearTimeout(trayToggleTimer);
  clearTimeout(popoverHideTimer);
  clearTimeout(floatingBoundsSaveTimer);
  clearTimeout(reducedMotionTimer);
  clearTimeout(installationDetectionTimer);
});

function createWindow({ showOnReady = false, initialSection } = {}) {
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
  mainWindow.setSkipTaskbar(Boolean(store.state.preferences?.taskbarIconHidden));
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  mainWindow.webContents.on("will-navigate", (event) => event.preventDefault());
  observeRefreshVisibility(mainWindow);
  observeReducedMotionPreference(mainWindow);
  mainWindow.on("close", (event) => {
    if (process.platform === "win32" && !isQuitting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });
  mainWindow.loadFile(
    join(import.meta.dirname, "../dist/index.html"),
    initialSection ? { search: `section=${encodeURIComponent(initialSection)}` } : undefined,
  );
  if (showOnReady) mainWindow.once("ready-to-show", () => mainWindow.show());
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
  observeRefreshVisibility(floatingWidgetWindow);
  observeReducedMotionPreference(floatingWidgetWindow);
  floatingWidgetWindow.webContents.on("context-menu", () => {
    Menu.buildFromTemplate([
      { label: tr("Open Quick View"), click: () => openPopover(floatingWidgetWindow?.getBounds(), "floating") },
      { label: tr("Open Dashboard"), click: () => openDashboard("overview") },
      { type: "separator" },
      { label: tr("Hide Floating Shortcut"), click: () => { setFloatingWidgetEnabled(false).catch(() => {}); } },
    ]).popup({ window: floatingWidgetWindow });
  });
  floatingWidgetWindow.on("moved", () => {
    if (!floatingDragSession) scheduleFloatingBoundsSave();
  });
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
  const recovered = candidate && applyDragDelta(candidate, { dx: 0, dy: 0 }, floatingWorkAreas());
  if (recovered) return recovered;
  const workArea = screen.getPrimaryDisplay().workArea;
  return {
    x: workArea.x + workArea.width - FLOATING_WIDGET_WIDTH - 18,
    y: workArea.y + 72,
    width: FLOATING_WIDGET_WIDTH,
    height: FLOATING_WIDGET_HEIGHT,
  };
}

function floatingWorkAreas() {
  return screen.getAllDisplays().map((display) => display.workArea);
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
function createPopoverWindow({ openAppearanceOnFirstShow = false } = {}) {
  const acrylic = prefersAcrylic(process.platform, release());
  popoverWindow = new BrowserWindow({
    width: POPOVER_WIDTH,
    height: POPOVER_INITIAL_HEIGHT,
    show: false,
    frame: false,
    roundedCorners: true,
    resizable: false,
    movable: false,
    maximizable: false,
    minimizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: true,
    acceptFirstMouse: true,
    transparent: !acrylic,
    // backgroundMaterial is locked at creation on Windows. Changing material
    // later would require rebuilding the window rather than toggling in place.
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
  applyWindowsChrome(popoverWindow, { round: true });
  popoverWindow.setMenu(null);
  popoverWindow.setAlwaysOnTop(true, "pop-up-menu");
  popoverWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  popoverWindow.webContents.on("will-navigate", (event) => event.preventDefault());
  observeRefreshVisibility(popoverWindow);
  observeReducedMotionPreference(popoverWindow);
  popoverWindow.on("blur", () => {
    if (popoverWindow.webContents.isDevToolsOpened()) return;
    hidePopover({ dismissedByClick: true });
  });
  popoverWindow.on("close", (event) => {
    if (isQuitting) return;
    event.preventDefault();
    hidePopover();
  });
  const search = new URLSearchParams();
  if (acrylic) search.set("material", "acrylic");
  if (openAppearanceOnFirstShow) search.set("appearance", "1");
  popoverWindow.loadFile(join(import.meta.dirname, "../dist/popover.html"), (
    search.size ? { search: search.toString() } : undefined
  ));
}

function showPopover(anchorBounds, anchorKind = "tray", options = {}) {
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
  popoverWindow.webContents.send("popover:shown", { appearanceOpen: options.appearanceOpen === true });
}

function openPopover(anchorBounds, anchorKind, options = {}) {
  const explicitAnchor = usableTrayBounds(anchorBounds);
  if (explicitAnchor) {
    showPopover(explicitAnchor, anchorKind || "tray", options);
    return;
  }
  const floatingAnchor = floatingWidgetWindow?.isVisible()
    ? usableTrayBounds(floatingWidgetWindow.getBounds())
    : undefined;
  if (floatingAnchor) showPopover(floatingAnchor, "floating", options);
  else showPopover(usableTrayBounds(tray?.getBounds?.()), "tray", options);
}

function showPopoverWhenReady(options = {}) {
  if (!popoverWindow || popoverWindow.isDestroyed()) createPopoverWindow();
  const show = () => openPopover(undefined, undefined, options);
  if (popoverWindow.webContents.isLoading()) popoverWindow.webContents.once("did-finish-load", show);
  else show();
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
  if (options.immediate || reducedMotion) finish();
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
  updateTrayTooltip();
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
    { label: tr("Refresh now"), click: () => { refreshManually().catch(() => {}); } },
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

async function handleLaunchArguments(arguments_) {
  if (arguments_.resetOnboarding) {
    await store.resetOnboarding();
    notifyRenderer();
  }
  if (arguments_.target === "popover") {
    showPopoverWhenReady({ appearanceOpen: arguments_.openPopupSettings });
    return;
  }
  openDashboard(arguments_.dashboardSection);
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
  ipcMain.handle("usage:refresh", () => refreshManually());
  ipcMain.handle("onboarding:complete", async (_event, providerIDs) => {
    await store.completeOnboarding(normalizeProviderIDs(providerIDs));
    await refreshAfterMutation();
    return publicState();
  });
  ipcMain.handle("providers:rescan", async () => {
    await scanInstalledProviders();
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
    await scanInstalledProviders();
    await refreshAfterMutation();
    return publicState();
  });
  ipcMain.handle("providers:clear-credential", async (_event, providerID) => {
    assertProviderID(providerID);
    if (!MANUAL_PROVIDER_IDS.has(providerID)) throw new Error("This provider uses its own local sign-in");
    await store.clearProviderSecret(providerID);
    await scanInstalledProviders();
    await refreshAfterMutation();
    return publicState();
  });
  ipcMain.handle("providers:accept-detection", async (_event, providerID) => {
    assertProviderID(providerID);
    const first = store.state.pendingDetectionSuggestions?.[0];
    if (!first || first.providerID !== providerID) throw new Error("Detection suggestion is no longer available");
    await store.setProviderEnabled(providerID, true);
    await refreshAfterMutation();
    return publicState();
  });
  ipcMain.handle("providers:dismiss-detection", (_event, providerID) => {
    assertProviderID(providerID);
    store.dismissDetectionSuggestion(providerID);
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("providers:open-app", async (_event, providerID) => {
    if (!DESKTOP_APP_PROVIDER_IDS.has(providerID)) throw new Error("Unsupported provider app");
    const executablePath = resolveProviderDesktopAppPath(providerID);
    if (!executablePath) throw new Error("The installed desktop app could not be found");
    const launchError = await shell.openPath(executablePath);
    if (launchError) throw new Error(publicError(launchError));
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
    await refreshManually();
    return publicState();
  });
  ipcMain.handle("sync:disconnect", async () => {
    await store.disconnect();
    updateTrayTooltip();
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("feed:open", async (_event, value) => {
    if (!isAllowedPostURL(value)) throw new Error("This feed link is not allowed");
    await shell.openExternal(value, { activate: true });
    return true;
  });
  ipcMain.handle("codex:usage-open", async (_event, value) => {
    if (!isAllowedCodexUsageURL(value)) throw new Error("This Codex usage link is not allowed");
    await shell.openExternal(value, { activate: true });
    return true;
  });
  ipcMain.handle("update:open", async (_event, value) => {
    if (!isAllowedReleaseURL(value)) throw new Error("This update link is not allowed");
    await shell.openExternal(value, { activate: true });
    return true;
  });
  ipcMain.handle("settings:set-launch-at-login", (_event, value) => {
    app.setLoginItemSettings({ openAtLogin: Boolean(value) });
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-floating-widget", (_event, value) => setFloatingWidgetEnabled(Boolean(value)));
  ipcMain.handle("settings:set-background-depth", async (_event, value) => {
    await store.setBackgroundDepth(value);
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-taskbar-icon-hidden", async (_event, value) => {
    await store.setTaskbarIconHidden(value === true);
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.setSkipTaskbar(value === true);
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-zai-region", async (_event, value) => {
    await store.setZAIRegion(value);
    await refreshAfterMutation();
    return publicState();
  });
  ipcMain.handle("settings:set-feed-notifications", async (_event, value) => {
    await store.setFeedNotificationsEnabled(value === true);
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-local-usage-source-enabled", async (_event, id, enabled) => {
    await store.setLocalUsageSourceEnabled(id, enabled === true);
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-scoped-pool-visibility", async (_event, key, value) => {
    await store.setScopedPoolVisibility(key, value);
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-summary-strategy", async (_event, value) => {
    await store.setSummaryStrategy(value);
    updateTrayTooltip();
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-popover-glass-style", async (_event, value) => {
    await store.setPopoverGlassStyle(value);
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-popover-backdrop-opacity", async (_event, value) => {
    await store.setPopoverBackdropOpacity(value);
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-tray-display-mode", async (_event, value) => {
    await store.setTrayDisplayMode(value);
    updateTrayTooltip();
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-tray-providers", async (_event, value) => {
    await store.setTrayProviders(value);
    updateTrayTooltip();
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-language", async (_event, value) => {
    await store.setLanguage(value);
    activateLanguage(store.state.preferences?.language, app.getLocale());
    updateTrayContextMenu();
    notifyRenderer();
    return publicState();
  });
  ipcMain.handle("settings:set-refresh-minutes", async (_event, value) => {
    await store.setRefreshMinutes(value);
    refreshCadenceAnchorAt = Date.now();
    scheduleAutomaticRefresh();
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
  ipcMain.handle("floating:drag-start", (event) => {
    assertFloatingWidgetSender(event);
    clearTimeout(floatingBoundsSaveTimer);
    floatingDragSession = { bounds: floatingWidgetWindow.getBounds() };
    return true;
  });
  ipcMain.handle("floating:drag-move", (event, delta) => {
    assertFloatingWidgetSender(event);
    if (!floatingDragSession) return false;
    const bounds = applyDragDelta(floatingDragSession.bounds, delta, floatingWorkAreas());
    if (bounds) floatingWidgetWindow.setBounds(bounds);
    return Boolean(bounds);
  });
  ipcMain.handle("floating:drag-end", (event) => {
    assertFloatingWidgetSender(event);
    if (!floatingDragSession) return false;
    floatingDragSession = undefined;
    scheduleFloatingBoundsSave();
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

async function refreshAll(options) {
  if (refreshPromise) return refreshPromise;
  refreshPromise = performRefresh(options).finally(() => { refreshPromise = undefined; });
  return refreshPromise;
}

async function refreshManually() {
  clearTimeout(refreshTimer);
  refreshTimer = undefined;
  const inFlight = refreshPromise;
  if (inFlight) {
    try { await inFlight; } catch {}
  }
  try {
    return await refreshAll({ providerIDs: enabledProviderIDs(), includeSharedSources: true });
  } finally {
    refreshCadenceAnchorAt = Date.now();
    scheduleAutomaticRefresh();
  }
}

/// A first-launch click can race the refresh started during app boot. Wait for
/// that read to settle, then run once with the newly selected providers instead
/// of returning the now-obsolete in-flight result.
async function refreshAfterMutation() {
  return refreshManually();
}

function enabledProviderIDs() {
  return store.state.onboardingCompleted ? store.state.enabledProviders : [];
}

function anyAppWindowVisible() {
  return [mainWindow, popoverWindow, floatingWidgetWindow].some((target) => (
    target && !target.isDestroyed() && target.isVisible() && !target.isMinimized()
  ));
}

function observeRefreshVisibility(target) {
  for (const event of ["show", "hide", "minimize", "restore", "closed"]) {
    target.on(event, scheduleAutomaticRefresh);
  }
}

function observeReducedMotionPreference(target) {
  target.on("focus", refreshReducedMotionPreference);
  target.on("show", () => {
    refreshReducedMotionPreference();
    scheduleReducedMotionPoll();
  });
  for (const event of ["hide", "minimize", "restore", "closed"]) {
    target.on(event, scheduleReducedMotionPoll);
  }
}

function readReducedMotionPreference() {
  const spi = readWindowsReducedMotion();
  let electron;
  if (process.platform === "win32") {
    try { electron = systemPreferences.getAnimationSettings().prefersReducedMotion === true; }
    catch {}
  }
  return { value: resolveReducedMotion(spi, electron), sources: { spi, electron } };
}

function refreshReducedMotionPreference() {
  const next = readReducedMotionPreference();
  if (next.value === reducedMotion
    && Object.is(next.sources.spi, reducedMotionSources.spi)
    && Object.is(next.sources.electron, reducedMotionSources.electron)) return;
  reducedMotion = next.value;
  reducedMotionSources = next.sources;
  notifyRenderer();
}

function scheduleReducedMotionPoll() {
  clearTimeout(reducedMotionTimer);
  reducedMotionTimer = undefined;
  if (isQuitting || !anyAppWindowVisible()) return;
  reducedMotionTimer = setTimeout(() => {
    reducedMotionTimer = undefined;
    refreshReducedMotionPreference();
    scheduleReducedMotionPoll();
  }, REDUCED_MOTION_POLL_MS);
}

function refreshPolicyInput(providerFailureCounts = {}) {
  let systemIdleSeconds = 0;
  try { systemIdleSeconds = powerMonitor.getSystemIdleTime(); } catch {}
  return {
    userIntervalMinutes: store?.state?.preferences?.refreshMinutes,
    anyWindowVisible: anyAppWindowVisible(),
    systemIdleSeconds,
    providerFailureCounts,
  };
}

function scheduleAutomaticRefresh() {
  clearTimeout(refreshTimer);
  refreshTimer = undefined;
  if (isQuitting || !store || !refreshCadenceAnchorAt) return;

  const enabled = new Set(enabledProviderIDs());
  for (const providerID of providerRetryStates.keys()) {
    if (!enabled.has(providerID)) providerRetryStates.delete(providerID);
  }
  const cadenceDelay = nextRefreshDelayMs(refreshPolicyInput());
  if (cadenceDelay === null) return;

  const cadenceAt = refreshCadenceAnchorAt + cadenceDelay;
  const retryAt = Math.min(
    ...[...providerRetryStates.values()].map((state) => state.retryAfter),
    Number.POSITIVE_INFINITY,
  );
  const delay = Math.max(0, Math.min(cadenceAt, retryAt) - Date.now());
  refreshTimer = setTimeout(() => { runScheduledRefresh().catch(() => {}); }, delay);
}

async function runScheduledRefresh() {
  refreshTimer = undefined;
  if (refreshPromise) {
    try { await refreshPromise; } finally { scheduleAutomaticRefresh(); }
    return;
  }

  const now = Date.now();
  const cadenceDelay = nextRefreshDelayMs(refreshPolicyInput());
  if (cadenceDelay === null) return;
  const cadenceDue = now >= refreshCadenceAnchorAt + cadenceDelay;
  const enabled = enabledProviderIDs();
  const dueRetries = enabled.filter((providerID) => providerRetryStates.get(providerID)?.retryAfter <= now);
  if (!cadenceDue && !dueRetries.length) {
    scheduleAutomaticRefresh();
    return;
  }

  const providerIDs = cadenceDue
    ? enabled.filter((providerID) => !providerRetryStates.has(providerID) || providerRetryStates.get(providerID).retryAfter <= now)
    : dueRetries;
  try {
    await refreshAll({ providerIDs, includeSharedSources: cadenceDue });
  } finally {
    if (cadenceDue) refreshCadenceAnchorAt = Date.now();
    scheduleAutomaticRefresh();
  }
}

async function performRefresh({ providerIDs, includeSharedSources = true } = {}) {
  store.state.isRefreshing = true;
  if (includeSharedSources) store.state.feedLoading = !store.state.trending?.length;
  notifyRenderer();
  // Electron's net stack follows the Windows system proxy. Node's global
  // fetch does not, which made a valid Codex login look like a quota timeout.
  const windowsFetch = (url, options) => net.fetch(url, options);
  const enabledProviders = enabledProviderIDs();
  const attemptedProviders = normalizeProviderIDs(providerIDs ?? enabledProviders)
    .filter((providerID) => enabledProviders.includes(providerID));
  const results = await Promise.allSettled([
    collectEnabledProviders(attemptedProviders, {
      fetchImpl: windowsFetch,
      getStoredSecret: (providerID) => store.getProviderSecret(providerID),
      zaiRegion: store.state.preferences?.zaiRegion,
    }),
    includeSharedSources ? fetchCuratedFeed() : Promise.resolve(undefined),
    includeSharedSources ? collectWindowsLocalUsage() : Promise.resolve(undefined),
    includeSharedSources ? checkForAvailableUpdate(windowsFetch) : Promise.resolve(undefined),
    includeSharedSources ? serviceStatusService.refreshIfNeeded() : Promise.resolve(undefined),
  ]);
  const providerResult = results[0];
  const providers = providerResult.status === "fulfilled" ? providerResult.value.providers : [];
  const rawNotices = providerResult.status === "fulfilled"
    ? providerResult.value.notificationNotices
    : { local: noticeFromError(providerResult.reason) };
  const refreshedNoticeDetails = Object.fromEntries(Object.entries(rawNotices).map(([providerID, notice]) => (
    [providerID, { kind: notice.kind, detail: publicError(notice.message) }]
  )));
  const refreshedNotices = Object.fromEntries(Object.entries(rawNotices).map(([providerID, notice]) => (
    [providerID, publicProviderNotice(providerID, notice).message]
  )));
  const failedProviders = providerResult.status === "fulfilled"
    ? new Set(Object.keys(providerResult.value.notices))
    : new Set(attemptedProviders);
  const refreshFinishedAt = Date.now();
  for (const providerID of attemptedProviders) {
    const previous = providerRetryStates.get(providerID)?.failureCount || 0;
    const next = providerRetryState(previous, failedProviders.has(providerID), refreshFinishedAt);
    if (next.failureCount) providerRetryStates.set(providerID, next);
    else providerRetryStates.delete(providerID);
  }
  // A transient network failure must not erase the last successful provider
  // snapshot. Its notice and captured-at age tell the UI that it is stale.
  const retained = (store.state.providers || []).filter((provider) => enabledProviders.includes(provider.providerID));
  store.state.providers = mergeProviders(providers, retained);
  const notices = Object.fromEntries(Object.entries(store.state.notices || {}).filter(([providerID]) => enabledProviders.includes(providerID)));
  const noticeDetails = Object.fromEntries(Object.entries(store.state.noticeDetails || {}).filter(([providerID]) => enabledProviders.includes(providerID)));
  for (const providerID of attemptedProviders) delete notices[providerID];
  for (const providerID of attemptedProviders) delete noticeDetails[providerID];
  if (providerResult.status === "fulfilled") {
    delete notices.local;
    delete noticeDetails.local;
  }
  store.state.notices = { ...notices, ...refreshedNotices };
  store.state.noticeDetails = { ...noticeDetails, ...refreshedNoticeDetails };

  const providerNotifications = decideProviderNotifications({
    notices: providerResult.status === "fulfilled" ? providerResult.value.notificationNotices : {},
    attemptedProviderIDs: attemptedProviders,
    bookkeeping: store.state.notificationBookkeeping,
    now: refreshFinishedAt,
  });
  store.setNotificationBookkeeping(providerNotifications.bookkeeping);
  for (const providerID of providerNotifications.providerIDs) showProviderSignedOutNotification(providerID);

  const feedResult = results[1];
  if (includeSharedSources && feedResult.status === "fulfilled") {
    store.state.trending = feedResult.value;
    store.state.feedUpdatedAt = Date.now();
    delete store.state.feedError;
    const feedNotifications = selectFeedNotifications({
      posts: feedResult.value,
      seenIDs: store.state.notificationBookkeeping?.feedSeenIDs,
      enabled: store.state.preferences?.feedNotificationsEnabled,
    });
    store.setNotificationBookkeeping({
      ...store.state.notificationBookkeeping,
      feedSeenIDs: feedNotifications.seenIDs,
    });
    for (const post of feedNotifications.posts) showFeedNotification(post);
  } else if (includeSharedSources) {
    store.state.feedError = publicError(feedResult.reason);
  }
  if (includeSharedSources) store.state.feedLoading = false;

  const localUsageResult = results[2];
  if (includeSharedSources && localUsageResult.status === "fulfilled") {
    store.setLocalDailyUsageHistory(localUsageResult.value);
    store.state.lastLocalUsageAt = Date.now();
    delete store.state.localUsageError;
  } else if (includeSharedSources) {
    store.state.localUsageError = publicError(localUsageResult.reason);
  }

  if (includeSharedSources) {
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
  }
  return finishRefresh();
}

async function finishRefresh() {
  await scanInstalledProviders();
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
  const state = publicState();
  const summaries = state.providers.flatMap((provider) => {
    const remainingPercent = trayRemainingPercent(provider);
    if (!Number.isFinite(remainingPercent)) return [];
    const name = provider.providerID.charAt(0).toUpperCase() + provider.providerID.slice(1);
    return [`${name} ${remainingPercent}%`];
  });
  tray.setToolTip(summaries.length ? `TokenRemain — ${summaries.slice(0, 4).join(" · ")}` : "TokenRemain");
  tray.setImage(dynamicTrayImage(state) || nativeImage.createFromPath(iconPath()).resize({ width: 20, height: 20 }));
}

function dynamicTrayImage(state) {
  if (!state.providers.length) return undefined;
  const providers = state.providers.map((provider) => ({
    providerID: provider.providerID,
    remainingPercent: trayRemainingPercent(provider),
    colorHex: providerMeta(provider.providerID).color,
  }));
  const selected = pickTrayProviders(providers, state.trayProviders, state.trayDisplayMode);
  if (!selected.length) return undefined;
  const image = nativeImage.createEmpty();
  for (const [scaleFactor, size] of [[1, 16], [2, 32]]) {
    const rendered = renderTrayIcon({ mode: state.trayDisplayMode, providers: selected, size });
    image.addRepresentation({
      scaleFactor,
      width: rendered.width,
      height: rendered.height,
      buffer: rgbaToNativeBitmap(rendered.buffer),
    });
  }
  return image;
}

/// Electron 43 constructs raw NativeImage bitmaps as Skia N32 premultiplied
/// pixels. On little-endian Windows that memory layout is premultiplied BGRA,
/// while the pure renderer deliberately exposes straight-alpha RGBA.
function rgbaToNativeBitmap(rgba) {
  const bitmap = Buffer.alloc(rgba.length);
  for (let index = 0; index < rgba.length; index += 4) {
    const alpha = rgba[index + 3];
    bitmap[index] = Math.round(rgba[index + 2] * alpha / 255);
    bitmap[index + 1] = Math.round(rgba[index + 1] * alpha / 255);
    bitmap[index + 2] = Math.round(rgba[index] * alpha / 255);
    bitmap[index + 3] = alpha;
  }
  return bitmap;
}

/// Local mirror of overview-model's summaryWindow (that module is not in the
/// packaged main-process file set), honoring the quota summary strategy.
function trayRemainingPercent(provider) {
  const strategy = store?.state?.preferences?.summaryStrategy;
  const rolling = (provider?.windows || []).filter((window) => window.windowMinutes > 0);
  const window = rolling.reduce(
    (current, candidate) => {
      if (!current) return candidate;
      if (strategy === "lowestRemaining") return candidate.usedPercent > current.usedPercent ? candidate : current;
      return candidate.windowMinutes < current.windowMinutes ? candidate : current;
    },
    undefined,
  ) || provider?.windows?.[0];
  return Number.isFinite(window?.usedPercent)
    ? Math.round(Math.min(100, Math.max(0, 100 - window.usedPercent)))
    : undefined;
}

function publicState() {
  const paired = store?.state?.pairedMac;
  const localDailyUsageHistory = store?.state?.localDailyUsageHistory;
  const remoteDailyUsageHistory = store?.state?.remoteSnapshot?.dailyUsageHistory;
  const rawDailyUsageHistory = mergeDailyUsageHistories(localDailyUsageHistory, remoteDailyUsageHistory);
  const disabledLocalUsageSources = store?.state?.preferences?.disabledLocalUsageSources || [];
  const dailyUsageHistory = aggregateLocalUsageHistories(
    localDailyUsageHistory,
    remoteDailyUsageHistory,
    disabledLocalUsageSources,
  );
  const pricing = pricingService?.getStatus();
  const providerDetections = store?.state?.providerDetections || [];
  const enabledProviders = normalizeProviderIDs(store?.state?.enabledProviders);
  const updateCheck = store?.state?.updateCheck;
  const noticeDetails = Object.fromEntries(Object.entries(store?.state?.notices || {}).map(([providerID, message]) => (
    [providerID, publicProviderNotice(providerID, noticeFromError(message))]
  )));
  for (const [providerID, notice] of Object.entries(store?.state?.noticeDetails || {})) {
    noticeDetails[providerID] = publicProviderNotice(providerID, notice);
  }
  const notices = Object.fromEntries(Object.entries(noticeDetails).map(([providerID, notice]) => [providerID, notice.message]));
  const availableUpdate = compareVersionCores(app.getVersion(), updateCheck?.availableVersion) === -1
    && isAllowedReleaseURL(updateCheck?.availableURL)
    ? { version: updateCheck.availableVersion, url: updateCheck.availableURL }
    : undefined;
  return {
    sourceInstanceID: store?.state?.sourceInstanceID,
    deviceName: hostname(),
    appVersion: app.getVersion(),
    availableUpdate,
    launchAtLogin: Boolean(app.getLoginItemSettings().openAtLogin),
    reducedMotion,
    // Raw detector values let on-device QA distinguish authoritative SPI from Electron's fallback.
    reducedMotionSources,
    feedNotificationsEnabled: Boolean(store?.state?.preferences?.feedNotificationsEnabled),
    disabledLocalUsageSources,
    floatingWidgetEnabled: Boolean(store?.state?.preferences?.floatingWidgetEnabled),
    backgroundDepth: store?.state?.preferences?.backgroundDepth ?? 0,
    taskbarIconHidden: Boolean(store?.state?.preferences?.taskbarIconHidden),
    zaiRegion: store?.state?.preferences?.zaiRegion || "global",
    summaryStrategy: store?.state?.preferences?.summaryStrategy || "shortestWindow",
    popoverGlassStyle: store?.state?.preferences?.popoverGlassStyle || "frosted",
    popoverBackdropOpacity: store?.state?.preferences?.popoverBackdropOpacity ?? 0.62,
    trayDisplayMode: store?.state?.preferences?.trayDisplayMode || "full",
    trayProviders: store?.state?.preferences?.trayProviders || ["claude", "codex"],
    // Raw explicit overrides only. Missing keys are Auto; renderers combine
    // this map with the provider scoped windows to resolve group activity.
    scopedPoolVisibility: store?.state?.preferences?.scopedPoolVisibility || {},
    languagePreference: store?.state?.preferences?.language || "system",
    refreshMinutes: store?.state?.preferences?.refreshMinutes ?? 5,
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
        launchable: Boolean(detection?.launchable),
        detail: detection?.detail,
        enabled: enabledProviders.includes(definition.id),
      };
    }),
    enabledProviders,
    pendingDetectionSuggestions: store?.state?.pendingDetectionSuggestions || [],
    providers: mergeLocalFirstProviders(store?.state?.providers || [], store?.state?.remoteSnapshot?.providers || []),
    serviceStatus: serviceStatusService?.getStatuses() || {},
    localProviders: store?.state?.providers || [],
    notices,
    // Renderer notice contract: `notices[id]` remains the friendly localized
    // string, while `noticeDetails[id]` is { message, kind, detail }; detail is
    // the bounded raw collector error reserved for tooltips and diagnostics.
    noticeDetails,
    lastUpdatedAt: store?.state?.lastUpdatedAt,
    isRefreshing: Boolean(store?.state?.isRefreshing),
    dailyUsageHistory,
    localUsage: {
      hasLocal: Boolean(localDailyUsageHistory),
      hasRemote: Boolean(remoteDailyUsageHistory),
      capturedAt: rawDailyUsageHistory?.capturedAt,
      sources: detectedLocalUsageSources(rawDailyUsageHistory),
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

async function checkForAvailableUpdate(fetchImpl, now = Date.now()) {
  const previous = store.state.updateCheck || {};
  const hasAvailableUpdate = compareVersionCores(app.getVersion(), previous.availableVersion) === -1
    && isAllowedReleaseURL(previous.availableURL);
  const outcome = previous.failureCount > 0
    ? "failure"
    : hasAvailableUpdate ? "update-available" : "no-update";
  if (!isDue({
    lastCheckedAt: previous.lastCheckedAt,
    outcome,
    failureCount: previous.failureCount,
    now,
  })) return;

  try {
    const release = await fetchLatestRelease({ fetchImpl, etag: previous.etag });
    if (release.notModified) {
      store.setUpdateCheck({ ...previous, lastCheckedAt: now, etag: release.etag, failureCount: 0 });
      return;
    }
    const available = compareVersionCores(app.getVersion(), release.version) === -1;
    store.setUpdateCheck({
      lastCheckedAt: now,
      etag: release.etag,
      failureCount: 0,
      ...(available ? { availableVersion: release.version, availableURL: release.url } : {}),
    });
  } catch {
    store.setUpdateCheck({
      ...previous,
      lastCheckedAt: now,
      failureCount: Math.min(3, (previous.failureCount || 0) + 1),
    });
  }
}

async function scanInstalledProviders({ announce = true } = {}) {
  if (installationDetectionPromise) return installationDetectionPromise;
  installationDetectionPromise = (async () => {
    const detections = detectLocalProviders({
      hasStoredSecret: (providerID) => store.hasProviderSecret(providerID),
    });
    store.state.providerDetections = detections;
    const suggestions = await store.applyProviderDetections(detections);
    if (announce && suggestions.length) {
      notifyRenderer();
      openDashboard("limits");
    }
    return suggestions;
  })();
  try {
    return await installationDetectionPromise;
  } finally {
    installationDetectionPromise = undefined;
  }
}

function scheduleInstallationDetection() {
  clearTimeout(installationDetectionTimer);
  installationDetectionTimer = undefined;
  if (isQuitting || !store) return;
  installationDetectionTimer = setTimeout(() => {
    installationDetectionTimer = undefined;
    scanInstalledProviders().catch(() => {}).finally(scheduleInstallationDetection);
  }, INSTALLATION_DETECTION_POLL_MS);
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

function assertFloatingWidgetSender(event) {
  if (!floatingWidgetWindow || floatingWidgetWindow.isDestroyed() || event.sender !== floatingWidgetWindow.webContents) {
    throw new Error("This action is only available from the floating shortcut");
  }
}

function showProviderSignedOutNotification(providerID) {
  if (!Notification.isSupported()) return;
  const displayName = providerMeta(providerID).name;
  const notification = new Notification({
    title: tr("%1$@ is signed out", [displayName]),
    body: tr("TokenRemain can no longer read your usage — the cards are showing the last good snapshot. Sign in to %1$@ again to restore it.", [displayName]),
    icon: iconPath(),
  });
  notification.on("click", () => openDashboard("dataSources"));
  notification.show();
}

function showFeedNotification(post) {
  if (!Notification.isSupported()) return;
  // Notification.subtitle is macOS-only; Windows toasts drop it, so the
  // author line leads the body instead.
  const notification = new Notification({
    title: tr(post.priority === "token_reset" ? "TokenRemain · Token / quota update" : "TokenRemain · Major AI update"),
    body: `${post.displayName} · @${post.username}\n${truncateNotificationBody(post.text)}`,
    icon: iconPath(),
  });
  notification.on("click", () => {
    if (isAllowedPostURL(post.url)) shell.openExternal(post.url, { activate: true }).catch(() => {});
  });
  notification.show();
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

function publicProviderNotice(providerID, notice) {
  const detail = publicError(notice?.detail ?? notice?.message);
  const kind = ["network", "timeout", "signIn", "rateLimit", "unknown"].includes(notice?.kind)
    ? notice.kind
    : "unknown";
  const providerName = providerMeta(providerID).name;
  let message;
  if (kind === "network" || kind === "timeout") {
    message = trKey("service.claude.cli_timeout").replace(/Claude(?: Code|-Code)?/, providerName);
  } else if (kind === "rateLimit") {
    message = trKey("service.claude.rate_limited").replace("Claude", providerName);
  } else {
    message = detail;
  }
  return { message: publicError(message), kind, detail };
}
