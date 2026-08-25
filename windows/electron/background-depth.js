/// macOS DashboardSurfaceLightening parity. The user-facing slider spans the
/// whole 0...1 range, but the surfaces spend only 25% of the trip toward the
/// cool-neutral target so the fixed secondary text keeps WCAG AA contrast.
export const DEFAULT_BACKGROUND_DEPTH = 0;
export const BACKGROUND_DEPTH_STEP = 0.02;
export const MAXIMUM_BACKGROUND_BLEND = 0.25;
export const BACKGROUND_DEPTH_TARGET = "#8a9099";

export function normalizeBackgroundDepth(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return DEFAULT_BACKGROUND_DEPTH;
  const steps = 1 / BACKGROUND_DEPTH_STEP;
  return Math.round(Math.min(Math.max(value, 0), 1) * steps) / steps;
}

export function backgroundDepthCSSPercentage(value) {
  return `${normalizeBackgroundDepth(value) * MAXIMUM_BACKGROUND_BLEND * 100}%`;
}
