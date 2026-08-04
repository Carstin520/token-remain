import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("tokenRemain", {
  getState: () => ipcRenderer.invoke("state:get"),
  refresh: () => ipcRenderer.invoke("usage:refresh"),
  pair: (input) => ipcRenderer.invoke("sync:pair", input),
  disconnect: () => ipcRenderer.invoke("sync:disconnect"),
  openExternal: (url) => ipcRenderer.invoke("feed:open", url),
  onStateChanged: (listener) => {
    const wrapped = (_event, state) => listener(state);
    ipcRenderer.on("state:changed", wrapped);
    return () => ipcRenderer.removeListener("state:changed", wrapped);
  },
});
