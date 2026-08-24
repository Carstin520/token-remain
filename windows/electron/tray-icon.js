const DISPLAY_MODES = new Set(["full", "compact", "minimal"]);
const SEMANTIC_COLORS = Object.freeze({
  danger: "#FF6B6B",
  warning: "#FFB554",
  neutral: "#F2F4F7",
});

const DIGITS = Object.freeze({
  0: ["111", "101", "101", "101", "111"],
  1: ["010", "110", "010", "010", "111"],
  2: ["111", "001", "111", "100", "111"],
  3: ["111", "001", "111", "001", "111"],
  4: ["101", "101", "111", "001", "001"],
  5: ["111", "100", "111", "001", "111"],
  6: ["111", "100", "111", "101", "111"],
  7: ["111", "001", "010", "010", "010"],
  8: ["111", "101", "111", "101", "111"],
  9: ["111", "101", "111", "001", "111"],
});

export function pickTrayProviders(providers, selectedIDs, mode = "full") {
  const byID = new Map((Array.isArray(providers) ? providers : []).flatMap((provider) => {
    const id = provider?.providerID ?? provider?.id;
    return typeof id === "string" && id ? [[id, provider]] : [];
  }));
  const selected = [];
  const seen = new Set();
  for (const id of Array.isArray(selectedIDs) ? selectedIDs : []) {
    if (selected.length >= 4) break;
    if (typeof id !== "string" || seen.has(id) || !byID.has(id)) continue;
    seen.add(id);
    selected.push(byID.get(id));
  }

  if (mode === "compact") return selected.slice(0, 2);
  if (!selected.length) return [];
  return [selected.reduce((lowest, candidate) => (
    comparableRemaining(candidate?.remainingPercent) < comparableRemaining(lowest?.remainingPercent)
      ? candidate
      : lowest
  ))];
}

export function renderTrayIcon(options = {}) {
  const size = normalizedSize(options.size);
  const mode = DISPLAY_MODES.has(options.mode) ? options.mode : "full";
  const providers = (Array.isArray(options.providers) ? options.providers : []).slice(0, 4);
  const buffer = new Uint8Array(size * size * 4);
  if (!providers.length) return { width: size, height: size, buffer };

  if (mode === "compact") {
    const visible = providers.slice(0, 2);
    if (visible[0]) drawRing(buffer, size, {
      radius: size * 0.365,
      stroke: size * 0.115,
      remainingPercent: visible[0].remainingPercent,
      color: parseHex(visible[0].colorHex),
    });
    if (visible[1]) drawRing(buffer, size, {
      radius: size * 0.19,
      stroke: size * 0.105,
      remainingPercent: visible[1].remainingPercent,
      color: parseHex(visible[1].colorHex),
    });
    return { width: size, height: size, buffer };
  }

  const provider = providers.reduce((lowest, candidate) => (
    comparableRemaining(candidate?.remainingPercent) < comparableRemaining(lowest?.remainingPercent)
      ? candidate
      : lowest
  ));
  const color = mode === "full"
    ? parseHex(semanticColor(provider?.remainingPercent))
    : parseHex(provider?.colorHex);
  drawRing(buffer, size, {
    radius: size * 0.365,
    stroke: size * 0.12,
    remainingPercent: provider?.remainingPercent,
    color,
  });
  if (mode === "full" && Number.isFinite(provider?.remainingPercent)) {
    drawNumber(buffer, size, Math.round(clamp(provider.remainingPercent, 0, 100)), color);
  }
  return { width: size, height: size, buffer };
}

function drawRing(buffer, size, { radius, stroke, remainingPercent, color }) {
  drawSampledShape(buffer, size, color, 0.2, (x, y) => (
    Math.abs(Math.hypot(x, y) - radius) <= stroke / 2
  ));
  if (!Number.isFinite(remainingPercent)) return;
  const fraction = clamp(remainingPercent / 100, 0, 1);
  if (fraction <= 0) return;
  drawSampledShape(buffer, size, color, 1, (x, y) => pointOnArc(x, y, radius, stroke, fraction));
}

