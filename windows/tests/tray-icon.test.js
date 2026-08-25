import assert from "node:assert/strict";
import test from "node:test";
import { pickTrayProviders, renderTrayIcon } from "../electron/tray-icon.js";

const provider = (remainingPercent, colorHex = "#6687C5") => ({ remainingPercent, colorHex });

test("Tray icon buffers have the requested dimensions and deterministic pixels", () => {
  const options = { mode: "compact", providers: [provider(47), provider(82, "#BF8471")], size: 32 };
  const first = renderTrayIcon(options);
  const second = renderTrayIcon(options);
  assert.deepEqual({ width: first.width, height: first.height, length: first.buffer.length }, { width: 32, height: 32, length: 4_096 });
  assert.ok(first.buffer instanceof Uint8Array);
  assert.deepEqual(first.buffer, second.buffer);
});

test("Ring coverage is roughly proportional and zero draws no opaque arc", () => {
  const opaque = (remainingPercent) => {
    const { buffer } = renderTrayIcon({ mode: "minimal", providers: [provider(remainingPercent)], size: 32 });
    let count = 0;
    for (let index = 3; index < buffer.length; index += 4) if (buffer[index] === 255) count += 1;
    return count;
  };
  const full = opaque(100);
  const half = opaque(50);
  const empty = opaque(0);
  assert.ok(full > half * 1.6, `${full} should be substantially greater than ${half}`);
  assert.ok(half > 0);
  assert.equal(empty, 0);
});

test("Full mode renders distinct crisp bitmap digits", () => {
  const fortySeven = renderTrayIcon({ mode: "full", providers: [provider(47)], size: 32 }).buffer;
  const eightyTwo = renderTrayIcon({ mode: "full", providers: [provider(82)], size: 32 }).buffer;
  assert.notDeepEqual(fortySeven, eightyTwo);
  assert.ok([...fortySeven].some((value, index) => index % 4 === 3 && value === 255));
});

test("Unknown remaining renders only the faint track", () => {
  const { buffer } = renderTrayIcon({ mode: "full", providers: [provider(undefined)], size: 32 });
  const alphas = [...buffer].filter((_value, index) => index % 4 === 3);
  assert.ok(alphas.some((alpha) => alpha > 0));
  assert.ok(alphas.every((alpha) => alpha < 255));
});

test("Provider selection preserves compact order and resolves lowest known quota", () => {
  const providers = [
    { providerID: "claude", remainingPercent: undefined },
    { providerID: "codex", remainingPercent: 58 },
    { providerID: "cursor", remainingPercent: 17 },
    { providerID: "copilot", remainingPercent: 72 },
    { providerID: "devin", remainingPercent: 1 },
  ];
  assert.deepEqual(pickTrayProviders(providers, ["invalid", "claude", "codex", "cursor"], "compact").map((item) => item.providerID), ["claude", "codex"]);
  assert.deepEqual(pickTrayProviders(providers, ["claude", "codex", "cursor"], "minimal").map((item) => item.providerID), ["cursor"]);
  assert.deepEqual(pickTrayProviders(providers, ["claude", "codex"], "full").map((item) => item.providerID), ["codex"]);
  assert.deepEqual(pickTrayProviders(providers, ["claude"], "minimal").map((item) => item.providerID), ["claude"]);
  assert.deepEqual(pickTrayProviders(providers, ["claude", "codex", "cursor", "copilot", "devin"], "minimal").map((item) => item.providerID), ["cursor"]);
});

test("Full mode applies semantic colors only at conventional thresholds", () => {
  const renderedColors = (remainingPercent) => {
    const { buffer } = renderTrayIcon({ mode: "full", providers: [provider(remainingPercent, "#00FF00")], size: 32 });
    const colors = new Set();
    for (let index = 0; index < buffer.length; index += 4) {
      if (buffer[index + 3]) colors.add(`${buffer[index]},${buffer[index + 1]},${buffer[index + 2]}`);
    }
    return colors;
  };
  assert.ok(renderedColors(9).has("255,107,107"));
  assert.ok(renderedColors(10).has("255,181,84"));
  assert.ok(renderedColors(29).has("255,181,84"));
  assert.ok(renderedColors(30).has("242,244,247"));
  assert.ok(!renderedColors(9).has("0,255,0"));
});
