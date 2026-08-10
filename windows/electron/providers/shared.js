import { execFile } from "node:child_process";
import { existsSync as fileExistsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export function numeric(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value);
  return undefined;
}

export function clamp(value) {
  return Math.min(100, Math.max(0, Number(value)));
}

export function timestamp(value) {
  const number = numeric(value);
  if (number !== undefined && number > 0) return Math.trunc(number < 1e10 ? number * 1000 : number);
  const parsed = typeof value === "string" ? Date.parse(value) : NaN;
  return Number.isFinite(parsed) ? parsed : undefined;
}

export function environmentValue(env, name) {
  if (typeof env[name] === "string") return env[name];
  const key = Object.keys(env).find((candidate) => candidate.toLowerCase() === name.toLowerCase());
  return key ? env[key] : undefined;
}

export function windowsHome(env = process.env) {
  return String(environmentValue(env, "USERPROFILE") || environmentValue(env, "HOME") || homedir());
}

export async function readSmallText(path, maximum = 2 * 1024 * 1024) {
  const data = await readFile(path);
  if (data.length > maximum) throw new Error("Local provider file is unexpectedly large");
  return data.toString("utf8");
}

export async function readSmallJSON(path, maximum) {
  return JSON.parse(await readSmallText(path, maximum));
}

export async function fetchPayload(url, options = {}, { fetchImpl = fetch, timeoutMs = 15_000, text = false } = {}) {
  const response = await fetchImpl(url, {
    ...options,
    signal: AbortSignal.timeout(timeoutMs),
    redirect: "error",
  });
  if (!response.ok) {
    if (response.status === 401 || response.status === 403) throw new Error(`Local credential was rejected (${response.status})`);
    throw new Error(`Provider request failed (${response.status})`);
  }
  const length = numeric(response.headers.get("content-length"));
  if (length && length > 4 * 1024 * 1024) throw new Error("Provider response is unexpectedly large");
  return text ? response.text() : response.json();
}

export async function sqliteRows(path, sql, parameters = []) {
  // Electron 43 ships Node's read-only SQLite API. Keeping this as a dynamic
  // import lets the source/test suite still run on older development Nodes.
  const { DatabaseSync } = await import("node:sqlite");
  const database = new DatabaseSync(path, { readOnly: true });
  try {
    return database.prepare(sql).all(...parameters);
  } finally {
    database.close();
  }
}

export async function sqliteValue(path, key) {
  const rows = await sqliteRows(path, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", [key]);
  const value = rows[0]?.value;
  if (value === undefined || value === null) return undefined;
  const text = String(value).trim();
  if (!text) return undefined;
  if (text.startsWith("\"") && text.endsWith("\"")) {
    try { return JSON.parse(text); } catch { return text.slice(1, -1); }
  }
  return text;
}

export function findExecutable(names, { env = process.env, home = windowsHome(env), existsSync, platform = process.platform } = {}) {
  const exists = existsSync || fileExistsSync;
  const pathValue = environmentValue(env, "PATH") || "";
  const localAppData = environmentValue(env, "LOCALAPPDATA");
  const programFiles = environmentValue(env, "PROGRAMFILES") || "C:\\Program Files";
  const candidates = [
    ...pathValue.split(platform === "win32" ? ";" : delimiter).filter(Boolean).flatMap((directory) => names.map((name) => join(directory, name))),
    ...names.map((name) => join(home, ".local", "bin", name)),
    ...(localAppData ? names.map((name) => join(localAppData, "Programs", name.replace(/-cli(?:\.exe)?$/i, ""), name)) : []),
    ...names.map((name) => join(programFiles, name.replace(/-cli(?:\.exe)?$/i, ""), name)),
  ];
  return candidates.find(exists);
}

export async function runExecutable(command, args, options = {}) {
  const result = await execFileAsync(command, args, {
    windowsHide: true,
    timeout: options.timeoutMs || 30_000,
    maxBuffer: options.maxBuffer || 2 * 1024 * 1024,
    env: options.env || process.env,
  });
  return `${result.stdout || ""}\n${result.stderr || ""}`;
}

export function quota(providerID, windows, { now = Date.now(), planName, remainingBalance, scopedWindows } = {}) {
  if (!windows.length) throw new Error(`${providerID} returned no usable quota window`);
  return {
    providerID,
    capturedAt: now,
    ...(planName ? { planName } : {}),
    windows,
    ...(remainingBalance ? { remainingBalance } : {}),
    ...(scopedWindows?.length ? { scopedWindows } : {}),
  };
}

export function balanceWindow(amount, currencyCode, usedPercent = 0) {
  const remainingBalance = { amount: Math.max(0, amount), currencyCode: String(currencyCode || "").toUpperCase() };
  return { usedPercent: clamp(usedPercent), windowMinutes: 0, remainingBalance };
}

export function titleCase(value) {
  const text = String(value || "").trim();
  return text ? text.split(/[_\-\s]+/).map((part) => part.charAt(0).toUpperCase() + part.slice(1).toLowerCase()).join(" ") : undefined;
}
