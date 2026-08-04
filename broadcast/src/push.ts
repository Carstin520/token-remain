import { APNsError, sendAPNs } from "./apns";
import type {
  DeliveryRow,
  DeviceRow,
  Env,
  FeedItemRow,
  PushJob,
} from "./types";

export async function enqueueItemBroadcast(env: Env, itemID: string): Promise<number> {
  const devices = await activeDevices(env);
  let queued = 0;
  for (const device of devices) {
    const delivery = await createDelivery(
      env,
      device.installation_id,
      "item",
      itemID,
      null,
      `item:${itemID}:${device.installation_id}`,
    );
    if (delivery) {
      await env.PUSH_QUEUE.send(delivery, { contentType: "json" });
      queued += 1;
    }
  }
  return queued;
}

export async function enqueueDueDailyDigests(env: Env, now = new Date()): Promise<number> {
  const devices = await activeDevices(env);
  const freshItemCount = await env.DB.prepare(
    `SELECT COUNT(*) AS count
     FROM feed_items
     WHERE status = 'published' AND datetime(published_at) >= datetime(?, '-1 day')`,
  )
    .bind(now.toISOString())
    .first<number>("count");
  if (!freshItemCount) return 0;

  let queued = 0;
  for (const device of devices) {
    const local = localTime(now, device.timezone);
    const targetHour = Number.parseInt(env.DAILY_DIGEST_LOCAL_HOUR, 10);
    if (local.hour !== targetHour) continue;

    const delivery = await createDelivery(
      env,
      device.installation_id,
      "daily_digest",
      null,
      local.date,
      `digest:${local.date}:${device.installation_id}`,
    );
    if (delivery) {
      await env.PUSH_QUEUE.send(delivery, { contentType: "json" });
      queued += 1;
    }
  }
  return queued;
}

export async function consumePushBatch(
  batch: MessageBatch<PushJob>,
  env: Env,
): Promise<void> {
  for (const message of batch.messages) {
    try {
      await consumePush(message.body, env);
      message.ack();
    } catch (error) {
      if (error instanceof APNsError && error.retryable) {
        message.retry({ delaySeconds: Math.min(60 * 2 ** message.attempts, 3_600) });
      } else {
        message.ack();
      }
    }
  }
}

async function consumePush(job: PushJob, env: Env): Promise<void> {
  const delivery = await env.DB.prepare(
    `SELECT id, dedupe_key, installation_id, kind, item_id, digest_local_date,
            status, attempt_count
     FROM push_deliveries WHERE id = ?`,
  )
    .bind(job.deliveryId)
    .first<DeliveryRow>();
  if (!delivery || delivery.status === "sent") return;

  const device = await env.DB.prepare(
    `SELECT installation_id, registration_key_hash, apns_token, platform, locale,
            timezone, notifications_enabled, active
     FROM devices WHERE installation_id = ?`,
  )
    .bind(job.installationId)
    .first<DeviceRow>();
  if (!device || !device.active || !device.notifications_enabled) {
    await markDelivery(env, delivery.id, "failed", "device is inactive");
    return;
  }

  const item = delivery.item_id
    ? await env.DB.prepare(
      `SELECT id, text, author_username, author_display_name, published_at, url,
              priority, tier, likes, reposts, replies, selection_score, status
       FROM feed_items WHERE id = ? AND status = 'published'`,
    )
      .bind(delivery.item_id)
      .first<FeedItemRow>()
    : undefined;
  const rawDigestCount = delivery.kind === "daily_digest"
    ? await env.DB.prepare(
      `SELECT COUNT(*) AS count FROM feed_items
       WHERE status = 'published'
         AND datetime(published_at) >= datetime('now', '-1 day')`,
    ).first<number>("count")
    : undefined;
  const digestCount = rawDigestCount ?? undefined;

  await env.DB.prepare(
    `UPDATE push_deliveries
     SET status = 'sending', attempt_count = attempt_count + 1
     WHERE id = ?`,
  )
    .bind(delivery.id)
    .run();

  try {
    await sendAPNs(env, {
      kind: delivery.kind,
      device,
      ...(item ? { item } : {}),
      ...(digestCount !== undefined ? { digestCount } : {}),
    });
    await env.DB.prepare(
      `UPDATE push_deliveries
       SET status = 'sent', sent_at = ?, last_error = NULL
       WHERE id = ?`,
    )
      .bind(new Date().toISOString(), delivery.id)
      .run();
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown APNs failure";
    if (error instanceof APNsError && error.unregistered) {
      await env.DB.prepare(
        "UPDATE devices SET active = 0, updated_at = ? WHERE installation_id = ?",
      )
        .bind(new Date().toISOString(), device.installation_id)
        .run();
    }
    await markDelivery(env, delivery.id, "failed", message);
    throw error;
  }
}

async function activeDevices(env: Env): Promise<DeviceRow[]> {
  const result = await env.DB.prepare(
    `SELECT installation_id, registration_key_hash, apns_token, platform, locale,
            timezone, notifications_enabled, active
     FROM devices
     WHERE active = 1 AND notifications_enabled = 1
     ORDER BY last_seen_at DESC`,
  ).all<DeviceRow>();
  return result.results;
}

async function createDelivery(
  env: Env,
  installationID: string,
  kind: DeliveryRow["kind"],
  itemID: string | null,
  localDate: string | null,
  dedupeKey: string,
): Promise<PushJob | null> {
  const id = crypto.randomUUID();
  const result = await env.DB.prepare(
    `INSERT OR IGNORE INTO push_deliveries (
       id, dedupe_key, installation_id, kind, item_id, digest_local_date,
       status, attempt_count, created_at
     ) VALUES (?, ?, ?, ?, ?, ?, 'queued', 0, ?)`,
  )
    .bind(
      id,
      dedupeKey,
      installationID,
      kind,
      itemID,
      localDate,
      new Date().toISOString(),
    )
    .run();
  return result.meta.changes === 1
    ? { deliveryId: id, installationId: installationID }
    : null;
}

async function markDelivery(
  env: Env,
  deliveryID: string,
  status: "failed",
  error: string,
): Promise<void> {
  await env.DB.prepare(
    "UPDATE push_deliveries SET status = ?, last_error = ? WHERE id = ?",
  )
    .bind(status, error.slice(0, 500), deliveryID)
    .run();
}

function localTime(now: Date, timeZone: string): { date: string; hour: number } {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return {
    date: `${value.year}-${value.month}-${value.day}`,
    hour: Number.parseInt(value.hour ?? "-1", 10),
  };
}
