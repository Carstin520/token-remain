import assert from "node:assert/strict";
import test from "node:test";
import {
  clampPopoverHeight,
  edgeNearestTray,
  isUsableTrayBounds,
  POPOVER_MAX_HEIGHT,
  POPOVER_MIN_HEIGHT,
  POPOVER_WIDTH,
  prefersAcrylic,
  resolvePopoverBounds,
  taskbarEdge,
} from "../electron/popover-placement.js";

const FHD = {
  bounds: { x: 0, y: 0, width: 1920, height: 1080 },
  workArea: { x: 0, y: 0, width: 1920, height: 1032 },
};

function contains(bounds, workArea) {
  return bounds.x >= workArea.x
    && bounds.y >= workArea.y
    && bounds.x + bounds.width <= workArea.x + workArea.width
    && bounds.y + bounds.height <= workArea.y + workArea.height;
}

function assertIntegral(bounds) {
  for (const key of ["x", "y", "width", "height"]) {
    assert.ok(Number.isInteger(bounds[key]), `${key} must be an integer, got ${bounds[key]}`);
  }
}

test("Taskbar edge is read from the gap between display bounds and work area", () => {
  assert.equal(taskbarEdge(FHD), "bottom");
  assert.equal(taskbarEdge({ bounds: { x: 0, y: 0, width: 1920, height: 1080 }, workArea: { x: 0, y: 48, width: 1920, height: 1032 } }), "top");
  assert.equal(taskbarEdge({ bounds: { x: 0, y: 0, width: 1920, height: 1080 }, workArea: { x: 72, y: 0, width: 1848, height: 1080 } }), "left");
  assert.equal(taskbarEdge({ bounds: { x: 0, y: 0, width: 1920, height: 1080 }, workArea: { x: 0, y: 0, width: 1848, height: 1080 } }), "right");
  // An auto-hidden taskbar leaves the work area untouched.
  assert.equal(taskbarEdge({ bounds: FHD.bounds, workArea: FHD.bounds }), undefined);
  assert.equal(taskbarEdge(undefined), undefined);
});

test("Bottom taskbar puts the popover above the tray icon, centred on it", () => {
  const trayBounds = { x: 1700, y: 1032, width: 24, height: 24 };
  const bounds = resolvePopoverBounds({ trayBounds, display: FHD, height: 500 });
  assertIntegral(bounds);
  assert.equal(bounds.edge, "bottom");
  assert.equal(bounds.anchored, true);
  assert.equal(bounds.y + bounds.height, 1032 - 8);
  assert.equal(bounds.x + bounds.width / 2, 1712);
  assert.ok(contains(bounds, FHD.workArea));
});

test("Top taskbar drops the popover below the taskbar band, tracking the tray icon", () => {
  const display = { bounds: { x: 0, y: 0, width: 1920, height: 1080 }, workArea: { x: 0, y: 48, width: 1920, height: 1032 } };
  const bounds = resolvePopoverBounds({ trayBounds: { x: 1700, y: 8, width: 24, height: 24 }, display, height: 500 });
  assert.equal(bounds.edge, "top");
  // The icon sits inside the taskbar, so the work area is what bounds the top.
  assert.equal(bounds.y, 56);
  assert.equal(bounds.x + bounds.width / 2, 1712);
  assert.ok(contains(bounds, display.workArea));
});

test("Left taskbar puts the popover to the right of the taskbar band", () => {
  const display = { bounds: { x: 0, y: 0, width: 1920, height: 1080 }, workArea: { x: 72, y: 0, width: 1848, height: 1080 } };
  const bounds = resolvePopoverBounds({ trayBounds: { x: 10, y: 500, width: 24, height: 24 }, display, height: 500 });
  assert.equal(bounds.edge, "left");
  assert.equal(bounds.x, 80);
  assert.equal(bounds.y + bounds.height / 2, 512);
  assert.ok(contains(bounds, display.workArea));
});

