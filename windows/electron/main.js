import { app, BrowserWindow, clipboard, ipcMain, Menu, nativeImage, safeStorage, screen, shell, Tray } from "electron";
import { hostname, release } from "node:os";
import { join } from "node:path";
import { collectClaude } from "./collectors/claude.js";
import { collectCodex } from "./collectors/codex.js";
import { fetchCuratedFeed, isAllowedPostURL } from "./feed.js";
import {
  clampPopoverHeight,
  isRect,
  POPOVER_INITIAL_HEIGHT,
  POPOVER_WIDTH,
  prefersAcrylic,
  resolvePopoverBounds,
} from "./popover-placement.js";
import { StateStore } from "./state-store.js";
import { makeSnapshot } from "./sync/crypto.js";
import { exchangeSnapshot, pairWithMac } from "./sync/client.js";
import { mergeProviders } from "../src/provider-meta.js";

const REFRESH_INTERVAL_MS = 60_000;
/// A tray double-click arrives as click + double-click. Holding the popover
/// toggle for this long lets the second click cancel it, so opening the
/// dashboard never flashes the popover first.
const TRAY_DOUBLE_CLICK_GRACE_MS = 250;
/// Clicking the tray while the popover is open blurs it before the click event
/// arrives. Within this window the click counts as the dismissal instead of
/// immediately reopening what the user just closed.
const TRAY_REOPEN_GUARD_MS = 320;
const DASHBOARD_SECTIONS = new Set(["overview", "limits", "trends", "devices", "dataSources", "settings"]);
const MAX_POPOVER_CONTENT_HEIGHT = 4_000;

let mainWindow;
let popoverWindow;
let store;
let refreshPromise;
let refreshTimer;
let tray;
let isQuitting = false;
let trayToggleTimer;
let popoverHiddenAt = 0;
let popoverContentHeight = POPOVER_INITIAL_HEIGHT;
let popoverAnchorBounds;

if (!app.requestSingleInstanceLock()) app.quit();

app.on("second-instance", () => {
  if (app.isReady()) openDashboard();
});

app.whenReady().then(async () => {
  app.setAppUserModelId("com.jamesli.tokenremain.windows");
  store = new StateStore({ userDataPath: app.getPath("userData"), safeStorage });
  await store.load();
  registerIPC();
  createWindow();
  createPopoverWindow();
  createTray();
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
    // Acrylic is decoration: without Windows 11 22H2 the popover simply keeps
    // the dashboard's opaque dark surface, and nothing else changes.
    backgroundColor: acrylic ? "#00000000" : "#0d0e10",
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

function showPopover(trayBounds) {
  if (!popoverWindow || popoverWindow.isDestroyed()) createPopoverWindow();
  popoverAnchorBounds = usableTrayBounds(trayBounds) || usableTrayBounds(tray?.getBounds?.());
  positionPopover();
  popoverWindow.show();
  popoverWindow.setAlwaysOnTop(true, "pop-up-menu");
  popoverWindow.focus();
  popoverWindow.webContents.send("popover:visibility", true);
  popoverWindow.webContents.send("popover:shown");
}

function hidePopover(options = {}) {
  if (!popoverWindow || popoverWindow.isDestroyed() || !popoverWindow.isVisible()) return;
  if (options.dismissedByClick) popoverHiddenAt = Date.now();
  popoverWindow.hide();
  popoverWindow.webContents.send("popover:visibility", false);
}

function togglePopover(trayBounds) {
  const dismissedByThisClick = Date.now() - popoverHiddenAt < TRAY_REOPEN_GUARD_MS;
  if (dismissedByThisClick || popoverWindow?.isVisible()) hidePopover();
  else showPopover(trayBounds);
}

/// Keeps the popover next to the tray icon and inside the work area of the
/// display the icon lives on, at whatever height the content currently needs.
function positionPopover() {
  if (!popoverWindow || popoverWindow.isDestroyed()) return;
  const display = popoverDisplay();
  const bounds = resolvePopoverBounds({
    trayBounds: popoverAnchorBounds,
    display,
    width: POPOVER_WIDTH,
    height: clampPopoverHeight(popoverContentHeight, display),
  });
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
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: "Open Dashboard", click: () => openDashboard("overview") },
    { label: "Refresh now", click: () => { refreshAll().catch(() => {}); } },
    { label: "Settings", click: () => openDashboard("settings") },
    { type: "separator" },
    { label: "Quit", click: () => { isQuitting = true; app.quit(); } },
  ]));
  tray.on("click", (_event, trayBounds) => {
    cancelTrayToggle();
    trayToggleTimer = setTimeout(() => {
      trayToggleTimer = undefined;
      togglePopover(trayBounds);
    }, TRAY_DOUBLE_CLICK_GRACE_MS);
  });
  tray.on("double-click", () => openDashboard("overview"));
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

async function performRefresh() {
  store.state.isRefreshing = true;
  store.state.feedLoading = !store.state.trending?.length;
  notifyRenderer();
  const results = await Promise.allSettled([collectClaude(), collectCodex(), fetchCuratedFeed()]);
  const providers = [];
  const notices = {};
  for (const [index, result] of results.slice(0, 2).entries()) {
    const id = index === 0 ? "claude" : "codex";
    if (result.status === "fulfilled") providers.push(result.value);
    else notices[id] = publicError(result.reason);
  }
  if (providers.length) {
    store.state.providers = providers;
  }
  store.state.notices = notices;

  const feedResult = results[2];
  if (feedResult.status === "fulfilled") {
    store.state.trending = feedResult.value;
    store.state.feedUpdatedAt = Date.now();
    delete store.state.feedError;
  } else {
    store.state.feedError = publicError(feedResult.reason);
  }
  store.state.feedLoading = false;

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
  store.recordQuotaUsage(mergeProviders(store.state.providers || [], store.state.remoteSnapshot?.providers || []));
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
  return {
    sourceInstanceID: store?.state?.sourceInstanceID,
    deviceName: hostname(),
    appVersion: app.getVersion(),
    launchAtLogin: Boolean(app.getLoginItemSettings().openAtLogin),
    providers: mergeProviders(store?.state?.providers || [], store?.state?.remoteSnapshot?.providers || []),
    localProviders: store?.state?.providers || [],
    notices: store?.state?.notices || {},
    lastUpdatedAt: store?.state?.lastUpdatedAt,
    isRefreshing: Boolean(store?.state?.isRefreshing),
    dailyUsageHistory: store?.state?.remoteSnapshot?.dailyUsageHistory,
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

/// One refresh loop feeds both surfaces: the dashboard and the tray popover
/// always render the same snapshot.
function notifyRenderer() {
  const state = publicState();
  for (const target of [mainWindow, popoverWindow]) {
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
