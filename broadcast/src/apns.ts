import type { DeviceRow, Env, FeedItemRow, PushKind } from "./types";

let cachedProviderToken: { value: string; issuedAt: number } | undefined;

export interface APNsDelivery {
  kind: PushKind;
  device: DeviceRow;
  item?: FeedItemRow;
  digestCount?: number;
}

export class APNsError extends Error {
  constructor(
    message: string,
    readonly retryable: boolean,
    readonly unregistered: boolean = false,
  ) {
    super(message);
  }
}

export async function sendAPNs(env: Env, delivery: APNsDelivery): Promise<void> {
  const configuration = apnsConfiguration(env);
  const providerToken = await providerJWT(configuration);
  const topic = delivery.device.platform === "macos"
    ? env.APNS_TOPIC_MACOS
    : env.APNS_TOPIC_IOS;
  const host = env.APNS_ENVIRONMENT === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
  const payload = notificationPayload(delivery);

  const response = await fetch(`https://${host}/3/device/${delivery.device.apns_token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${providerToken}`,
      "apns-expiration": String(Math.floor(Date.now() / 1_000) + 86_400),
      "apns-priority": "10",
      "apns-push-type": "alert",
      "apns-topic": topic,
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (response.ok) return;

  let reason = `APNs ${response.status}`;
  try {
    const body = await response.json<{ reason?: string }>();
    if (body.reason) reason = `${reason}: ${body.reason}`;
  } catch {
    // APNs may return an empty body; the status remains sufficient for logs.
  }
  if (response.status === 410) throw new APNsError(reason, false, true);
  if (response.status === 429 || response.status >= 500 || response.status === 403) {
    throw new APNsError(reason, true);
  }
  throw new APNsError(reason, false);
}

function apnsConfiguration(env: Env): {
  keyID: string;
  teamID: string;
  privateKey: string;
} {
  const keyID = env.APNS_KEY_ID?.trim();
  const teamID = env.APNS_TEAM_ID?.trim();
  const privateKey = env.APNS_PRIVATE_KEY?.trim().replace(/\\n/g, "\n");
  if (!keyID || !teamID || !privateKey) {
    throw new APNsError("APNs credentials are not configured", true);
  }
  return { keyID, teamID, privateKey };
}

async function providerJWT(configuration: {
  keyID: string;
  teamID: string;
  privateKey: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1_000);
  if (cachedProviderToken && now - cachedProviderToken.issuedAt < 50 * 60) {
    return cachedProviderToken.value;
  }

  const header = base64url(JSON.stringify({ alg: "ES256", kid: configuration.keyID }));
  const claims = base64url(JSON.stringify({ iss: configuration.teamID, iat: now }));
  const input = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(configuration.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(input),
  );
  const value = `${input}.${base64url(new Uint8Array(signature))}`;
  cachedProviderToken = { value, issuedAt: now };
  return value;
}

function notificationPayload(delivery: APNsDelivery): Record<string, unknown> {
  if (delivery.kind === "daily_digest") {
    const isChinese = delivery.device.locale.toLowerCase().startsWith("zh");
    const title = isChinese
      ? "TokenRemain · 今日 X 动态"
      : "TokenRemain · Today's X updates";
    const body = isChinese
      ? (delivery.digestCount
        ? `今天有 ${delivery.digestCount} 条新动态，点击查看。`
        : "点击查看最新 X 动态。")
      : (delivery.digestCount
        ? `${delivery.digestCount} new update${delivery.digestCount === 1 ? "" : "s"} today.`
        : "See the latest X update.");
    return {
      aps: {
        alert: {
          title,
          body,
        },
        sound: "default",
        "thread-id": "tokenremain-feed",
      },
      route: "feed",
    };
  }
  const item = delivery.item;
  if (!item) throw new APNsError("push item is missing", false);
  return {
    aps: {
      alert: {
        title: `TokenRemain · @${item.author_username}`,
        subtitle: item.author_display_name,
        body: truncate(item.text, 180),
      },
      sound: "default",
      "thread-id": "tokenremain-feed",
    },
    feedItemID: item.id,
    url: item.url,
    route: "feed",
  };
}

function pemBytes(pem: string): ArrayBuffer {
  const value = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const binary = atob(value);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return bytes.buffer;
}

function base64url(value: string | Uint8Array): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function truncate(value: string, maximum: number): string {
  return value.length <= maximum ? value : `${value.slice(0, maximum - 1)}…`;
}
