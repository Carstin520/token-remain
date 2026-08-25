import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const LOCALES = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "de"];
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = join(scriptDirectory, "..", "..");
const outputPath = join(scriptDirectory, "..", "src", "locales.generated.js");

function decodeQuoted(value) {
  return JSON.parse(`"${value}"`);
}

function parseStrings(source, locale) {
  const messages = {};
  const pattern = /^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";\s*$/gm;
  for (const match of source.matchAll(pattern)) {
    messages[decodeQuoted(match[1])] = decodeQuoted(match[2]);
  }
  if (Object.keys(messages).length < 500) {
    throw new Error(`Localization catalog ${locale} is incomplete (${Object.keys(messages).length} entries)`);
  }
  return messages;
}

const catalogs = {};
for (const locale of LOCALES) {
  const path = join(repositoryRoot, "Sources", "UsageDock", "Localization", `${locale}.lproj`, "Localizable.strings");
  catalogs[locale] = parseStrings(await readFile(path, "utf8"), locale);
}

await mkdir(dirname(outputPath), { recursive: true });
await writeFile(
  outputPath,
  `// Generated from Sources/UsageDock/Localization by scripts/generate-locales.mjs.\nexport default ${JSON.stringify(catalogs, null, 2)};\n`,
);
