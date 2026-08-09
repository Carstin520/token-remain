// Presentation helpers for the popover's local-usage ring. Keeping the
// geometry outside React makes the rendered chart deterministic and gives the
// pointer hit-testing the same segment boundaries as the visible gradient.

function ringEntries(entries = []) {
  return entries.filter((entry) => Number.isFinite(entry?.tokens) && entry.tokens > 0 && typeof entry.color === "string");
}

export function usageRingStops(entries, highlightedID) {
  const usable = ringEntries(entries);
  const total = usable.reduce((sum, entry) => sum + entry.tokens, 0);
  if (!(total > 0)) return "var(--track) 0% 100%";
  let running = 0;
  return usable.flatMap((entry) => {
    const start = running / total * 100;
    running += entry.tokens;
    const end = running / total * 100;
    const color = highlightedID && highlightedID !== entry.id
      ? `color-mix(in srgb, ${entry.color} 32%, transparent)`
      : entry.color;
    return [`${color} ${start}%`, `${color} ${end}%`];
  }).join(", ");
}

export function usageRingSegmentAtPoint(entries, point, size, lineWidth = 8) {
  const usable = ringEntries(entries);
  const total = usable.reduce((sum, entry) => sum + entry.tokens, 0);
  if (!(total > 0) || !Number.isFinite(size) || size <= 0) return undefined;

  const radius = size / 2;
  const x = point.x - radius;
  const y = point.y - radius;
  const distance = Math.hypot(x, y);
  const outerRadius = radius;
  const innerRadius = Math.max(0, outerRadius - lineWidth - 2);
  if (distance < innerRadius || distance > outerRadius) return undefined;

  let degrees = Math.atan2(y, x) * 180 / Math.PI + 90;
  if (degrees < 0) degrees += 360;
  const target = degrees / 360 * total;
  let running = 0;
  for (const entry of usable) {
    running += entry.tokens;
    if (target < running) return entry.id;
  }
  return usable.at(-1)?.id;
}
