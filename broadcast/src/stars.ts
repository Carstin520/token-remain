import { json } from "./http";
import type { Env } from "./types";

const REPO = "Carstin520/token-remain";

// Unauthenticated GitHub API call; the hourly cron retries all day and the
// daily row keeps the last successful reading, so occasional rate-limit
// failures from shared egress IPs are self-healing.
export async function snapshotStarHistory(env: Env, now: Date): Promise<void> {
  const response = await fetch(`https://api.github.com/repos/${REPO}`, {
    headers: {
      accept: "application/vnd.github+json",
      "user-agent": "tokenremain-broadcast (star-history snapshot)",
    },
  });
  if (!response.ok) {
    throw new Error(`GitHub repo lookup failed with status ${response.status}`);
  }
  const body = (await response.json()) as { stargazers_count?: number };
  const count = body.stargazers_count;
  if (typeof count !== "number" || !Number.isFinite(count) || count < 0) {
    throw new Error("GitHub repo lookup returned no usable stargazers_count");
  }

  const iso = now.toISOString();
  await env.DB.prepare(
    `INSERT INTO star_history (day, star_count, updated_at)
     VALUES (?, ?, ?)
     ON CONFLICT(day) DO UPDATE SET
       star_count = excluded.star_count,
       updated_at = excluded.updated_at`,
  )
    .bind(iso.slice(0, 10), count, iso)
    .run();
}

export async function getStarHistory(env: Env): Promise<Response> {
  const rows = await env.DB.prepare(
    "SELECT day, star_count FROM star_history ORDER BY day ASC",
  ).all<{ day: string; star_count: number }>();

  return json(
    {
      repo: REPO,
      days: rows.results.map((row) => ({ day: row.day, stars: row.star_count })),
    },
    {
      headers: {
        "access-control-allow-origin": "*",
        "cache-control": "public, max-age=3600",
      },
    },
  );
}
