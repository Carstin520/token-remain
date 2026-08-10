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
