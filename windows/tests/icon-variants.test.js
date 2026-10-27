import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { inflateSync } from "node:zlib";
import test from "node:test";

function decodeEntry(png) {
  const width = png.readUInt32BE(16);
  const height = png.readUInt32BE(20);
  assert.equal(png[24], 8);
  assert.equal(png[25], 6);
  const chunks = [];
  for (let offset = 8; offset + 12 <= png.length;) {
    const length = png.readUInt32BE(offset);
    if (png.toString("ascii", offset + 4, offset + 8) === "IDAT") chunks.push(png.subarray(offset + 8, offset + 8 + length));
    offset += length + 12;
  }
  const rows = inflateSync(Buffer.concat(chunks));
  // generate-ico deliberately emits unfiltered RGBA rows.
  for (let y = 0; y < height; y += 1) assert.equal(rows[y * (width * 4 + 1)], 0);
  return { width, height, pixel(x, y) { return rows.subarray(y * (width * 4 + 1) + 1 + x * 4, y * (width * 4 + 1) + 5 + x * 4); } };
}

function litRingComponents(image) {
  const candidates = new Set();
  const n = image.width;
  for (let y = 0; y < n; y += 1) for (let x = 0; x < n; x += 1) {
    const [r, g, b] = image.pixel(x, y);
    if (Math.hypot(x + 0.5 - n / 2, y + 0.5 - n / 2) > n * 0.33 && g > 100 && b > 100 && g - r > 60) candidates.add(y * n + x);
  }
  let count = 0;
  while (candidates.size) {
    count += 1;
    const start = candidates.values().next().value;
    candidates.delete(start);
    const pending = [start];
    while (pending.length) {
      const current = pending.pop();
      const x = current % n;
      for (const neighbor of [current - n, current + n, ...(x > 0 ? [current - 1] : []), ...(x < n - 1 ? [current + 1] : [])]) {
        if (candidates.delete(neighbor)) pending.push(neighbor);
      }
    }
  }
  return count;
}

test("ICO entries use head-only, ten-dot and twenty-dot artwork at their actual pixel sizes", async () => {
  const ico = await readFile(new URL("../build/icon.ico", import.meta.url));
  const expected = [[16, 0], [24, 0], [32, 8], [48, 8], [64, 15], [128, 15], [256, 15]];
  assert.equal(ico.readUInt16LE(4), expected.length);
  for (let i = 0; i < expected.length; i += 1) {
    const [size, lit] = expected[i];
    const offset = 6 + i * 16;
    const length = ico.readUInt32LE(offset + 8);
    const start = ico.readUInt32LE(offset + 12);
    const image = decodeEntry(ico.subarray(start, start + length));
    assert.equal(image.width, size);
    assert.equal(image.height, size);
    assert.equal(litRingComponents(image), lit, `${size}px must select the correct geometry`);
  }
});

test("the small fallback source ships as an extra resource for the native tray", async () => {
  const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
  assert.ok(pkg.build.extraResources.some(item => item.from === "../site/assets/brand/appicon-small.png" && item.to === "appicon-small.png"));
  const main = await readFile(new URL("../electron/main.js", import.meta.url), "utf8");
  assert.match(main, /createFromPath\(trayFallbackIconPath\(\)\)/);
});
