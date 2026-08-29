// CommonJS, and named .cjs inside this "type": "module" package, because a
// sandboxed preload is always evaluated as CommonJS: ESM `import` here fails to
// load and leaves the renderer with no bridge at all.
const { contextBridge, ipcRenderer } = require("electron");

function subscribe(channel, listener) {
  const wrapped = (_event, payload) => listener(payload);
  ipcRenderer.on(channel, wrapped);
  return () => ipcRenderer.removeListener(channel, wrapped);
}

contextBridge.exposeInMainWorld("tokenRemain", {
  getState: () => ipcRenderer.invoke("state:get"),
  refresh: () => ipcRenderer.invoke("usage:refresh"),
  completeOnboarding: (providerIDs) => ipcRenderer.invoke("onboarding:complete", providerIDs),
  rescanProviders: () => ipcRenderer.invoke("providers:rescan"),
  setProviderEnabled: (providerID, enabled) => ipcRenderer.invoke("providers:set-enabled", providerID, enabled),
  setProviderCredential: (providerID, value) => ipcRenderer.invoke("providers:set-credential", providerID, value),
  clearProviderCredential: (providerID) => ipcRenderer.invoke("providers:clear-credential", providerID),
  acceptDetectionSuggestion: (providerID) => ipcRenderer.invoke("providers:accept-detection", providerID),
  dismissDetectionSuggestion: (providerID) => ipcRenderer.invoke("providers:dismiss-detection", providerID),
  openProviderApp: (providerID) => ipcRenderer.invoke("providers:open-app", providerID),
  pair: (input) => ipcRenderer.invoke("sync:pair", input),
  disconnect: () => ipcRenderer.invoke("sync:disconnect"),
  openExternal: (url) => ipcRenderer.invoke("feed:open", url),
  openCodexUsage: (url) => ipcRenderer.invoke("codex:usage-open", url),
  openUpdate: (url) => ipcRenderer.invoke("update:open", url),
  setLaunchAtLogin: (value) => ipcRenderer.invoke("settings:set-launch-at-login", value),
  setFloatingWidgetEnabled: (value) => ipcRenderer.invoke("settings:set-floating-widget", value),
  setBackgroundDepth: (value) => ipcRenderer.invoke("settings:set-background-depth", value),
  setTaskbarIconHidden: (value) => ipcRenderer.invoke("settings:set-taskbar-icon-hidden", value),
  setZAIRegion: (value) => ipcRenderer.invoke("settings:set-zai-region", value),
  setFeedNotificationsEnabled: (value) => ipcRenderer.invoke("settings:set-feed-notifications", value),
  setLocalUsageSourceEnabled: (id, enabled) => ipcRenderer.invoke("settings:set-local-usage-source-enabled", id, enabled),
  setScopedPoolVisibility: (key, value) => ipcRenderer.invoke("settings:set-scoped-pool-visibility", key, value),
  setTrayDisplayMode: (value) => ipcRenderer.invoke("settings:set-tray-display-mode", value),
  setTrayProviders: (value) => ipcRenderer.invoke("settings:set-tray-providers", value),
  setLanguage: (value) => ipcRenderer.invoke("settings:set-language", value),
  setRefreshMinutes: (value) => ipcRenderer.invoke("settings:set-refresh-minutes", value),
  setSummaryStrategy: (value) => ipcRenderer.invoke("settings:set-summary-strategy", value),
  setPopoverGlassStyle: (value) => ipcRenderer.invoke("settings:set-popover-glass-style", value),
  setPopoverBackdropOpacity: (value) => ipcRenderer.invoke("settings:set-popover-backdrop-opacity", value),
  openPopup: () => ipcRenderer.invoke("popup:open"),
  togglePopupFromFloating: () => ipcRenderer.invoke("popup:toggle-from-floating"),
  startFloatingDrag: () => ipcRenderer.invoke("floating:drag-start"),
  moveFloatingWidget: (delta) => ipcRenderer.invoke("floating:drag-move", delta),
  endFloatingDrag: () => ipcRenderer.invoke("floating:drag-end"),
  relaunch: () => ipcRenderer.invoke("app:relaunch"),
  quit: () => ipcRenderer.invoke("app:quit"),
  openDashboard: (section) => ipcRenderer.invoke("dashboard:open", section),
  copyText: (text) => ipcRenderer.invoke("clipboard:copy-text", text),
  hidePopover: () => ipcRenderer.send("popover:hide"),
  resizePopover: (contentHeight) => ipcRenderer.send("popover:resize", contentHeight),
  onStateChanged: (listener) => subscribe("state:changed", listener),
  onNavigate: (listener) => subscribe("navigate:section", listener),
  onPopoverShown: (listener) => subscribe("popover:shown", listener),
  onPopoverVisibility: (listener) => subscribe("popover:visibility", listener),
});
