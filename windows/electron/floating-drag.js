// Pure floating-widget drag geometry. BrowserWindow and screen coordinates are
// both expressed in DIP, so the main process only has to validate, round, and
// keep the requested rectangle inside the available display work areas.

export const MAX_FLOATING_DRAG_DELTA = 10_000;

export function applyDragDelta(startBounds, delta, workAreas) {
  if (!isUsableRect(startBounds) || !isUsableDelta(delta)) return undefined;
  const areas = (Array.isArray(workAreas) ? workAreas : []).filter(isUsableRect);
  if (!areas.length) return undefined;

  const desired = {
    x: Math.round(startBounds.x + delta.dx),
    y: Math.round(startBounds.y + delta.dy),
    width: Math.round(startBounds.width),
    height: Math.round(startBounds.height),
  };
  if (isCoveredByWorkAreas(desired, areas)) return desired;

  return areas
    .map((area) => clampToWorkArea(desired, area))
    .reduce((nearest, candidate) => (
      distanceSquared(candidate, desired) < distanceSquared(nearest, desired) ? candidate : nearest
    ));
}

function isUsableRect(rect) {
  return Boolean(rect)
    && Number.isFinite(rect.x) && Number.isFinite(rect.y)
    && Number.isFinite(rect.width) && Number.isFinite(rect.height)
    && rect.width > 0 && rect.height > 0;
}

function isUsableDelta(delta) {
  return Boolean(delta)
    && Number.isFinite(delta.dx) && Number.isFinite(delta.dy)
    && Math.abs(delta.dx) <= MAX_FLOATING_DRAG_DELTA
    && Math.abs(delta.dy) <= MAX_FLOATING_DRAG_DELTA;
}

// A widget may straddle two adjacent monitors. Checking the union by vertical
// slabs accepts that seam while still rejecting holes in L-shaped layouts.
function isCoveredByWorkAreas(rect, workAreas) {
  const right = rect.x + rect.width;
  const bottom = rect.y + rect.height;
  const boundaries = new Set([rect.x, right]);
  for (const area of workAreas) {
    const areaRight = area.x + area.width;
    if (area.x > rect.x && area.x < right) boundaries.add(area.x);
    if (areaRight > rect.x && areaRight < right) boundaries.add(areaRight);
  }
  const xs = [...boundaries].sort((left, rightValue) => left - rightValue);
  for (let index = 0; index < xs.length - 1; index += 1) {
    const sampleX = (xs[index] + xs[index + 1]) / 2;
    const intervals = workAreas
      .filter((area) => sampleX >= area.x && sampleX <= area.x + area.width)
      .map((area) => [Math.max(rect.y, area.y), Math.min(bottom, area.y + area.height)])
      .filter(([start, end]) => end > start)
      .sort((left, rightValue) => left[0] - rightValue[0]);
    let coveredThrough = rect.y;
    for (const [start, end] of intervals) {
      if (start > coveredThrough) break;
      coveredThrough = Math.max(coveredThrough, end);
      if (coveredThrough >= bottom) break;
    }
    if (coveredThrough < bottom) return false;
  }
  return true;
}

function clampToWorkArea(rect, workArea) {
  return {
    x: clampAxis(rect.x, rect.width, workArea.x, workArea.width),
    y: clampAxis(rect.y, rect.height, workArea.y, workArea.height),
    width: rect.width,
    height: rect.height,
  };
}

function clampAxis(value, size, origin, extent) {
  const minimum = Math.ceil(origin);
  const maximum = Math.floor(origin + extent - size);
  if (maximum < minimum) return minimum;
  return Math.min(maximum, Math.max(minimum, Math.round(value)));
}

function distanceSquared(left, right) {
  const dx = left.x - right.x;
  const dy = left.y - right.y;
  return dx * dx + dy * dy;
}
