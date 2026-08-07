import { app, BrowserWindow, ipcMain, Menu, nativeImage, safeStorage, shell, Tray } from "electron";
import { hostname } from "node:os";
import { join } from "node:path";
import { collectClaude } from "./collectors/claude.js";
import { collectCodex } from "./collectors/codex.js";
import { fetchCuratedFeed, isAllowedPostURL } from "./feed.js";
import { StateStore } from "./state-store.js";
import { makeSnapshot } from "./sync/crypto.js";
import { exchangeSnapshot, pairWithMac } from "./sync/client.js";
import { mergeProviders } from "../src/provider-meta.js";

const REFRESH_INTERVAL_MS = 60_000;
let mainWindow;
let store;
let refreshPromise;
let refreshTimer;
let tray;
let isQuitting = false;

if (!app.requestSingleInstanceLock()) app.quit();

app.on("second-instance", () => {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
});

app.whenReady().then(async () => {
  app.setAppUserModelId("com.jamesli.tokenremain.windows");
  store = new StateStore({ userDataPath: app.getPath("userData"), safeStorage });
  await store.load();
  registerIPC();
  createWindow();
  createTray();
  await refreshAll();
  refreshTimer = setInterval(refreshAll, REFRESH_INTERVAL_MS);
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});

app.on("window-all-closed", () => {
  if (process.platform !== "win32") app.quit();
});

app.on("before-quit", () => {
  isQuitting = true;
  clearInterval(refreshTimer);
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
      preload: join(import.meta.dirname, "preload.js"),
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

function createTray() {
  const image = nativeImage.createFromPath(iconPath()).resize({ width: 20, height: 20 });
  tray = new Tray(image);
  tray.setToolTip("TokenRemain");
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: "Open TokenRemain", click: showMainWindow },
    { label: "Refresh now", click: refreshAll },
    { type: "separator" },
    { label: "Quit", click: () => { isQuitting = true; app.quit(); } },
  ]));
  tray.on("double-click", showMainWindow);
}

function showMainWindow() {
  if (!mainWindow) createWindow();
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
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
  store.state.lastUpdatedAt = Date.now();
  store.state.isRefreshing = false;
  await store.save();
  notifyRenderer();
  return publicState();
}

function publicState() {
  const paired = store?.state?.pairedMac;
  return {
    sourceInstanceID: store?.state?.sourceInstanceID,
    deviceName: hostname(),
    providers: mergeProviders(store?.state?.providers || [], store?.state?.remoteSnapshot?.providers || []),
    localProviders: store?.state?.providers || [],
    notices: store?.state?.notices || {},
    lastUpdatedAt: store?.state?.lastUpdatedAt,
    isRefreshing: Boolean(store?.state?.isRefreshing),
    dailyUsageHistory: store?.state?.remoteSnapshot?.dailyUsageHistory,
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

function notifyRenderer() {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send("state:changed", publicState());
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
