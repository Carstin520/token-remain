import { readFile } from "node:fs/promises";

export async function readBoundedJSON(path, maxBytes = 1024 * 1024) {
  const data = await readFile(path);
  if (data.length > maxBytes) throw new Error("Credential file is unexpectedly large");
  return JSON.parse(data.toString("utf8"));
}

export function number(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value);
  return undefined;
}

export function clampPercent(value) {
  return Math.min(100, Math.max(0, value));
}

export function parseReset(value) {
  if (typeof value === "string" && value.trim()) {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  const numeric = number(value);
  if (!numeric || numeric <= 0) return undefined;
  return numeric < 1e10 ? Math.trunc(numeric * 1000) : Math.trunc(numeric);
}

export function decodeJWTExpiry(token) {
  try {
    const payload = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
    return number(payload.exp) ? payload.exp * 1000 : undefined;
  } catch {
    return undefined;
  }
}

export async function fetchJSON(url, options, { fetchImpl = fetch, timeoutMs = 10_000 } = {}) {
  const response = await fetchImpl(url, {
    ...options,
    signal: AbortSignal.timeout(timeoutMs),
    redirect: "error",
  });
  if (!response.ok) throw new Error(`Request failed (${response.status})`);
  const contentLength = number(response.headers.get("content-length"));
  if (contentLength && contentLength > 1024 * 1024) throw new Error("Provider response is unexpectedly large");
  return response.json();
}