test("Right taskbar puts the popover to the left of the taskbar band", () => {
  const display = { bounds: { x: 0, y: 0, width: 1920, height: 1080 }, workArea: { x: 0, y: 0, width: 1848, height: 1080 } };
  const bounds = resolvePopoverBounds({ trayBounds: { x: 1880, y: 500, width: 24, height: 24 }, display, height: 500 });
  assert.equal(bounds.edge, "right");
  assert.equal(bounds.x + bounds.width, 1840);
  assert.equal(bounds.y + bounds.height / 2, 512);
  assert.ok(contains(bounds, display.workArea));
});

test("A second display keeps the popover on that display's work area", () => {
  const secondary = {
    bounds: { x: 1920, y: -220, width: 2560, height: 1440 },
    workArea: { x: 1920, y: -220, width: 2560, height: 1392 },
  };
  const bounds = resolvePopoverBounds({ trayBounds: { x: 4440, y: 1150, width: 24, height: 24 }, display: secondary, height: 620 });
  assertIntegral(bounds);
  assert.ok(contains(bounds, secondary.workArea));
  // Clamped inwards from the right edge rather than centred past it.
  assert.equal(bounds.x + bounds.width, 1920 + 2560 - 8);
});

test("Negative-coordinate displays keep negative, in-bounds placements", () => {
  const left = {
    bounds: { x: -1920, y: -1080, width: 1920, height: 1080 },
    workArea: { x: -1920, y: -1080, width: 1920, height: 1032 },
  };
  const bounds = resolvePopoverBounds({ trayBounds: { x: -300, y: -48, width: 24, height: 24 }, display: left, height: 500 });
  assertIntegral(bounds);
  assert.ok(bounds.x < 0 && bounds.y < 0);
  assert.ok(contains(bounds, left.workArea));
});

test("Fractional DIP work areas from 125% and 150% scaling stay inside after rounding", () => {
  // 1920x1080 physical at 125% and 150% reports fractional DIP extents.
  const scaled = [
    { scaleFactor: 1.25, bounds: { x: 0, y: 0, width: 1536, height: 864 }, workArea: { x: 0, y: 0, width: 1536, height: 825.6 } },
    { scaleFactor: 1.5, bounds: { x: 0, y: 0, width: 1280, height: 720 }, workArea: { x: 0, y: 0, width: 1280, height: 688.5 } },
    { scaleFactor: 1.5, bounds: { x: -1706.5, y: 0, width: 1706.5, height: 960 }, workArea: { x: -1706.5, y: 0, width: 1706.5, height: 928.5 } },
  ];
  for (const display of scaled) {
    const trayBounds = {
      x: display.workArea.x + display.workArea.width - 41.5,
      y: display.workArea.height - 0.5,
      width: 16.5,
      height: 16.5,
    };
    const height = clampPopoverHeight(2_000, display);
    const bounds = resolvePopoverBounds({ trayBounds, display, height });
    assertIntegral(bounds);
    assert.ok(contains(bounds, display.workArea), `scale ${display.scaleFactor} produced ${JSON.stringify(bounds)}`);
  }
});

test("Height is capped by the work area so tall content scrolls instead of overflowing", () => {
  assert.equal(clampPopoverHeight(520, FHD), 520);
  assert.equal(clampPopoverHeight(5_000, FHD), POPOVER_MAX_HEIGHT);
  assert.equal(clampPopoverHeight(100, FHD), POPOVER_MIN_HEIGHT);
  // A short work area wins over the popover's own minimum.
  const shortDisplay = { bounds: { x: 0, y: 0, width: 1280, height: 400 }, workArea: { x: 0, y: 0, width: 1280, height: 360 } };
  assert.equal(clampPopoverHeight(700, shortDisplay), 344);
  assert.equal(clampPopoverHeight(undefined, FHD), 460);
});

