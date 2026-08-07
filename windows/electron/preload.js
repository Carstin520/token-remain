import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("tokenRemain", {
  getState: () => ipcRenderer.invoke("state:get"),
  refresh: () => ipcRenderer.invoke("usage:refresh"),
  pair: (input) => ipcRenderer.invoke("sync:pair", input),
  disconnect: () => ipcRenderer.invoke("sync:disconnect"),
  openExternal: (url) => ipcRenderer.invoke("feed:open", url),
  setLaunchAtLogin: (value) => ipcRenderer.invoke("settings:set-launch-at-login", value),
  relaunch: () => ipcRenderer.invoke("app:relaunch"),
  quit: () => ipcRenderer.invoke("app:quit"),
  onStateChanged: (listener) => {
    const wrapped = (_event, state) => listener(state);
    ipcRenderer.on("state:changed", wrapped);
    return () => ipcRenderer.removeListener("state:changed", wrapped);
  },
});
