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
  pair: (input) => ipcRenderer.invoke("sync:pair", input),
  disconnect: () => ipcRenderer.invoke("sync:disconnect"),
  openExternal: (url) => ipcRenderer.invoke("feed:open", url),
  setLaunchAtLogin: (value) => ipcRenderer.invoke("settings:set-launch-at-login", value),
  relaunch: () => ipcRenderer.invoke("app:relaunch"),
  quit: () => ipcRenderer.invoke("app:quit"),
  openDashboard: (section) => ipcRenderer.invoke("dashboard:open", section),
  hidePopover: () => ipcRenderer.send("popover:hide"),
  resizePopover: (contentHeight) => ipcRenderer.send("popover:resize", contentHeight),
  onStateChanged: (listener) => subscribe("state:changed", listener),
  onNavigate: (listener) => subscribe("navigate:section", listener),
  onPopoverShown: (listener) => subscribe("popover:shown", listener),
  onPopoverVisibility: (listener) => subscribe("popover:visibility", listener),
});
