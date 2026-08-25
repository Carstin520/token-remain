import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";
import { PROVIDER_CATALOG } from "./catalog.js";

export const DESKTOP_APP_PROVIDER_IDS = new Set(["claude", "codex"]);

function clean(value) {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function firstEnvironment(env, names) {
  for (const name of names) {
    const direct = clean(env[name]);
    if (direct) return direct;
    const key = Object.keys(env).find((candidate) => candidate.toLowerCase() === name.toLowerCase());
    const fallback = key ? clean(env[key]) : undefined;
    if (fallback) return fallback;
  }
  return undefined;
}

function anyExists(paths, exists = existsSync) {
  return paths.filter(Boolean).some((path) => exists(path));
}

function directoryContains(directory, prefix, readDirectory = readdirSync) {
  try {
    return readDirectory(directory).some((name) => String(name).toLowerCase().startsWith(prefix.toLowerCase()));
  } catch {
    return false;
  }
}

function executableExists(names, { env, home, exists, platform }) {
  const pathValue = firstEnvironment(env, ["PATH"]) || "";
  const extensions = platform === "win32" ? ["", ".exe", ".cmd", ".bat"] : [""];
  const directories = [
    ...pathValue.split(platform === "win32" ? ";" : delimiter).filter(Boolean),
    join(home, ".local", "bin"),
    join(home, ".npm-global", "bin"),
  ];
  return directories.some((directory) => names.some((name) => extensions.some((extension) => exists(join(directory, `${name}${extension}`)))));
}

function automaticDetection(id, context) {
  const { env, home, appData, localAppData, programFiles, programFilesX86, exists, readDirectory } = context;
  const programs = (...parts) => localAppData ? join(localAppData, "Programs", ...parts) : undefined;
  const app = (...parts) => appData ? join(appData, ...parts) : undefined;
  const systemPrograms = (name) => [programFiles && join(programFiles, name), programFilesX86 && join(programFilesX86, name)];
  const storePackages = localAppData ? join(localAppData, "Packages") : undefined;
  const installed = (() => {
    switch (id) {
      case "claude":
        return anyExists([join(home, ".claude"), programs("Claude"), app("Claude"), ...systemPrograms("Claude")], exists)
          || (storePackages && directoryContains(storePackages, "Anthropic.Claude", readDirectory))
          || executableExists(["claude"], context);
      case "codex":
        return anyExists([join(home, ".codex"), programs("ChatGPT"), programs("Codex"), app("ChatGPT"), app("Codex"), ...systemPrograms("ChatGPT"), ...systemPrograms("Codex")], exists)
          || (storePackages && directoryContains(storePackages, "OpenAI.ChatGPT", readDirectory))
          || executableExists(["codex"], context);
      case "cursor":
        return anyExists([app("Cursor"), programs("Cursor"), join(home, ".cursor"), ...systemPrograms("Cursor")], exists);
      case "copilot":
        return anyExists([
          join(home, ".config", "github-copilot"),
          join(home, ".config", "gh", "hosts.yml"),
        ], exists)
          || directoryContains(join(home, ".vscode", "extensions"), "github.copilot", readDirectory)
          || directoryContains(join(home, ".cursor", "extensions"), "github.copilot", readDirectory);
      case "devin":
        return anyExists([join(home, ".local", "share", "devin"), app("Devin"), programs("Devin"), ...systemPrograms("Devin")], exists);
      case "windsurf":
        return Boolean(clean(env.WINDSURF_API_KEY))
          || anyExists([app("Windsurf"), programs("Windsurf"), join(home, ".codeium", "windsurf"), ...systemPrograms("Windsurf")], exists);
      case "grok":
        return anyExists([join(home, ".grok", "auth.json")], exists) || executableExists(["grok"], context);
      case "antigravity":
        return anyExists([app("Antigravity"), programs("Antigravity"), ...systemPrograms("Antigravity")], exists);
      case "opencode":
        return anyExists([
          clean(env.OPENCODE_DATA_DIR),
          clean(env.XDG_DATA_HOME) && join(env.XDG_DATA_HOME, "opencode"),
          join(home, ".local", "share", "opencode"),
        ], exists) || executableExists(["opencode"], context);
      case "kiro":
        return anyExists([app("Kiro"), programs("Kiro"), ...systemPrograms("Kiro")], exists)
          || executableExists(["kiro-cli", "kiro"], context);
      default:
        return false;
    }
  })();
  const desktopAppPath = resolveProviderDesktopAppPath(id, context);
  return {
    providerID: id,
    installed,
    configured: installed,
    ...(DESKTOP_APP_PROVIDER_IDS.has(id) ? { launchable: Boolean(desktopAppPath) } : {}),
    access: "local-session",
    detail: installed ? `Detected ${context.definition.product} on this PC` : `Install and sign in to ${context.definition.product}`,
  };
}

/// Resolve only allow-listed, known executable locations. The renderer sends a
/// provider ID, never a filesystem path; the main process repeats this lookup
/// immediately before launching the app.
export function resolveProviderDesktopAppPath(providerID, {
  env = process.env,
  platform = process.platform,
  exists = existsSync,
  readDirectory = readdirSync,
} = {}) {
  if (platform !== "win32" || !DESKTOP_APP_PROVIDER_IDS.has(providerID)) return undefined;
  const localAppData = firstEnvironment(env, ["LOCALAPPDATA"]);
  const appData = firstEnvironment(env, ["APPDATA"]);
  const programFiles = firstEnvironment(env, ["PROGRAMFILES"]);
  const programFilesX86 = firstEnvironment(env, ["PROGRAMFILES(X86)"]);
  const names = providerID === "claude" ? ["Claude"] : ["ChatGPT", "Codex"];
  const directCandidates = names.flatMap((name) => [
    localAppData && join(localAppData, "Programs", name, `${name}.exe`),
    localAppData && join(localAppData, name, `${name}.exe`),
    localAppData && join(localAppData, "Microsoft", "WindowsApps", `${name}.exe`),
    appData && join(appData, name, `${name}.exe`),
    programFiles && join(programFiles, name, `${name}.exe`),
    programFilesX86 && join(programFilesX86, name, `${name}.exe`),
  ]).filter(Boolean);
  const direct = directCandidates.find((candidate) => exists(candidate));
  if (direct) return direct;

  // Squirrel-style installs keep the executable under app-<version>.
  for (const name of names) {
    for (const root of [localAppData && join(localAppData, name), appData && join(appData, name)].filter(Boolean)) {
      const versions = directoryEntries(root, readDirectory)
        .filter((child) => child.toLowerCase().startsWith("app-"))
        .sort((left, right) => right.localeCompare(left, undefined, { numeric: true }));
      const versioned = versions
        .map((child) => join(root, child, `${name}.exe`))
        .find((candidate) => exists(candidate));
      if (versioned) return versioned;
    }
  }
  return undefined;
}

function manualConfigExists(definition, context) {
  const { env, home, exists, hasStoredSecret } = context;
  if (definition.environmentKeys.some((name) => clean(env[name]))) return true;
  if (hasStoredSecret(definition.id)) return true;
  if (definition.id === "zai" && exists(join(home, ".config", "zai", "key.json"))) return true;
  if (definition.id === "openrouter" && exists(join(home, ".config", "openrouter", "key.json"))) return true;
  return false;
}

function manualLocalInstall(definition, context) {
  const { env, home, appData, localAppData, exists } = context;
  const app = (...parts) => appData ? join(appData, ...parts) : undefined;
  const programs = (...parts) => localAppData ? join(localAppData, "Programs", ...parts) : undefined;
  switch (definition.id) {
    case "zai":
      return anyExists([clean(env.ZCODE_HOME), join(home, ".zcode"), app("ZCode"), programs("ZCode")], exists);
    case "kimi":
      return anyExists([clean(env.KIMI_CODE_HOME), join(home, ".kimi-code"), app("Kimi Code"), programs("Kimi Code")], exists);
    case "qoder":
      return anyExists([
        clean(env.QODER_HOME),
        clean(env.QODER_CN_HOME),
        app("Qoder"),
        app("QoderCN"),
        programs("Qoder"),
        programs("QoderCN"),
      ], exists);
    default:
      return false;
  }
}

export function detectLocalProviders({
  env = process.env,
  home = firstEnvironment(env, ["USERPROFILE", "HOME"]) || homedir(),
  platform = process.platform,
  exists = existsSync,
  readDirectory = readdirSync,
  hasStoredSecret = () => false,
} = {}) {
  const context = {
    env,
    home,
    appData: firstEnvironment(env, ["APPDATA"]),
    localAppData: firstEnvironment(env, ["LOCALAPPDATA"]),
    programFiles: firstEnvironment(env, ["PROGRAMFILES"]),
    programFilesX86: firstEnvironment(env, ["PROGRAMFILES(X86)"]),
    exists,
    readDirectory,
    hasStoredSecret,
    platform,
  };
  return PROVIDER_CATALOG.map((definition) => {
    if (definition.access === "local-session") {
      return automaticDetection(definition.id, { ...context, definition });
    }
    const configured = manualConfigExists(definition, context);
    const locallyInstalled = manualLocalInstall(definition, context);
    return {
      providerID: definition.id,
      installed: configured || locallyInstalled,
      configured,
      access: definition.access,
      credentialKind: definition.credentialKind,
      detail: configured
        ? `${definition.credentialKind} is configured locally on this PC`
        : locallyInstalled
          ? `Detected ${definition.product}; TokenRemain will try its local session before ${definition.credentialKind}`
        : `Add a ${definition.credentialKind} locally in Data Sources`,
    };
  });
}

function directoryEntries(directory, readDirectory) {
  try {
    return readDirectory(directory).map((entry_) => typeof entry_ === "string" ? entry_ : entry_?.name).filter(Boolean);
  } catch {
    return [];
  }
}
