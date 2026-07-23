import { bearerToken, constantTimeEqual, HttpError, json, readJSON } from "./http";
import type { AdminFeedItem } from "./validation";
import type { Env, FeedItemRow } from "./types";
import { enqueueItemBroadcast } from "./push";
import { validateAdminFeedItem } from "./validation";

export async function getFeed(env: Env): Promise<Response> {
  const result = await env.DB.prepare(
    `SELECT id, text, author_username, author_display_name, published_at, url,
            priority, tier, likes, reposts, replies, status
     FROM feed_items
     WHERE status = 'published'
       AND datetime(published_at) >= datetime('now', '-14 days')
     ORDER BY published_at DESC
     LIMIT 50`,
  ).all<FeedItemRow>();

  const response = json({
    items: result.results.map(publicFeedItem),
  });
  response.headers.set("cache-control", "public, max-age=60, stale-while-revalidate=300");
  return response;
}

export async function publishAdminItem(request: Request, env: Env): Promise<Response> {
  requireAdmin(request, env);
  const item = validateAdminFeedItem(await readJSON<unknown>(request));
  const created = await upsertFeedItem(env, item);
  if (created && item.priority !== "normal") {
    await enqueueItemBroadcast(env, item.id);
  }
  return json({ published: true, created, item: publicAdminFeedItem(item) }, { status: created ? 201 : 200 });
}

export async function upsertFeedItem(
  env: Env,
  item: AdminFeedItem,
  selectionScore = 0,
): Promise<boolean> {
  const now = new Date().toISOString();
  const existing = await env.DB.prepare(
    "SELECT 1 AS present FROM feed_items WHERE id = ?",
  )
    .bind(item.id)
    .first<number>("present");
  await env.DB.prepare(
    `INSERT INTO feed_items (
       id, text, author_username, author_display_name, published_at, url,
       priority, tier, likes, reposts, replies, selection_score, status,
       created_at, updated_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'published', ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       text = excluded.text,
       author_username = excluded.author_username,
       author_display_name = excluded.author_display_name,
       published_at = excluded.published_at,
       url = excluded.url,
       priority = excluded.priority,
       tier = excluded.tier,
       likes = excluded.likes,
       reposts = excluded.reposts,
       replies = excluded.replies,
       selection_score = excluded.selection_score,
       status = 'published',
       updated_at = excluded.updated_at`,
  )
    .bind(
      item.id,
      item.text,
      item.authorUsername,
      item.authorDisplayName,
      item.publishedAt,
      item.url,
      item.priority,
      item.tier,
      item.metrics.likes,
      item.metrics.reposts,
      item.metrics.replies,
      selectionScore,
      now,
      now,
    )
    .run();
  return existing === null;
}

function publicFeedItem(row: FeedItemRow): Record<string, unknown> {
  return {
    id: row.id,
    text: row.text,
    author: {
      username: row.author_username,
      displayName: row.author_display_name,
    },
    publishedAt: row.published_at,
    url: row.url,
    priority: row.priority,
    tier: row.tier,
    metrics: {
      likes: row.likes,
      reposts: row.reposts,
      replies: row.replies,
    },
  };
}

function publicAdminFeedItem(item: AdminFeedItem): Record<string, unknown> {
  return {
    id: item.id,
    text: item.text,
    author: {
      username: item.authorUsername,
      displayName: item.authorDisplayName,
    },
    publishedAt: item.publishedAt,
    url: item.url,
    priority: item.priority,
    tier: item.tier,
    metrics: item.metrics,
  };
}

function requireAdmin(request: Request, env: Env): void {
  if (!env.ADMIN_TOKEN) throw new HttpError(503, "admin publishing is not configured");
  const supplied = bearerToken(request);
  if (!supplied || !constantTimeEqual(supplied, env.ADMIN_TOKEN)) {
    throw new HttpError(401, "unauthorized");
  }
}