function drawSampledShape(buffer, size, color, opacity, contains) {
  const samples = 4;
  const center = size / 2;
  for (let py = 0; py < size; py += 1) {
    for (let px = 0; px < size; px += 1) {
      let covered = 0;
      for (let sy = 0; sy < samples; sy += 1) {
        for (let sx = 0; sx < samples; sx += 1) {
          const x = px + (sx + 0.5) / samples - center;
          const y = py + (sy + 0.5) / samples - center;
          if (contains(x, y)) covered += 1;
        }
      }
      if (covered) blendPixel(buffer, (py * size + px) * 4, color, opacity * covered / (samples * samples));
    }
  }
}

function pointOnArc(x, y, radius, stroke, fraction) {
  if (fraction >= 1) return Math.abs(Math.hypot(x, y) - radius) <= stroke / 2;
  let angle = Math.atan2(x, -y);
  if (angle < 0) angle += Math.PI * 2;
  const endAngle = fraction * Math.PI * 2;
  if (angle <= endAngle && Math.abs(Math.hypot(x, y) - radius) <= stroke / 2) return true;
  const halfStroke = stroke / 2;
  const startDistance = Math.hypot(x, y + radius);
  const endX = Math.sin(endAngle) * radius;
  const endY = -Math.cos(endAngle) * radius;
  return startDistance <= halfStroke || Math.hypot(x - endX, y - endY) <= halfStroke;
}

function drawNumber(buffer, size, value, color) {
  const text = String(value);
  const unscaledWidth = text.length * 3 + Math.max(0, text.length - 1);
  const scale = Math.max(1, Math.floor(Math.min((size * 0.7) / unscaledWidth, (size * 0.42) / 5)));
  const width = unscaledWidth * scale;
  const height = 5 * scale;
  const left = Math.floor((size - width) / 2);
  const top = Math.floor((size - height) / 2);
  for (let digitIndex = 0; digitIndex < text.length; digitIndex += 1) {
    const glyph = DIGITS[text[digitIndex]];
    if (!glyph) continue;
    for (let row = 0; row < 5; row += 1) {
      for (let column = 0; column < 3; column += 1) {
        if (glyph[row][column] !== "1") continue;
        const originX = left + digitIndex * 4 * scale + column * scale;
        const originY = top + row * scale;
        for (let y = 0; y < scale; y += 1) {
          for (let x = 0; x < scale; x += 1) {
            const px = originX + x;
            const py = originY + y;
            if (px >= 0 && px < size && py >= 0 && py < size) {
              blendPixel(buffer, (py * size + px) * 4, color, 1);
            }
          }
        }
      }
    }
  }
}

function blendPixel(buffer, offset, color, sourceAlpha) {
  const destinationAlpha = buffer[offset + 3] / 255;
  const outputAlpha = sourceAlpha + destinationAlpha * (1 - sourceAlpha);
  if (outputAlpha <= 0) return;
  for (let channel = 0; channel < 3; channel += 1) {
    const destination = buffer[offset + channel];
    buffer[offset + channel] = Math.round((color[channel] * sourceAlpha + destination * destinationAlpha * (1 - sourceAlpha)) / outputAlpha);
  }
  buffer[offset + 3] = Math.round(outputAlpha * 255);
}

function semanticColor(value) {
  if (!Number.isFinite(value)) return SEMANTIC_COLORS.neutral;
  if (value < 10) return SEMANTIC_COLORS.danger;
  if (value < 30) return SEMANTIC_COLORS.warning;
  return SEMANTIC_COLORS.neutral;
}

function parseHex(value) {
  const match = /^#([0-9a-f]{6})$/i.exec(String(value || ""));
  const hex = match?.[1] || SEMANTIC_COLORS.neutral.slice(1);
  return [0, 2, 4].map((offset) => Number.parseInt(hex.slice(offset, offset + 2), 16));
}

function comparableRemaining(value) {
  return Number.isFinite(value) ? clamp(value, 0, 100) : Number.POSITIVE_INFINITY;
}

function normalizedSize(value) {
  return Number.isInteger(value) && value > 0 ? value : 16;
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}
