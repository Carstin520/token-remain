import type { FeedItemRow } from "./types";

const minimumRotatingRelevanceScore = 40;
const maxNormalPostsPerAuthor = 3;

export function rankFeedItems(
  rows: FeedItemRow[],
  now = new Date(),
): FeedItemRow[] {
  const ranked = rows
    .filter((row) => (
      row.tier !== "rotating"
      || row.priority !== "normal"
      || topicRelevanceScore(row.text) >= minimumRotatingRelevanceScore
    ))
    .sort((left, right) => {
      const scoreDifference = trendingScore(right, now) - trendingScore(left, now);
      if (scoreDifference !== 0) return scoreDifference;
      const selectionDifference = right.selection_score - left.selection_score;
      if (selectionDifference !== 0) return selectionDifference;
      const dateDifference = Date.parse(right.published_at) - Date.parse(left.published_at);
      if (dateDifference !== 0) return dateDifference;
      return left.id.localeCompare(right.id);
    });

  const normalCounts = new Map<string, number>();
  return ranked.filter((row) => {
    if (row.priority !== "normal") return true;
    const author = row.author_username.toLowerCase();
    const count = normalCounts.get(author) ?? 0;
    if (count >= maxNormalPostsPerAuthor) return false;
    normalCounts.set(author, count + 1);
    return true;
  });
}

export function isRelevantRotatingPost(
  item: Pick<FeedItemRow, "priority" | "text">,
): boolean {
  return item.priority !== "normal"
    || topicRelevanceScore(item.text) >= minimumRotatingRelevanceScore;
}

export function topicRelevanceScore(text: string): number {
  const normalized = text.toLocaleLowerCase();
  const directImpactTerms = [
    "usage limit", "rate limit", "quota", "token", "context window",
    "pricing", "price", "credit", "paid user", "all plans",
    "outage", "incident", "degraded", "back online", "resolved",
    "额度", "配额", "限额", "价格", "故障", "中断", "恢复",
  ];
  const aiProductTerms = [
    "codex", "chatgpt", "openai", "claude", "anthropic", "gpt",
    "grok", "xai", "kimi", "deepseek", "mistral", "gemini",
    "model", "api", "agent", "模型", "接口", "智能体",
  ];
  const actionableTerms = [
    "launch", "release", "available", "rolling out", "introducing",
    "reset", "increase", "decrease", "fixed", "update", "benchmark",
    "发布", "上线", "推出", "重置", "提升", "下调", "修复", "更新",
  ];
  const noiseTerms = [
    "election", "politics", "government", "tesla", "spacex",
    "starship", "mars", "moon", "dogecoin", "crypto",
    "移民", "选举", "火星", "月球",
  ];

  let score = 0;
  if (containsAny(normalized, directImpactTerms)) score += 90;
  if (containsAny(normalized, aiProductTerms)) score += 70;
  if (containsAny(normalized, actionableTerms)) score += 35;
  if (containsAny(normalized, noiseTerms)) score -= 180;
  return score;
}

function trendingScore(row: FeedItemRow, now: Date): number {
  const publishedAt = Date.parse(row.published_at);
  const ageHours = Math.max(
    0.5,
    (now.getTime() - (Number.isFinite(publishedAt) ? publishedAt : now.getTime())) / 3_600_000,
  );
  const engagement = Math.max(0, row.likes + 2 * row.reposts + row.replies);
  const velocity = (engagement + 1) / Math.pow(ageHours, 0.8);
  const momentum = Math.min(2_500, Math.trunc(Math.log2(velocity + 1) * 240));
  const priority = row.priority === "token_reset"
    ? 1_800
    : row.priority === "major_update"
      ? 900
      : 0;
  const relevance = Math.max(0, topicRelevanceScore(row.text)) * 4;
  const freshness = Math.max(0, 360 - Math.trunc(ageHours * 12));
  const source = row.tier === "primary" ? 50 : 0;
  return momentum + priority + relevance + freshness + source;
}

function containsAny(value: string, candidates: string[]): boolean {
  return candidates.some((candidate) => value.includes(candidate));
}
