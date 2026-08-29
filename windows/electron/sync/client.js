import { hostname } from "node:os";
import {
  acceptPairingResponse,
  decodeBase64URL,
  encodeEnvelope,
  makePairingRequest,
  openEnvelope,
  sealSnapshot,
} from "./crypto.js";

const REQUEST_TIMEOUT_MS = 10_000;

export async function pairWithMac({ macURL, pairingCode, sourceInstanceID, deviceName = hostname() }) {
  const baseURL = normalizeMacURL(macURL);
  const secret = decodeBase64URL(pairingCode.trim());
  if (secret.length !== 32) throw new Error("Pairing code must contain 32 bytes of entropy");
  const { request, clientNonce } = makePairingRequest({
    secret,
    sourceInstanceID,
    deviceName,
  });
  const response = await requestJSON(new URL("/v1/pair", baseURL), request);
  return {
    baseURL,
    ...acceptPairingResponse({ secret, request, clientNonce, response }),
  };
}

export async function exchangeSnapshot({
  baseURL,
  snapshot,
  key,
  keyID,
  expectedSourceInstanceID,
  lastRemoteSequence = 0,
}) {
  const envelope = sealSnapshot(snapshot, { key, keyID });
  const response = await fetch(new URL("/v1/snapshot", normalizeMacURL(baseURL)), {
    method: "POST",
    headers: { "Content-Type": "application/json", "Content-Length": String(encodeEnvelope(envelope).length) },
    body: encodeEnvelope(envelope),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    redirect: "error",
  });
  if (!response.ok) throw new Error(await boundedError(response));
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > 32 * 1024) throw new Error("Mac returned an oversized response");
  const responseEnvelope = JSON.parse(bytes.toString("utf8"));
  return validateRemoteSnapshot(
    openEnvelope(responseEnvelope, { key, expectedKeyID: keyID }),
    { expectedSourceInstanceID, lastRemoteSequence },
  );
}

export function validateRemoteSnapshot(snapshot, { expectedSourceInstanceID, lastRemoteSequence = 0 }) {
  if (
    typeof expectedSourceInstanceID !== "string" ||
    snapshot.sourceInstanceID.toLowerCase() !== expectedSourceInstanceID.toLowerCase()
  ) {
    throw new Error("Mac snapshot came from an unexpected source");
  }
  if (!Number.isSafeInteger(lastRemoteSequence) || lastRemoteSequence < 0) {
    throw new Error("Invalid saved Mac sequence");
  }
  if (snapshot.sequence <= lastRemoteSequence) throw new Error("Mac snapshot replay rejected");
  return snapshot;
}

export function normalizeMacURL(value) {
  const url = new URL(String(value).trim());
  if (url.protocol !== "http:") throw new Error("Direct sync currently requires an http:// LAN address");
  if (url.username || url.password || url.search || url.hash) throw new Error("Mac address must not contain credentials or parameters");
  url.pathname = "/";
  return url.toString();
}

async function requestJSON(url, body) {
  const data = Buffer.from(JSON.stringify(body), "utf8");
  if (data.length > 16 * 1024) throw new Error("Pairing request is too large");
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Content-Length": String(data.length) },
    body: data,
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    redirect: "error",
  });
  if (!response.ok) throw new Error(await boundedError(response));
  return response.json();
}

async function boundedError(response) {
  const text = (await response.text()).slice(0, 240).trim();
  return text || `Mac sync request failed (${response.status})`;
}