test("A popover as tall as the work area still fits inside it", () => {
  const shortDisplay = { bounds: { x: 0, y: 0, width: 1280, height: 400 }, workArea: { x: 0, y: 0, width: 1280, height: 360 } };
  const height = clampPopoverHeight(POPOVER_MAX_HEIGHT, shortDisplay);
  const bounds = resolvePopoverBounds({ trayBounds: { x: 1240, y: 362, width: 24, height: 24 }, display: shortDisplay, height });
  assert.ok(contains(bounds, shortDisplay.workArea));
  assert.equal(bounds.height, 344);
  // Narrower than the popover: the leading edge stays visible.
  const narrow = { bounds: { x: 0, y: 0, width: 320, height: 480 }, workArea: { x: 0, y: 0, width: 320, height: 440 } };
  const narrowBounds = resolvePopoverBounds({ trayBounds: { x: 300, y: 442, width: 24, height: 24 }, display: narrow, height: 300 });
  assert.equal(narrowBounds.x, 0);
  assert.equal(narrowBounds.width, POPOVER_WIDTH);
});

test("Unusable tray bounds fall back to the work-area corner beside the taskbar", () => {
  assert.equal(isUsableTrayBounds({ x: 0, y: 0, width: 0, height: 0 }, FHD.bounds), false);
  assert.equal(isUsableTrayBounds({ x: 9_000, y: 40, width: 24, height: 24 }, FHD.bounds), false);
  assert.equal(isUsableTrayBounds({ x: 0, y: 0, width: 1920, height: 1080 }, FHD.bounds), false);
  assert.equal(isUsableTrayBounds(undefined, FHD.bounds), false);
  assert.equal(isUsableTrayBounds({ x: 1700, y: 1040, width: 24, height: 24 }, FHD.bounds), true);

  for (const trayBounds of [undefined, { x: 0, y: 0, width: 0, height: 0 }, { x: 9_000, y: 40, width: 24, height: 24 }]) {
    const bounds = resolvePopoverBounds({ trayBounds, display: FHD, height: 500 });
    assert.equal(bounds.anchored, false);
    assert.equal(bounds.edge, "bottom");
    assert.ok(contains(bounds, FHD.workArea));
    assert.equal(bounds.x + bounds.width, 1920 - 8);
    assert.equal(bounds.y + bounds.height, 1032 - 8);
  }

  // The fallback follows the taskbar rather than hardcoding a screen corner.
  const topDisplay = { bounds: { x: 0, y: 0, width: 1920, height: 1080 }, workArea: { x: 0, y: 48, width: 1920, height: 1032 } };
  assert.equal(resolvePopoverBounds({ display: topDisplay, height: 500 }).y, 56);
  const leftDisplay = { bounds: { x: 0, y: 0, width: 1920, height: 1080 }, workArea: { x: 72, y: 0, width: 1848, height: 1080 } };
  assert.equal(resolvePopoverBounds({ display: leftDisplay, height: 500 }).x, 80);
});

test("An auto-hidden taskbar anchors off the display edge the tray sits nearest", () => {
  const autoHide = { bounds: { x: 0, y: 0, width: 1920, height: 1080 }, workArea: { x: 0, y: 0, width: 1920, height: 1080 } };
  assert.equal(edgeNearestTray({ x: 1700, y: 1060, width: 16, height: 16 }, autoHide.bounds), "bottom");
  assert.equal(edgeNearestTray({ x: 1700, y: 4, width: 16, height: 16 }, autoHide.bounds), "top");
  const bounds = resolvePopoverBounds({ trayBounds: { x: 1700, y: 1060, width: 16, height: 16 }, display: autoHide, height: 500 });
  assert.equal(bounds.edge, "bottom");
  assert.equal(bounds.y + bounds.height, 1060 - 8);
  assert.ok(contains(bounds, autoHide.workArea));
});

test("Missing display data still produces integral, non-negative-size bounds", () => {
  const bounds = resolvePopoverBounds({});
  assertIntegral(bounds);
  assert.equal(bounds.width, POPOVER_WIDTH);
  assert.ok(bounds.height > 0);
});

test("Acrylic is limited to Windows 11 22H2 and newer", () => {
  assert.equal(prefersAcrylic("win32", "10.0.22621"), true);
  assert.equal(prefersAcrylic("win32", "10.0.26100"), true);
  assert.equal(prefersAcrylic("win32", "10.0.19045"), false);
  assert.equal(prefersAcrylic("darwin", "25.5.0"), false);
  assert.equal(prefersAcrylic("win32", undefined), false);
});
