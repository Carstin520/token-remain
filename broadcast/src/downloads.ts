import { json } from "./http";
import type { Env } from "./types";

const MACOS_ASSET = "macos_dmg";
const MACOS_DOWNLOAD_URL =
  "https://github.com/Carstin520/token-remain/releases/latest/download/TokenRemain.dmg";
const PUBLIC_SITE_ORIGIN = "https://tokenremain.jamescarstin520.chatgpt.site";

export async function redirectToMacDownload(env: Env): Promise<Response> {
  const now = new Date().toISOString();
  await env.DB.prepare(
    `INSERT INTO download_counters (asset, total_count, updated_at)
     VALUES (?, 1, ?)
     ON CONFLICT(asset) DO UPDATE SET
       total_count = total_count + 1,
       updated_at = excluded.updated_at`,
  )
    .bind(MACOS_ASSET, now)
    .run();

  return new Response(null, {
    status: 302,
    headers: {
      "cache-control": "no-store",
      location: MACOS_DOWNLOAD_URL,
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

export async function getDownloadStats(env: Env): Promise<Response> {
  const row = await env.DB.prepare(
    "SELECT total_count, updated_at FROM download_counters WHERE asset = ?",
  )
    .bind(MACOS_ASSET)
    .first<{ total_count: number; updated_at: string }>();

  return json(
    {
      macos: {
        totalDownloads: row?.total_count ?? 0,
        updatedAt: row?.updated_at ?? null,
      },
    },
    {
      headers: {
        "access-control-allow-origin": PUBLIC_SITE_ORIGIN,
        "cache-control": "public, max-age=60",
      },
    },
  );
}
