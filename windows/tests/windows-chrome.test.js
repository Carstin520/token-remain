import assert from "node:assert/strict";
import test from "node:test";
import {
  applyWindowsChrome,
  DWMWA_BORDER_COLOR,
  DWMWA_COLOR_NONE,
  DWMWA_WINDOW_CORNER_PREFERENCE,
  DWMWCP_ROUND,
  hwndFromHandle,
} from "../electron/windows-chrome.js";

test("Windows chrome constants match the documented DWM attributes", () => {
  assert.equal(DWMWA_WINDOW_CORNER_PREFERENCE, 33);
  assert.equal(DWMWCP_ROUND, 2);
  assert.equal(DWMWA_BORDER_COLOR, 34);
  assert.equal(DWMWA_COLOR_NONE, 0xFFFFFFFE);
});

test("Native HWND decoding supports 64-bit and 32-bit little-endian handles", () => {
  const handle64 = Buffer.alloc(8);
  handle64.writeBigUInt64LE(0xFEDCBA9876543210n);
  assert.equal(hwndFromHandle(handle64), 0xFEDCBA9876543210n);

  const handle32 = Buffer.alloc(4);
  handle32.writeUInt32LE(0xFEDCBA98);
  assert.equal(hwndFromHandle(handle32), 0xFEDCBA98n);
});

test("Windows chrome is a no-op outside win32", () => {
  let loaded = false;
  applyWindowsChrome({ isDestroyed: () => false }, {
    platform: "darwin",
    loader: () => { loaded = true; },
  });
  assert.equal(loaded, false);
});

test("Windows chrome gracefully swallows a native loader failure", () => {
  assert.doesNotThrow(() => applyWindowsChrome({ isDestroyed: () => false }, {
    platform: "win32",
    round: true,
    loader: () => { throw new Error("koffi unavailable"); },
  }));
});
