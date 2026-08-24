import assert from "node:assert/strict";
import test from "node:test";
import {
  readWindowsReducedMotion,
  reducedMotionFromClientAreaAnimations,
  resolveReducedMotion,
  SPI_GETCLIENTAREAANIMATION,
} from "../electron/system-motion.js";

test("Windows BOOL animation buffers decode to the inverse reduced-motion value", () => {
  const animationsEnabled = Buffer.alloc(4);
  animationsEnabled.writeInt32LE(1);
  assert.equal(reducedMotionFromClientAreaAnimations(animationsEnabled), false);
  assert.equal(reducedMotionFromClientAreaAnimations(Buffer.alloc(4)), true);
});

test("Windows reduced-motion detection is a no-op outside win32", () => {
  let loaded = false;
  const result = readWindowsReducedMotion({
    platform: "darwin",
    loader: () => { loaded = true; },
  });
  assert.equal(result, undefined);
  assert.equal(loaded, false);
});

test("Windows reduced-motion detection reads SPI and tolerates loader failure", () => {
  let action;
  const result = readWindowsReducedMotion({
    platform: "win32",
    loader: () => ({
      load: (library) => ({
        func: (signature) => (uiAction, uiParam, output, flags) => {
          assert.equal(library, "user32.dll");
          assert.match(signature, /SystemParametersInfoW/);
          assert.equal(uiParam, 0);
          assert.equal(flags, 0);
          action = uiAction;
          output.writeInt32LE(0);
          return 1;
        },
      }),
    }),
  });
  assert.equal(action, SPI_GETCLIENTAREAANIMATION);
  assert.equal(result, true);
  assert.equal(readWindowsReducedMotion({
    platform: "win32",
    loader: () => { throw new Error("koffi unavailable"); },
  }), undefined);
});

test("SPI reduced motion wins, then Electron, then the false default", () => {
  assert.equal(resolveReducedMotion(false, true), false);
  assert.equal(resolveReducedMotion(true, false), true);
  assert.equal(resolveReducedMotion(undefined, true), true);
  assert.equal(resolveReducedMotion(undefined, false), false);
  assert.equal(resolveReducedMotion(undefined, undefined), false);
});
