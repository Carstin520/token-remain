import { upsertFeedItem } from "./feed";
import { classify } from "./classification";
import { isRelevantRotatingPost } from "./selection";
import type { Env, FeedTier } from "./types";
import type { AdminFeedItem } from "./validation";

export const PRIMARY_ACCOUNTS = [
  { username: "thsottiaux", displayName: "Tibo" },
  { username: "sama", displayName: "Sam Altman" },
  { username: "claudeai", displayName: "Claude" },
  { username: "AnthropicAI", displayName: "Anthropic" },
  { username: "OpenAI", displayName: "OpenAI" },
  { username: "karpathy", displayName: "Andrej Karpathy" },
  { username: "JensenHuang", displayName: "Jensen Huang" },
] as const;

export const ROTATING_ACCOUNTS = [
  { username: "Kimi_Moonshot", displayName: "Kimi / Moonshot" },
  { username: "AIatMeta", displayName: "Meta AI" },
  { username: "GoogleDeepMind", displayName: "Google DeepMind" },
  { username: "xai", displayName: "xAI" },
  { username: "MistralAI", displayName: "Mistral AI" },
  { username: "deepseek_ai", displayName: "DeepSeek" },
  { username: "OpenRouterAI", displayName: "OpenRouter" },
  { username: "perplexity_ai", displayName: "Perplexity" },
  { username: "simonw", displayName: "Simon Willison" },
  { username: "emollick", displayName: "Ethan Mollick" },
  { username: "ArtificialAnlys", displayName: "Artificial Analysis" },
  { username: "elonmusk", displayName: "Elon Musk" },
] as const;

export const PRIMARY_DAILY_LIMIT = 30;
export const ROTATING_DAILY_LIMIT = 20;
export const ROTATING_PER_AUTHOR_DAILY_LIMIT = 3;

const authoredPostFilters = "-is:reply -is:retweet -is:nullcast";
const primaryByUsername = new Map(
  PRIMARY_ACCOUNTS.map((account) => [account.username.toLowerCase(), account]),
);
const rotatingByUsername = new Map(
  ROTATING_ACCOUNTS.map((account) => [account.username.toLowerCase(), account]),
);

interface XPost {
  id: string;
  text: string;
  author_id?: string;
  created_at?: string;
  in_reply_to_user_id?: string;
  possibly_sensitive?: boolean;
  referenced_tweets?: Array<{
    id: string;
    type: "retweeted" | "quoted" | "replied_to";
  }>;
  public_metrics?: {
    like_count?: number;
    retweet_count?: number;
    reply_count?: number;
    quote_count?: number;
    bookmark_count?: number;
    impression_count?: number;
  };
}

interface XUser {
  id: string;
  name: string;
  username: string;
  description?: string;
  verified?: boolean;
  public_metrics?: {
    followers_count?: number;
    following_count?: number;
    tweet_count?: number;
  };
}

interface XSearchResponse {
  data?: XPost[];
  includes?: {
    users?: XUser[];
  };
  detail?: string;
  title?: string;
}

interface CollectionCandidate extends AdminFeedItem {
  selectionScore: number;
}

export interface SyncResult {
  inserted: number;
  updated: number;
  skipped: boolean;
}

export function buildPrimaryQuery(): string {
  const accounts = PRIMARY_ACCOUNTS
    .map((account) => `from:${account.username}`)
    .join(" OR ");
  return `(${accounts}) ${authoredPostFilters}`;
}

export function buildRotatingQuery(): string {
  const accounts = ROTATING_ACCOUNTS
    .map((account) => `from:${account.username}`)
    .join(" OR ");
  return `(${accounts}) ${authoredPostFilters}`;
}

export async function syncPrimaryPosts(
  env: Env,
  now = new Date(),
): Promise<SyncResult> {
  const token = env.X_BEARER_TOKEN?.trim();
  if (!token) return { inserted: 0, updated: 0, skipped: true };

  const payload = await searchRecent(token, buildPrimaryQuery(), now, "recency");
  const candidates = candidatesFromSearch(payload, "primary", now)
    .filter((candidate) => primaryByUsername.has(candidate.authorUsername.toLowerCase()))
    .sort((left, right) => right.publishedAt.localeCompare(left.publishedAt));
  return ingestCandidates(
    env,
    candidates,
    "primary",
    PRIMARY_DAILY_LIMIT,
    now,
  );
}

