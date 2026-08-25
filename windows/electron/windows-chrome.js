import { createRequire } from "node:module";

export const DWMWA_WINDOW_CORNER_PREFERENCE = 33;
export const DWMWCP_ROUND = 2;
export const DWMWA_BORDER_COLOR = 34;
export const DWMWA_COLOR_NONE = 0xFFFFFFFE;

const require = createRequire(import.meta.url);

export function hwndFromHandle(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 4) throw new TypeError("Invalid native window handle");
  return buffer.length >= 8 ? buffer.readBigUInt64LE() : BigInt(buffer.readUInt32LE());
}

function loadKoffi() {
  return require("koffi");
}

function setUintAttribute(api, hwnd, attribute, value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value >>> 0);
  api.DwmSetWindowAttribute(hwnd, attribute, buffer, buffer.length);
}

/// Best-effort DWM polish for frameless Windows windows. Koffi and dwmapi.dll
/// are loaded only here, and every failure is swallowed so cosmetic chrome can
/// never prevent a BrowserWindow from being created.
export function applyWindowsChrome(win, {
  round = false,
  platform = process.platform,
  loader = loadKoffi,
} = {}) {
  if (platform !== "win32" || !win) return;
  try {
    if (win.isDestroyed?.()) return;
    const koffi = loader();
    const dwmapi = koffi.load("dwmapi.dll");
    const api = {
      DwmSetWindowAttribute: dwmapi.func(
        "int DwmSetWindowAttribute(uintptr_t hwnd, uint dwAttribute, void *pvAttribute, uint cbAttribute)",
      ),
    };
    const hwnd = hwndFromHandle(win.getNativeWindowHandle());
    if (round) setUintAttribute(api, hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND);
    setUintAttribute(api, hwnd, DWMWA_BORDER_COLOR, DWMWA_COLOR_NONE);
  } catch {
    // Purely cosmetic: missing native binaries and unsupported DWM calls are safe no-ops.
  }
}
