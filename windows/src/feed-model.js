// Port of the macOS AIFeedCollectionPolicy so the Windows Overview shows the
// same Trending / Important / More groupings from the same curated feed.

export const PRIORITY_RANK = { token_reset: 0, major_update: 1, normal: 2 };

const MAX_NORMAL_POSTS_PER_AUTHOR = 3;
const PREFERRED_IMPORTANT_LIMIT = 7;
const MAXIMUM_IMPORTANT_LIMIT = 10;
const MINIMUM_ROTATING_RELEVANCE = 100;

const DIRECT_IMPACT_TERMS = [
  "usage limit", "rate limit", "quota", "token", "context window",
  "pricing", "price", "credit", "paid user", "all plans",
  "outage", "incident", "degraded", "back online", "resolved",
  "额度", "配额", "限额", "价格", "故障", "中断", "恢复",
];
const AI_PRODUCT_TERMS = [
  "codex", "chatgpt", "openai", "claude", "anthropic", "gpt",
  "grok", "xai", "kimi", "deepseek", "mistral", "gemini",
  "model", "api", "agent", "模型", "接口", "智能体",
];
const ACTIONABLE_TERMS = [
  "launch", "release", "available", "rolling out", "introducing",
  "reset", "increase", "decrease", "fixed", "update", "benchmark",
  "发布", "上线", "推出", "重置", "提升", "下调", "修复", "更新",
];
const NOISE_TERMS = [
  "election", "politics", "government", "tesla", "spacex",
  "mars", "moon", "dogecoin", "crypto", "移民", "选举", "火星", "月球",
];

export function priorityTitle(priority) {
  if (priority === "token_reset") return "Quota / Token";
  if (priority === "major_update") return "Major update";
  return "";
}

export function initials(displayName, username) {
  const letters = String(displayName || "")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]);
  if (letters.length) return letters.join("").toUpperCase();
  return String(username || "?").slice(0, 1).toUpperCase();
}

export function engagementScore(post) {
  return post.metrics.likes + 2 * post.metrics.reposts + post.metrics.replies;
}

export function topicRelevanceScore(text) {
  const normalized = String(text).toLowerCase();
  const containsAny = (terms) => terms.some((term) => normalized.includes(term));
  let score = 0;
  if (containsAny(DIRECT_IMPACT_TERMS)) score += 90;
  if (containsAny(AI_PRODUCT_TERMS)) score += 70;
  if (containsAny(ACTIONABLE_TERMS)) score += 35;
  if (containsAny(NOISE_TERMS)) score -= 180;
  return score;
}

export function trendingScore(post, now = Date.now()) {
  const ageHours = Math.max(0.5, (now - post.publishedAt) / 3_600_000);
  const engagement = Math.max(0, engagementScore(post));
  const velocity = (engagement + 1) / Math.pow(ageHours, 0.8);
  const momentumScore = Math.min(1_600, Math.trunc(Math.log2(velocity + 1) * 180));
  const priorityScore = post.priority === "token_reset" ? 1_500 : post.priority === "major_update" ? 600 : 0;
  const relevanceScore = Math.max(0, topicRelevanceScore(post.text)) * 3;
  const freshnessScore = Math.max(0, 720 - Math.trunc(ageHours * 15));
  const sourceScore = post.tier === "primary" ? 50 : 0;
  return momentumScore + priorityScore + relevanceScore + freshnessScore + sourceScore;
}

export function isWithinFreshnessWindow(post, now = Date.now()) {
  const ageHours = Math.max(0, (now - post.publishedAt) / 3_600_000);
  const maximumAgeHours = post.priority === "token_reset" ? 36 : post.priority === "major_update" ? 72 : 48;
  return ageHours <= maximumAgeHours;
}

export function sortForRecommendation(posts, now = Date.now()) {
  return [...posts].sort((left, right) => {
    const leftScore = trendingScore(left, now);
    const rightScore = trendingScore(right, now);
    if (leftScore !== rightScore) return rightScore - leftScore;
    if (left.publishedAt !== right.publishedAt) return right.publishedAt - left.publishedAt;
    return left.id < right.id ? -1 : 1;
  });
}

/// The recommendation list every surface starts from: fresh posts, ranked, at
/// most three normal posts per author, low-relevance rotating posts dropped.
export function curateForDisplay(posts = [], now = Date.now()) {
  const normalCounts = new Map();
  return sortForRecommendation(posts, now).filter((post) => {
    if (!isWithinFreshnessWindow(post, now)) return false;
    if (post.priority !== "normal") return true;
    if (post.tier === "rotating" && topicRelevanceScore(post.text) < MINIMUM_ROTATING_RELEVANCE) return false;
    const username = post.username.toLowerCase();
    const count = normalCounts.get(username) || 0;
    if (count >= MAX_NORMAL_POSTS_PER_AUTHOR) return false;
    normalCounts.set(username, count + 1);
    return true;
  });
}

/// The one or two posts the Overview "Trending" card shows.
export function topStories(posts = [], now = Date.now()) {
  return curateForDisplay(posts, now).slice(0, 2);
}

/// Compact important group with a small overflow allowance for quota events.
export function selectImportantForDisplay(curated, now = Date.now()) {
  const ranked = sortForRecommendation(curated.filter((post) => post.priority !== "normal"), now);
  const criticalCount = ranked.filter((post) => post.priority === "token_reset").length;
  const displayLimit = Math.min(Math.max(PREFERRED_IMPORTANT_LIMIT, criticalCount), MAXIMUM_IMPORTANT_LIMIT);
  return ranked.slice(0, displayLimit);
}

export function morePosts(curated) {
  return curated.filter((post) => post.priority === "normal");
}
