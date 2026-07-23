import { HttpError, json, readJSON } from "./http";
import type { Env } from "./types";
import { validateRegistration } from "./validation";

export async function registerDevice(request: Request, env: Env): Promise<Response> {
  const registration = validateRegistration(await readJSON<unknown>(request));
  const now = new Date().toISOString();
  const registrationKeyHash = await hashRegistrationKey(registration.registrationKey);
  const existing = await env.DB.prepare(
    "SELECT registration_key_hash FROM devices WHERE installation_id = ?",
  )
    .bind(registration.installationId)
    .first<{ registration_key_hash: string }>();

  if (existing && existing.registration_key_hash !== registrationKeyHash) {
    throw new HttpError(409, "installation is already registered");
  }

  // APNs can reuse a token across an app reinstall while the client has a new
  // installation ID. Possession of the token is proven by APNs registration,
  // so retire the unreachable old anonymous row before enforcing uniqueness.
  await env.DB.prepare(
    "DELETE FROM devices WHERE apns_token = ? AND installation_id <> ?",
  )
    .bind(registration.deviceToken, registration.installationId)
    .run();

  await env.DB.prepare(
    `INSERT INTO devices (
       installation_id, registration_key_hash, apns_token, platform, locale, timezone,
       notifications_enabled, active, created_at, updated_at, last_seen_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
     ON CONFLICT(installation_id) DO UPDATE SET
       apns_token = excluded.apns_token,
       platform = excluded.platform,
       locale = excluded.locale,
       timezone = excluded.timezone,
       notifications_enabled = excluded.notifications_enabled,
       active = 1,
       updated_at = excluded.updated_at,
       last_seen_at = excluded.last_seen_at`,
  )
    .bind(
      registration.installationId,
      registrationKeyHash,
      registration.deviceToken,
      registration.platform,
      registration.locale,
      registration.timezone,
      registration.notificationsEnabled ? 1 : 0,
      now,
      now,
      now,
    )
    .run();

  return json({ registered: true }, { status: existing ? 200 : 201 });
}

export async function unregisterDevice(
  request: Request,
  env: Env,
  installationId: string,
): Promise<Response> {
  const body = await readJSON<{ registrationKey?: unknown }>(request);
  if (typeof body.registrationKey !== "string") throw new HttpError(400, "registrationKey is required");
  const hash = await hashRegistrationKey(body.registrationKey);
  const result = await env.DB.prepare(
    `UPDATE devices
     SET active = 0, notifications_enabled = 0, updated_at = ?
     WHERE installation_id = ? AND registration_key_hash = ?`,
  )
    .bind(new Date().toISOString(), installationId, hash)
    .run();
  if (result.meta.changes === 0) throw new HttpError(404, "registration not found");
  return json({ registered: false });
}

async function hashRegistrationKey(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