export async function syncRotatingPosts(
  env: Env,
  now = new Date(),
): Promise<SyncResult> {
  const token = env.X_BEARER_TOKEN?.trim();
  if (!token) return { inserted: 0, updated: 0, skipped: true };

  const payload = await searchRecent(token, buildRotatingQuery(), now, "relevancy");
  const candidates = candidatesFromSearch(payload, "rotating", now)
    .filter((candidate) => (
      rotatingByUsername.has(candidate.authorUsername.toLowerCase())
      && !primaryByUsername.has(candidate.authorUsername.toLowerCase())
      && isRelevantRotatingPost({
        priority: candidate.priority,
        text: candidate.text,
      })
    ))
    .sort((left, right) => {
      if (right.selectionScore !== left.selectionScore) {
        return right.selectionScore - left.selectionScore;
      }
      return right.publishedAt.localeCompare(left.publishedAt);
    });
  return ingestCandidates(
    env,
    candidates,
    "rotating",
    ROTATING_DAILY_LIMIT,
    now,
    ROTATING_PER_AUTHOR_DAILY_LIMIT,
  );
}

export async function ingestCandidates(
  env: Env,
  candidates: CollectionCandidate[],
  tier: FeedTier,
  dailyLimit: number,
  now: Date,
  perAuthorDailyLimit?: number,
): Promise<SyncResult> {
  const { start, end } = utcDayBounds(now);
  const count = await env.DB.prepare(
    `SELECT COUNT(*) AS count
     FROM feed_items
     WHERE tier = ? AND status = 'published'
       AND published_at >= ? AND published_at < ?`,
  )
    .bind(tier, start, end)
    .first<number>("count");
  let storedToday = count ?? 0;

  const authorCounts = new Map<string, number>();
  if (perAuthorDailyLimit !== undefined) {
    const rows = await env.DB.prepare(
      `SELECT lower(author_username) AS username, COUNT(*) AS count
       FROM feed_items
       WHERE tier = ? AND status = 'published'
         AND published_at >= ? AND published_at < ?
       GROUP BY lower(author_username)`,
    )
      .bind(tier, start, end)
      .all<{ username: string; count: number }>();
    for (const row of rows.results) authorCounts.set(row.username, row.count);
  }

  let inserted = 0;
  let updated = 0;
  const visited = new Set<string>();
  for (const candidate of candidates) {
    if (visited.has(candidate.id)) continue;
    visited.add(candidate.id);
    if (
      candidate.tier !== tier
      || candidate.publishedAt < start
      || candidate.publishedAt >= end
    ) {
      continue;
    }

    const existing = await env.DB.prepare(
      "SELECT status FROM feed_items WHERE id = ?",
    )
      .bind(candidate.id)
      .first<{ status: "draft" | "published" | "archived" }>();
    if (existing?.status === "published") {
      await upsertFeedItem(env, candidate, candidate.selectionScore);
      updated += 1;
      continue;
    }

    const author = candidate.authorUsername.toLowerCase();
    const authorCount = authorCounts.get(author) ?? 0;
    let replacement: { id: string; username: string; selection_score: number } | null = null;
    if (
      perAuthorDailyLimit !== undefined
      && authorCount >= perAuthorDailyLimit
    ) {
      replacement = await weakestPublishedCandidate(
        env,
        tier,
        start,
        end,
        author,
      );
      if (
        !replacement
        || candidate.selectionScore <= replacement.selection_score
      ) {
        continue;
      }
    }

    if (
      storedToday >= dailyLimit
      && !replacement
      && perAuthorDailyLimit === undefined
    ) {
      continue;
    }
    if (storedToday >= dailyLimit && !replacement) {
      replacement = await weakestPublishedCandidate(env, tier, start, end);
      if (
        !replacement
        || candidate.selectionScore <= replacement.selection_score
      ) {
        continue;
      }
    }

    if (replacement) {
      await env.DB.prepare(
        "UPDATE feed_items SET status = 'archived', updated_at = ? WHERE id = ?",
      )
        .bind(now.toISOString(), replacement.id)
        .run();
      storedToday -= 1;
      authorCounts.set(
        replacement.username,
        Math.max(0, (authorCounts.get(replacement.username) ?? 1) - 1),
      );
    }

    await upsertFeedItem(env, candidate, candidate.selectionScore);
    storedToday += 1;
    inserted += 1;
    authorCounts.set(author, (authorCounts.get(author) ?? 0) + 1);
  }

  return { inserted, updated, skipped: false };
}

export function isOriginalPost(
  post: Pick<XPost, "in_reply_to_user_id" | "referenced_tweets">,
): boolean {
  return !post.in_reply_to_user_id
    && !(post.referenced_tweets ?? []).some(
      (reference) => reference.type === "retweeted" || reference.type === "replied_to",
    );
}

