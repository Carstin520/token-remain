import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { enqueueDueDailyDigests } from "../src/push";
import {
  buildPrimaryQuery,
  buildRotatingQuery,
  classify,
  ingestCandidates,
  isEligibleRotatingAuthor,
  isOriginalPost,
  PRIMARY_ACCOUNTS,
  PRIMARY_DAILY_LIMIT,
  ROTATING_ACCOUNTS,
  ROTATING_DAILY_LIMIT,
  ROTATING_PER_AUTHOR_DAILY_LIMIT,
} from "../src/x-api";

describe("TokenRemain broadcast worker", () => {
  it("reports a server-curated health contract", async () => {
    const response = await exports.default.fetch("https://broadcast.test/health");
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      status: "ok",
      delivery: "server-curated",
      xCredentialsInClient: false,
      originalPostsOnly: true,
      collection: {
        primary: {
          accounts: PRIMARY_ACCOUNTS.map((account) => account.username),
          dailyLimit: 30,
        },
        rotating: {
          accounts: ROTATING_ACCOUNTS.map((account) => account.username),
          dailyLimit: 20,
        },
      },
    });
  });

  it("registers an anonymous APNs installation without an account", async () => {
    const response = await exports.default.fetch("https://broadcast.test/v1/devices/register", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        installationId: "installation_1234567890",
        registrationKey: "registration_key_12345678901234567890",
        deviceToken: "a".repeat(64),
        platform: "macos",
        locale: "zh-Hans",
        timezone: "Asia/Shanghai",
        notificationsEnabled: true,
      }),
    });
    expect(response.status).toBe(201);
    const stored = await env.DB.prepare(
      "SELECT installation_id, apns_token, timezone FROM devices WHERE installation_id = ?",
    )
      .bind("installation_1234567890")
      .first();
    expect(stored).toMatchObject({
      installation_id: "installation_1234567890",
      apns_token: "a".repeat(64),
      timezone: "Asia/Shanghai",
    });
  });

  it("records only an aggregate Mac download count before redirecting", async () => {
    const first = await exports.default.fetch(new Request(
      "https://broadcast.test/v1/downloads/macos",
      { redirect: "manual" },
    ));
    expect(first.status).toBe(302);
    expect(first.headers.get("location")).toBe(
      "https://github.com/Carstin520/token-remain/releases/latest/download/TokenRemain.dmg",
    );
    expect(first.headers.get("cache-control")).toBe("no-store");

    const second = await exports.default.fetch(new Request(
      "https://broadcast.test/v1/downloads/macos",
      { redirect: "manual" },
    ));
    expect(second.status).toBe(302);

    const stats = await exports.default.fetch(
      "https://broadcast.test/v1/downloads/stats",
    );
    expect(stats.status).toBe(200);
    expect(stats.headers.get("access-control-allow-origin")).toBe("*");
    await expect(stats.json()).resolves.toMatchObject({
      macos: {
        totalDownloads: 2,
      },
    });

    const schema = await env.DB.prepare(
      "PRAGMA table_info(download_counters)",
    ).all<{ name: string }>();
    expect(schema.results.map((column) => column.name)).toEqual([
      "asset",
      "total_count",
      "updated_at",
    ]);
  });

  it("publishes an authenticated item through the public feed contract", async () => {
    const payload = {
      id: "1900000000000000001",
      text: "A new TokenRemain update is available.",
      authorUsername: "owner",
      authorDisplayName: "TokenRemain",
      publishedAt: "2026-07-23T10:00:00Z",
      url: "https://x.com/owner/status/1900000000000000001",
      priority: "normal",
      tier: "primary",
      metrics: { likes: 10, reposts: 2, replies: 1 },
    };
    const publish = await exports.default.fetch("https://broadcast.test/v1/admin/feed/items", {
      method: "POST",
      headers: {
        authorization: "Bearer test-admin-token",
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    expect(publish.status).toBe(201);

    const response = await exports.default.fetch("https://broadcast.test/v1/ai-feed");
    expect(response.status).toBe(200);
    const feed = await response.json<{ items: Array<Record<string, unknown>> }>();
    expect(feed.items).toHaveLength(1);
    expect(feed.items[0]).toMatchObject({
      id: payload.id,
      text: payload.text,
      url: payload.url,
      priority: "normal",
    });
  });

  it("rejects invalid device and admin inputs", async () => {
    const unauthorized = await exports.default.fetch("https://broadcast.test/v1/admin/feed/items", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(unauthorized.status).toBe(401);

    const invalidDevice = await exports.default.fetch("https://broadcast.test/v1/devices/register", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        installationId: "short",
        registrationKey: "short",
        deviceToken: "bad",
        platform: "macos",
        locale: "en",
        timezone: "UTC",
      }),
    });
    expect(invalidDevice.status).toBe(400);
  });

  it("classifies quota and launch messages before neutral posts", () => {
    expect(classify("Usage quota resets every five hours.")).toBe("token_reset");
    expect(classify("Introducing our new model today.")).toBe("major_update");
    expect(classify("A quiet day at the office.")).toBe("normal");
  });

  it("builds two-tier searches that exclude replies, reposts, and quote posts", () => {
    const primary = buildPrimaryQuery();
    const rotating = buildRotatingQuery();

    for (const account of PRIMARY_ACCOUNTS) {
      expect(primary).toContain(`from:${account.username}`);
      expect(rotating).not.toMatch(
        new RegExp(`(?:^|[ (])from:${account.username}(?:[ )]|$)`, "i"),
      );
    }
    for (const account of ROTATING_ACCOUNTS) {
      expect(rotating).toContain(`from:${account.username}`);
    }
    for (const filter of ["-is:reply", "-is:retweet", "-is:quote"]) {
      expect(primary).toContain(filter);
      expect(rotating).toContain(filter);
    }
    expect(rotating.length).toBeLessThanOrEqual(512);
    expect(isOriginalPost({})).toBe(true);
    expect(isOriginalPost({ in_reply_to_user_id: "123" })).toBe(false);
    expect(isOriginalPost({
      referenced_tweets: [{ id: "456", type: "quoted" }],
    })).toBe(false);
    expect(isEligibleRotatingAuthor(
      {
        username: "GoogleDeepMind",
      },
    )).toBe(true);
    expect(isEligibleRotatingAuthor(
      {
        username: "popular_ai_outsider",
      },
    )).toBe(false);
    expect(isEligibleRotatingAuthor({
      username: "OpenAI",
    })).toBe(false);
  });

  it("enforces aggregate 30/20 daily limits and rotating author diversity", async () => {
    const now = new Date("2026-08-01T12:00:00Z");
    const primaryCandidates: Parameters<typeof ingestCandidates>[1] = Array.from(
      { length: 35 },
      (_, index) => candidate({
        id: `210000000000000${String(index).padStart(4, "0")}`,
        username: PRIMARY_ACCOUNTS[index % PRIMARY_ACCOUNTS.length].username,
        tier: "primary",
        publishedAt: `2026-08-01T10:${String(index).padStart(2, "0")}:00.000Z`,
        selectionScore: 100 - index,
      }),
    );
    const primaryResult = await ingestCandidates(
      env,
      primaryCandidates,
      "primary",
      PRIMARY_DAILY_LIMIT,
      now,
    );
    expect(primaryResult.inserted).toBe(30);
    const primaryOverflow = await ingestCandidates(
      env,
      [candidate({
        id: "2199999999999999999",
        username: "OpenAI",
        tier: "primary",
        publishedAt: "2026-08-01T10:59:00.000Z",
        selectionScore: 1_000,
      })],
      "primary",
      PRIMARY_DAILY_LIMIT,
      now,
    );
    expect(primaryOverflow.inserted).toBe(0);

    const rotatingCandidates: Parameters<typeof ingestCandidates>[1] = Array.from(
      { length: 30 },
      (_, index) => candidate({
        id: `220000000000000${String(index).padStart(4, "0")}`,
        username: index < 10 ? "HotAIAccount" : `aiaccount${index}`,
        tier: "rotating",
        publishedAt: `2026-08-01T11:${String(index).padStart(2, "0")}:00.000Z`,
        selectionScore: 200 - index,
      }),
    );
    const rotatingResult = await ingestCandidates(
      env,
      rotatingCandidates,
      "rotating",
      ROTATING_DAILY_LIMIT,
      now,
      ROTATING_PER_AUTHOR_DAILY_LIMIT,
    );
    expect(rotatingResult.inserted).toBe(20);

    const counts = await env.DB.prepare(
      `SELECT tier, COUNT(*) AS count
       FROM feed_items
       WHERE published_at >= '2026-08-01T00:00:00.000Z'
         AND published_at < '2026-08-02T00:00:00.000Z'
       GROUP BY tier`,
    ).all<{ tier: string; count: number }>();
    expect(Object.fromEntries(
      counts.results.map((row) => [row.tier, row.count]),
    )).toEqual({ primary: 30, rotating: 20 });

    const hotAccountCount = await env.DB.prepare(
      `SELECT COUNT(*) AS count
       FROM feed_items
       WHERE tier = 'rotating' AND lower(author_username) = 'hotaiaccount'
         AND published_at >= '2026-08-01T00:00:00.000Z'
         AND published_at < '2026-08-02T00:00:00.000Z'`,
    ).first<number>("count");
    expect(hotAccountCount).toBe(ROTATING_PER_AUTHOR_DAILY_LIMIT);

    const replacement = await ingestCandidates(
      env,
      [candidate({
        id: "2299999999999999999",
        username: "LateBreakingAI",
        tier: "rotating",
        publishedAt: "2026-08-01T11:59:00.000Z",
        selectionScore: 1_000,
      })],
      "rotating",
      ROTATING_DAILY_LIMIT,
      now,
      ROTATING_PER_AUTHOR_DAILY_LIMIT,
    );
    expect(replacement.inserted).toBe(1);
    const rotatingPublished = await env.DB.prepare(
      `SELECT COUNT(*) AS count FROM feed_items
       WHERE tier = 'rotating' AND status = 'published'
         AND published_at >= '2026-08-01T00:00:00.000Z'
         AND published_at < '2026-08-02T00:00:00.000Z'`,
    ).first<number>("count");
    expect(rotatingPublished).toBe(20);
    const lateBreaking = await env.DB.prepare(
      "SELECT status FROM feed_items WHERE id = '2299999999999999999'",
    ).first<string>("status");
    expect(lateBreaking).toBe("published");
  });

  it("does not expose an X credential in the public health or feed responses", async () => {
    const health = JSON.stringify(await (
      await exports.default.fetch("https://broadcast.test/health")
    ).json());
    const feed = JSON.stringify(await (
      await exports.default.fetch("https://broadcast.test/v1/ai-feed")
    ).json());
    expect(health).not.toContain("test-admin-token");
    expect(feed).not.toContain("test-admin-token");
    expect(health).not.toContain("X_BEARER_TOKEN");
    expect(feed).not.toContain("X_BEARER_TOKEN");
  });

  it("queues one local-day digest even when the newest feed item is older than 24 hours", async () => {
    const installationId = "installation_daily_123456";
    const registrationKey = "registration_key_daily_123456789012345";
    const publish = await exports.default.fetch("https://broadcast.test/v1/admin/feed/items", {
      method: "POST",
      headers: {
        authorization: "Bearer test-admin-token",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        id: "1900000000000000099",
        text: "An older public update remains available in the daily feed.",
        authorUsername: "owner",
        authorDisplayName: "TokenRemain",
        publishedAt: "2026-07-20T01:00:00Z",
        url: "https://x.com/owner/status/1900000000000000099",
        priority: "normal",
        tier: "primary",
        metrics: { likes: 0, reposts: 0, replies: 0 },
      }),
    });
    expect([200, 201]).toContain(publish.status);

    const device = await exports.default.fetch("https://broadcast.test/v1/devices/register", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        installationId,
        registrationKey,
        deviceToken: "b".repeat(64),
        platform: "ios",
        locale: "zh-Hans",
        timezone: "Asia/Shanghai",
        notificationsEnabled: true,
      }),
    });
    expect(device.status).toBe(201);

    const queued = await enqueueDueDailyDigests(
      env,
      new Date("2026-07-23T01:00:00Z"),
    );
    expect(queued).toBeGreaterThanOrEqual(1);
    const delivery = await env.DB.prepare(
      `SELECT kind, digest_local_date FROM push_deliveries
       WHERE installation_id = ?`,
    )
      .bind(installationId)
      .first();
    expect(delivery).toMatchObject({
      kind: "daily_digest",
      digest_local_date: "2026-07-23",
    });
  });
});

function candidate(input: {
  id: string;
  username: string;
  tier: "primary" | "rotating";
  publishedAt: string;
  selectionScore: number;
}): Parameters<typeof ingestCandidates>[1][number] {
  return {
    id: input.id,
    text: `Original AI post ${input.id}`,
    authorUsername: input.username,
    authorDisplayName: input.username,
    publishedAt: input.publishedAt,
    url: `https://x.com/${input.username}/status/${input.id}`,
    priority: "normal",
    tier: input.tier,
    metrics: { likes: 10, reposts: 2, replies: 1 },
    selectionScore: input.selectionScore,
  };
}
