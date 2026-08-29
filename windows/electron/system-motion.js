import { createRequire } from "node:module";

export const SPI_GETCLIENTAREAANIMATION = 0x1042;

const require = createRequire(import.meta.url);

function loadKoffi() {
  return require("koffi");
}

export function reducedMotionFromClientAreaAnimations(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 4) throw new TypeError("Invalid BOOL buffer");
  return buffer.readInt32LE(0) === 0;
}

/// Windows' Animation effects setting is authoritative for reduced motion.
/// Native loading stays lazy and best-effort so this module is safe in tests,
/// on non-Windows hosts, and when the optional native bridge cannot load.
export function readWindowsReducedMotion({
  platform = process.platform,
  loader = loadKoffi,
} = {}) {
  if (platform !== "win32") return undefined;
  try {
    const user32 = loader().load("user32.dll");
    const systemParametersInfo = user32.func(
      "int SystemParametersInfoW(uint uiAction, uint uiParam, void *pvParam, uint fWinIni)",
    );
    const animationsEnabled = Buffer.alloc(4);
    if (!systemParametersInfo(SPI_GETCLIENTAREAANIMATION, 0, animationsEnabled, 0)) return undefined;
    return reducedMotionFromClientAreaAnimations(animationsEnabled);
  } catch {
    return undefined;
  }
}

export function resolveReducedMotion(spi, electron) {
  if (typeof spi === "boolean") return spi;
  if (typeof electron === "boolean") return electron;
  return false;
}