async function searchRecent(
  token: string,
  query: string,
  now: Date,
  sortOrder: "recency" | "relevancy",
): Promise<XSearchResponse> {
  const endpoint = new URL("https://api.x.com/2/tweets/search/recent");
  endpoint.searchParams.set("query", query);
  endpoint.searchParams.set("max_results", "100");
  endpoint.searchParams.set("sort_order", sortOrder);
  endpoint.searchParams.set("start_time", utcDayBounds(now).start);
  endpoint.searchParams.set(
    "tweet.fields",
    [
      "author_id",
      "created_at",
      "in_reply_to_user_id",
      "possibly_sensitive",
      "public_metrics",
      "referenced_tweets",
    ].join(","),
  );
  endpoint.searchParams.set("expansions", "author_id");
  endpoint.searchParams.set(
    "user.fields",
    "description,name,username,verified,public_metrics",
  );

  const response = await fetch(endpoint, {
    headers: {
      accept: "application/json",
      authorization: `Bearer ${token}`,
    },
  });
  const payload = await response.json<XSearchResponse>();
  if (!response.ok) {
    throw new Error(
      `X recent search failed (${response.status}): ${
        payload.detail ?? payload.title ?? "unknown error"
      }`,
    );
  }
  return payload;
}

function candidatesFromSearch(
  payload: XSearchResponse,
  tier: FeedTier,
  now: Date,
): CollectionCandidate[] {
  const users = new Map(
    (payload.includes?.users ?? []).map((user) => [user.id, user]),
  );
  const authorActivity = new Map<string, number>();
  for (const post of payload.data ?? []) {
    if (post.author_id) {
      authorActivity.set(
        post.author_id,
        (authorActivity.get(post.author_id) ?? 0) + 1,
      );
    }
  }

  const candidates: CollectionCandidate[] = [];
  for (const post of payload.data ?? []) {
    if (
      !post.author_id
      || !post.created_at
      || post.possibly_sensitive
      || !isOriginalPost(post)
    ) {
      continue;
    }
    const author = users.get(post.author_id);
    if (!author) continue;
    const activity = authorActivity.get(author.id) ?? 1;
    if (tier === "rotating" && !isEligibleRotatingAuthor(author)) {
      continue;
    }
    const primary = primaryByUsername.get(author.username.toLowerCase());
    const rotating = rotatingByUsername.get(author.username.toLowerCase());
    const metrics = {
      likes: post.public_metrics?.like_count ?? 0,
      reposts: post.public_metrics?.retweet_count ?? 0,
      replies: post.public_metrics?.reply_count ?? 0,
    };
    candidates.push({
      id: post.id,
      text: post.text,
      authorUsername: author.username,
      authorDisplayName: primary?.displayName ?? rotating?.displayName ?? author.name,
      publishedAt: new Date(post.created_at).toISOString(),
      url: `https://x.com/${author.username}/status/${post.id}`,
      priority: classify(post.text),
      tier,
      metrics,
      selectionScore: discoveryHeatScore(
        post,
        author,
        activity,
        now,
      ),
    });
  }
  return candidates;
}

async function weakestPublishedCandidate(
  env: Env,
  tier: FeedTier,
  start: string,
  end: string,
  author?: string,
): Promise<{ id: string; username: string; selection_score: number } | null> {
  const authorClause = author === undefined
    ? ""
    : " AND lower(author_username) = ?";
  const statement = env.DB.prepare(
    `SELECT id, lower(author_username) AS username, selection_score
     FROM feed_items
     WHERE tier = ? AND status = 'published'
       AND published_at >= ? AND published_at < ?${authorClause}
     ORDER BY selection_score ASC, published_at ASC
     LIMIT 1`,
  );
  return author === undefined
    ? statement.bind(tier, start, end).first()
    : statement.bind(tier, start, end, author).first();
}

export function isEligibleRotatingAuthor(
  author: Pick<XUser, "username">,
): boolean {
  const username = author.username.toLowerCase();
  return rotatingByUsername.has(username) && !primaryByUsername.has(username);
}

function discoveryHeatScore(
  post: XPost,
  author: XUser,
  candidatePostCount: number,
  now: Date,
): number {
  const metrics = post.public_metrics;
  const engagement =
    Math.log1p(metrics?.like_count ?? 0) * 3
    + Math.log1p(metrics?.retweet_count ?? 0) * 5
    + Math.log1p(metrics?.reply_count ?? 0) * 2
    + Math.log1p(metrics?.quote_count ?? 0) * 4
    + Math.log1p(metrics?.bookmark_count ?? 0) * 2
    + Math.log1p(metrics?.impression_count ?? 0) * 0.5;
  const accountReach = Math.log1p(author.public_metrics?.followers_count ?? 0) * 0.5;
  const accountActivity = Math.min(candidatePostCount, 5) * 1.5;
  const ageHours = Math.max(
    0,
    (now.getTime() - Date.parse(post.created_at ?? now.toISOString())) / 3_600_000,
  );
  const recency = Math.max(0, 24 - ageHours) / 4;
  return engagement + accountReach + accountActivity + recency;
}

function utcDayBounds(now: Date): { start: string; end: string } {
  const start = new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate(),
  ));
  const end = new Date(start);
  end.setUTCDate(end.getUTCDate() + 1);
  return { start: start.toISOString(), end: end.toISOString() };
}
