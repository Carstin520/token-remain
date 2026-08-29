// Pure geometry for the tray popover. Everything here takes plain rectangles so
// the Windows taskbar/DPI/multi-monitor cases can be tested without Electron.
//
// Electron reports tray and display rectangles in DIP. At 125% / 150% scaling
// those values are frequently fractional, so every result is rounded and then
// re-clamped: a rounded window must never end up outside the work area.

export const POPOVER_WIDTH = 400;
export const POPOVER_MIN_HEIGHT = 260;
export const POPOVER_MAX_HEIGHT = 720;
export const POPOVER_INITIAL_HEIGHT = 460;

/// Distance kept between the tray icon and the popover.
const TRAY_GAP = 8;
/// Distance kept between the popover and the edges of the work area.
const SCREEN_MARGIN = 8;
/// A tray rectangle larger than this is not a tray icon; Windows occasionally
/// hands back the overflow flyout or a stale monitor rect.
const MAX_TRAY_EXTENT = 512;

export function isRect(rect) {
  return Boolean(rect)
    && Number.isFinite(rect.x) && Number.isFinite(rect.y)
    && Number.isFinite(rect.width) && Number.isFinite(rect.height);
}

/// Tray bounds are trusted only when they describe a small rectangle whose
/// centre actually sits on the display. The collapsed "show hidden icons" area
/// and a not-yet-realised tray both report unusable values.
export function isUsableTrayBounds(trayBounds, screenBounds) {
  if (!isRect(trayBounds)) return false;
  if (trayBounds.width <= 0 || trayBounds.height <= 0) return false;
  if (trayBounds.width > MAX_TRAY_EXTENT || trayBounds.height > MAX_TRAY_EXTENT) return false;
  if (!isRect(screenBounds)) return true;
  const centerX = trayBounds.x + trayBounds.width / 2;
  const centerY = trayBounds.y + trayBounds.height / 2;
  return centerX >= screenBounds.x && centerX <= screenBounds.x + screenBounds.width
    && centerY >= screenBounds.y && centerY <= screenBounds.y + screenBounds.height;
}

/// Which edge the taskbar occupies, derived from the gap between the display
/// bounds and its work area. An auto-hidden taskbar leaves no gap and returns
/// undefined so the caller can fall back to the tray position.
export function taskbarEdge(display) {
  const bounds = display?.bounds;
  const workArea = display?.workArea;
  if (!isRect(bounds) || !isRect(workArea)) return undefined;
  const insets = [
    ["bottom", (bounds.y + bounds.height) - (workArea.y + workArea.height)],
    ["top", workArea.y - bounds.y],
    ["left", workArea.x - bounds.x],
    ["right", (bounds.x + bounds.width) - (workArea.x + workArea.width)],
  ];
  const [edge, inset] = insets.reduce((widest, candidate) => (candidate[1] > widest[1] ? candidate : widest));
  return inset > 0 ? edge : undefined;
}

/// Fallback edge for an auto-hidden taskbar: the display edge the tray icon
/// sits closest to.
export function edgeNearestTray(trayBounds, screenBounds) {
  const centerX = trayBounds.x + trayBounds.width / 2;
  const centerY = trayBounds.y + trayBounds.height / 2;
  const distances = [
    ["bottom", (screenBounds.y + screenBounds.height) - centerY],
    ["top", centerY - screenBounds.y],
    ["left", centerX - screenBounds.x],
    ["right", (screenBounds.x + screenBounds.width) - centerX],
  ];
  return distances.reduce((nearest, candidate) => (candidate[1] < nearest[1] ? candidate : nearest))[0];
}

/// Popover height: the measured content, bounded by the popover's own limits
/// and by what the current work area can actually show. Content taller than
/// this scrolls inside the window instead of growing past the screen.
export function clampPopoverHeight(contentHeight, display, options = {}) {
  const {
    margin = SCREEN_MARGIN,
    minimum = POPOVER_MIN_HEIGHT,
    maximum = POPOVER_MAX_HEIGHT,
  } = options;
  const workAreaHeight = Number.isFinite(display?.workArea?.height) ? display.workArea.height : maximum;
  const ceiling = Math.max(1, Math.floor(Math.min(maximum, workAreaHeight - 2 * margin)));
  const requested = Number.isFinite(contentHeight) && contentHeight > 0
    ? Math.ceil(contentHeight)
    : POPOVER_INITIAL_HEIGHT;
  return Math.min(ceiling, Math.max(minimum, requested));
}

/// Integer window bounds anchored next to the tray icon and fully contained in
/// the work area of the display the tray lives on.
export function resolvePopoverBounds(input = {}) {
  const {
    trayBounds,
    display,
    width = POPOVER_WIDTH,
    height = POPOVER_INITIAL_HEIGHT,
    gap = TRAY_GAP,
    margin = SCREEN_MARGIN,
  } = input;
  const safeWidth = Math.max(1, Math.round(width));
  const safeHeight = Math.max(1, Math.round(height));
  const workArea = isRect(display?.workArea)
    ? display.workArea
    : { x: 0, y: 0, width: safeWidth + 2 * margin, height: safeHeight + 2 * margin };
  const screenBounds = isRect(display?.bounds) ? display.bounds : workArea;
  const anchored = isUsableTrayBounds(trayBounds, screenBounds);
  const edge = taskbarEdge({ bounds: screenBounds, workArea })
    || (anchored ? edgeNearestTray(trayBounds, screenBounds) : "bottom");

  const placement = anchored
    ? anchorToTray(trayBounds, edge, safeWidth, safeHeight, gap)
    : anchorToWorkAreaCorner(workArea, edge, safeWidth, safeHeight, margin);

  return {
    x: clampAxis(placement.x, safeWidth, workArea.x, workArea.width, margin),
    y: clampAxis(placement.y, safeHeight, workArea.y, workArea.height, margin),
    width: safeWidth,
    height: safeHeight,
    edge,
    anchored,
  };
}

