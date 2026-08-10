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
  pair: (input) => ipcRenderer.invoke("sync:pair", input),
  disconnect: () => ipcRenderer.invoke("sync:disconnect"),
  openExternal: (url) => ipcRenderer.invoke("feed:open", url),
  setLaunchAtLogin: (value) => ipcRenderer.invoke("settings:set-launch-at-login", value),
  setFloatingWidgetEnabled: (value) => ipcRenderer.invoke("settings:set-floating-widget", value),
  setLanguage: (value) => ipcRenderer.invoke("settings:set-language", value),
  openPopup: () => ipcRenderer.invoke("popup:open"),
  togglePopupFromFloating: () => ipcRenderer.invoke("popup:toggle-from-floating"),
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
