import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function sourceFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return sourceFiles(entryPath);
    return /\.(?:c?js|mjs)$/.test(entry.name) ? [entryPath] : [];
  }));
  return nested.flat();
}

function relativeImports(source) {
  const imports = [];
  const patterns = [
    /\bfrom\s+["'](\.{1,2}\/[^"']+)["']/g,
    /\bimport\s+["'](\.{1,2}\/[^"']+)["']/g,
    /\brequire\(\s*["'](\.{1,2}\/[^"']+)["']\s*\)/g,
  ];
  for (const pattern of patterns) {
    for (const match of source.matchAll(pattern)) imports.push(match[1]);
  }
  return imports;
}

function packagePatternCovers(pattern, relativePath) {
  const normalizedPattern = pattern.replaceAll("\\", "/");
  const normalizedPath = relativePath.replaceAll("\\", "/");
  if (normalizedPattern.endsWith("/**/*")) {
    return normalizedPath.startsWith(normalizedPattern.slice(0, -4));
  }
  return normalizedPattern === normalizedPath;
}

test("every local Electron runtime import is included in the packaged app", async () => {
  const packageJSON = JSON.parse(await readFile(path.join(projectRoot, "package.json"), "utf8"));
  const packagedFiles = packageJSON.build?.files || [];
  const electronFiles = await sourceFiles(path.join(projectRoot, "electron"));
  const missing = [];

  for (const sourcePath of electronFiles) {
    const source = await readFile(sourcePath, "utf8");
    for (const importPath of relativeImports(source)) {
      const importedPath = path.resolve(path.dirname(sourcePath), importPath);
      const relativePath = path.relative(projectRoot, importedPath);
      if (!packagedFiles.some((pattern) => packagePatternCovers(pattern, relativePath))) {
        missing.push(`${path.relative(projectRoot, sourcePath)} -> ${relativePath}`);
      }
    }
  }

  assert.deepEqual(missing, [], `Runtime imports omitted by build.files:\n${missing.join("\n")}`);
});

test("Windows packages unpack the architecture-specific native ccusage helper", async () => {
  const packageJSON = JSON.parse(await readFile(path.join(projectRoot, "package.json"), "utf8"));
  const lock = JSON.parse(await readFile(path.join(projectRoot, "package-lock.json"), "utf8"));
  assert.equal(packageJSON.dependencies?.ccusage, "20.0.19");
  assert.ok(packageJSON.build?.asar?.unpack?.some((pattern) => pattern.includes("@ccusage") && pattern.includes("ccusage")));
  assert.ok(lock.packages?.["node_modules/@ccusage/ccusage-win32-x64"]?.optional);
  assert.ok(lock.packages?.["node_modules/@ccusage/ccusage-win32-arm64"]?.optional);
  assert.ok(!packageJSON.scripts?.["dist:win"].includes("--x64"), "native ARM64 CI must not be forced back to x64");
});

test("Windows packages include and unpack the native Koffi DWM bridge", async () => {
  const packageJSON = JSON.parse(await readFile(path.join(projectRoot, "package.json"), "utf8"));
  const lock = JSON.parse(await readFile(path.join(projectRoot, "package-lock.json"), "utf8"));
  assert.match(packageJSON.dependencies?.koffi || "", /^\^?3\./);
  assert.ok(packageJSON.build?.asar?.unpack?.includes("node_modules/koffi/**/*"));
  // koffi resolves its prebuilt koffi.node from the sibling @koromix platform
  // package first, so that package must be outside the asar as well.
  assert.ok(packageJSON.build?.asar?.unpack?.includes("node_modules/@koromix/**/*"));
  assert.match(lock.packages?.["node_modules/koffi"]?.version || "", /^3\./);
  assert.equal(lock.packages?.["node_modules/@koromix/koffi-win32-x64"]?.optional, true);
  assert.equal(lock.packages?.["node_modules/@koromix/koffi-win32-arm64"]?.optional, true);
});

test("Windows packages use a generated ICO with a PNG-compressed 256px entry", async () => {
  const packageJSON = JSON.parse(await readFile(path.join(projectRoot, "package.json"), "utf8"));
  assert.equal(packageJSON.build?.win?.icon, "build/icon.ico");

  const icon = await readFile(path.join(projectRoot, "build/icon.ico"));
  assert.deepEqual(icon.subarray(0, 4), Buffer.from([0x00, 0x00, 0x01, 0x00]));
  const entryCount = icon.readUInt16LE(4);
  const entries = Array.from({ length: entryCount }, (_, index) => {
    const offset = 6 + index * 16;
    return {
      width: icon[offset] || 256,
      height: icon[offset + 1] || 256,
      byteLength: icon.readUInt32LE(offset + 8),
      imageOffset: icon.readUInt32LE(offset + 12),
    };
  });
  const largest = entries.find((entry) => entry.width === 256 && entry.height === 256);
  assert.ok(largest, "ICO must contain a 256px entry");
  const png = icon.subarray(largest.imageOffset, largest.imageOffset + largest.byteLength);
  assert.deepEqual(png.subarray(0, 8), Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]));
  assert.equal(png.readUInt32BE(16), 256);
  assert.equal(png.readUInt32BE(20), 256);
});
