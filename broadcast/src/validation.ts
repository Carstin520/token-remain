import { HttpError } from "./http";
import type { FeedPriority, FeedTier, Platform } from "./types";

const installationPattern = /^[A-Za-z0-9_-]{16,128}$/;
const registrationKeyPattern = /^[A-Za-z0-9_-]{32,128}$/;
const apnsTokenPattern = /^[a-fA-F0-9]{64,256}$/;
const usernamePattern = /^[A-Za-z0-9_]{1,15}$/;

export interface DeviceRegistration {
  installationId: string;
  registrationKey: string;
  deviceToken: string;
  platform: Platform;
  locale: string;
  timezone: string;
  notificationsEnabled: boolean;
}

export interface AdminFeedItem {
  id: string;
  text: string;
  authorUsername: string;
  authorDisplayName: string;
  publishedAt: string;
  url: string;
  priority: FeedPriority;
  tier: FeedTier;
  metrics: {
    likes: number;
    reposts: number;
    replies: number;
  };
}

export function validateRegistration(value: unknown): DeviceRegistration {
  const body = record(value);
  const installationId = requiredString(body, "installationId", 128);
  const registrationKey = requiredString(body, "registrationKey", 128);
  const deviceToken = requiredString(body, "deviceToken", 256);
  const platform = requiredString(body, "platform", 16);
  const locale = requiredString(body, "locale", 32);
  const timezone = requiredString(body, "timezone", 64);

  if (!installationPattern.test(installationId)) throw new HttpError(400, "invalid installationId");
  if (!registrationKeyPattern.test(registrationKey)) throw new HttpError(400, "invalid registrationKey");
  if (!apnsTokenPattern.test(deviceToken)) throw new HttpError(400, "invalid deviceToken");
  if (!["macos", "ios", "ipados"].includes(platform)) throw new HttpError(400, "invalid platform");
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: timezone }).format(new Date());
  } catch {
    throw new HttpError(400, "invalid timezone");
  }

  return {
    installationId,
    registrationKey,
    deviceToken: deviceToken.toLowerCase(),
    platform: platform as Platform,
    locale,
    timezone,
    notificationsEnabled: body.notificationsEnabled !== false,
  };
}

export function validateAdminFeedItem(value: unknown): AdminFeedItem {
  const body = record(value);
  const metrics = body.metrics === undefined ? {} : record(body.metrics);
  const id = requiredString(body, "id", 128);
  const text = requiredString(body, "text", 2_000);
  const authorUsername = requiredString(body, "authorUsername", 15);
  const authorDisplayName = requiredString(body, "authorDisplayName", 100);
  const publishedAt = requiredString(body, "publishedAt", 40);
  const url = requiredString(body, "url", 500);
  const priority = optionalEnum(body.priority, ["token_reset", "major_update", "normal"], "normal");
  const tier = optionalEnum(body.tier, ["primary", "rotating"], "primary");

  if (!usernamePattern.test(authorUsername)) throw new HttpError(400, "invalid authorUsername");
  if (!Number.isFinite(Date.parse(publishedAt))) throw new HttpError(400, "invalid publishedAt");
  const parsedURL = safeURL(url);
  if (!["x.com", "www.x.com"].includes(parsedURL.hostname.toLowerCase()) || parsedURL.protocol !== "https:") {
    throw new HttpError(400, "url must be an https://x.com post");
  }

  return {
    id,
    text,
    authorUsername,
    authorDisplayName,
    publishedAt: new Date(publishedAt).toISOString(),
    url: parsedURL.toString(),
    priority,
    tier,
    metrics: {
      likes: nonnegativeInteger(metrics.likes),
      reposts: nonnegativeInteger(metrics.reposts),
      replies: nonnegativeInteger(metrics.replies),
    },
  };
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "JSON object is required");
  }
  return value as Record<string, unknown>;
}

function requiredString(value: Record<string, unknown>, key: string, maximum: number): string {
  const field = value[key];
  if (typeof field !== "string") throw new HttpError(400, `${key} is required`);
  const trimmed = field.trim();
  if (!trimmed || trimmed.length > maximum) throw new HttpError(400, `invalid ${key}`);
  return trimmed;
}

function optionalEnum<T extends string>(
  value: unknown,
  allowed: readonly T[],
  fallback: T,
): T {
  if (value === undefined) return fallback;
  if (typeof value !== "string" || !allowed.includes(value as T)) {
    throw new HttpError(400, "invalid enum value");
  }
  return value as T;
}

function nonnegativeInteger(value: unknown): number {
  if (value === undefined) return 0;
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new HttpError(400, "metrics must be nonnegative integers");
  }
  return value;
}

function safeURL(value: string): URL {
  try {
    return new URL(value);
  } catch {
    throw new HttpError(400, "invalid url");
  }
}