/// Places the quick view beside the freely movable desktop shortcut. Unlike a
/// tray icon, this anchor can sit anywhere in the work area: prefer the side
/// with enough room, fall back above/below, and never use taskbar direction to
/// push the window back across the shortcut.
export function resolveFloatingPopoverBounds(input = {}) {
  const {
    anchorBounds,
    display,
    width = POPOVER_WIDTH,
    height = POPOVER_INITIAL_HEIGHT,
    gap = TRAY_GAP,
    margin = SCREEN_MARGIN,
  } = input;
  const safeWidth = Math.max(1, Math.round(width));
  const safeHeight = Math.max(1, Math.round(height));
  const workArea = isRect(display?.workArea)
    ? display.workArea
    : { x: 0, y: 0, width: safeWidth + 2 * margin, height: safeHeight + 2 * margin };
  if (!isRect(anchorBounds)) {
    return {
      x: clampAxis(workArea.x + workArea.width - margin - safeWidth, safeWidth, workArea.x, workArea.width, margin),
      y: clampAxis(workArea.y + margin, safeHeight, workArea.y, workArea.height, margin),
      width: safeWidth,
      height: safeHeight,
      side: "fallback",
      anchored: false,
    };
  }

  const leftRoom = anchorBounds.x - (workArea.x + margin);
  const rightRoom = (workArea.x + workArea.width - margin) - (anchorBounds.x + anchorBounds.width);
  const aboveRoom = anchorBounds.y - (workArea.y + margin);
  const belowRoom = (workArea.y + workArea.height - margin) - (anchorBounds.y + anchorBounds.height);
  const centerX = anchorBounds.x + anchorBounds.width / 2;
  const centerY = anchorBounds.y + anchorBounds.height / 2;
  let side;
  let placement;

  if (leftRoom >= safeWidth + gap || rightRoom >= safeWidth + gap) {
    side = leftRoom >= safeWidth + gap && (rightRoom < safeWidth + gap || leftRoom >= rightRoom) ? "left" : "right";
    placement = {
      x: side === "left" ? anchorBounds.x - gap - safeWidth : anchorBounds.x + anchorBounds.width + gap,
      y: centerY - safeHeight / 2,
    };
  } else {
    side = belowRoom >= safeHeight + gap && (aboveRoom < safeHeight + gap || belowRoom >= aboveRoom) ? "below" : "above";
    placement = {
      x: centerX - safeWidth / 2,
      y: side === "below" ? anchorBounds.y + anchorBounds.height + gap : anchorBounds.y - gap - safeHeight,
    };
  }

  return {
    x: clampAxis(placement.x, safeWidth, workArea.x, workArea.width, margin),
    y: clampAxis(placement.y, safeHeight, workArea.y, workArea.height, margin),
    width: safeWidth,
    height: safeHeight,
    side,
    anchored: true,
  };
}

function anchorToTray(trayBounds, edge, width, height, gap) {
  const centerX = trayBounds.x + trayBounds.width / 2;
  const centerY = trayBounds.y + trayBounds.height / 2;
  if (edge === "top") return { x: centerX - width / 2, y: trayBounds.y + trayBounds.height + gap };
  if (edge === "left") return { x: trayBounds.x + trayBounds.width + gap, y: centerY - height / 2 };
  if (edge === "right") return { x: trayBounds.x - gap - width, y: centerY - height / 2 };
  return { x: centerX - width / 2, y: trayBounds.y - gap - height };
}

/// Without trustworthy tray bounds the popover still follows the taskbar: it
/// hugs the work-area corner the notification area lives in, never a hardcoded
/// bottom-right of the screen.
function anchorToWorkAreaCorner(workArea, edge, width, height, margin) {
  const right = workArea.x + workArea.width - margin - width;
  const bottom = workArea.y + workArea.height - margin - height;
  if (edge === "top") return { x: right, y: workArea.y + margin };
  if (edge === "left") return { x: workArea.x + margin, y: bottom };
  return { x: right, y: bottom };
}

function clampAxis(value, size, origin, extent, margin) {
  if (!(extent > size)) return Math.ceil(origin);
  const gutter = extent - size >= 2 * margin ? margin : 0;
  const rounded = Math.round(Math.min(Math.max(value, origin + gutter), origin + extent - gutter - size));
  if (rounded < origin) return Math.ceil(origin);
  if (rounded + size > origin + extent) return Math.floor(origin + extent - size);
  return rounded;
}

/// Acrylic needs Windows 11 22H2 (build 22621). Everywhere else the popover
/// keeps the dashboard's opaque dark surface; the material is decoration only.
export function prefersAcrylic(platform, release) {
  if (platform !== "win32") return false;
  const build = Number.parseInt(String(release || "").split(".")[2], 10);
  return Number.isFinite(build) && build >= 22621;
}
