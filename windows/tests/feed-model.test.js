import assert from "node:assert/strict";
import test from "node:test";
import {
  curateForDisplay,
  initials,
  isWithinFreshnessWindow,
  morePosts,
  priorityTitle,
  selectImportantForDisplay,
  topStories,
  topicRelevanceScore,
  trendingScore,
} from "../src/feed-model.js";

const now = Date.parse("2026-08-04T08:00:00Z");

function post(id, overrides = {}) {
  return {
    id,
    text: "Codex quota update rolling out",
    username: "OpenAI",
    displayName: "OpenAI",
    publishedAt: now - 2 * 3_600_000,
    priority: "normal",
    tier: "primary",
    metrics: { likes: 100, reposts: 20, replies: 10 },
    ...overrides,
  };
}

test("Relevance scoring mirrors the Mac term weights, including the noise penalty", () => {
  assert.equal(topicRelevanceScore("Usage limit increase for Claude"), 90 + 70 + 35);
  assert.equal(topicRelevanceScore("dogecoin to mars"), -180);
  assert.equal(topicRelevanceScore("nothing relevant here"), 0);
});

test("Priority posts outrank engagement and keep the Mac's freshness windows", () => {
  const quota = post("1", { priority: "token_reset", metrics: { likes: 0, reposts: 0, replies: 0 } });
  const viral = post("2", { text: "unrelated viral thing", metrics: { likes: 50_000, reposts: 9_000, replies: 4_000 } });
  assert.ok(trendingScore(quota, now) > trendingScore(viral, now));
  assert.equal(isWithinFreshnessWindow(post("3", { publishedAt: now - 40 * 3_600_000 }), now), true);
  assert.equal(isWithinFreshnessWindow(post("4", { priority: "token_reset", publishedAt: now - 40 * 3_600_000 }), now), false);
  assert.equal(isWithinFreshnessWindow(post("5", { publishedAt: now - 50 * 3_600_000 }), now), false);
});

test("Curation drops stale posts, caps three normal posts per author, and gates rotating noise", () => {
  const posts = [
    post("a1"), post("a2"), post("a3"), post("a4"),
    post("stale", { publishedAt: now - 60 * 3_600_000 }),
    post("rotating-noise", { tier: "rotating", username: "rando", text: "nothing relevant here" }),
    post("rotating-good", { tier: "rotating", username: "rando", text: "Claude usage limit reset announced" }),
  ];
  const curated = curateForDisplay(posts, now);
  const ids = curated.map((item) => item.id);
  assert.equal(ids.includes("stale"), false);
  assert.equal(ids.includes("rotating-noise"), false);
  assert.equal(ids.includes("rotating-good"), true);
  assert.equal(ids.filter((id) => id.startsWith("a")).length, 3);
});

test("Important keeps only prioritized posts and Trending takes the top two overall", () => {
  const posts = [
    post("quota", { priority: "token_reset" }),
    post("update", { priority: "major_update", username: "AnthropicAI", displayName: "Anthropic" }),
    post("n1", { username: "sama", displayName: "Sam Altman" }),
    post("n2", { username: "tibo", displayName: "Tibo" }),
  ];
  const curated = curateForDisplay(posts, now);
  const important = selectImportantForDisplay(curated, now);
  assert.deepEqual(important.map((item) => item.id), ["quota", "update"]);
  assert.deepEqual(morePosts(curated).map((item) => item.id).sort(), ["n1", "n2"]);
  const stories = topStories(posts, now);
  assert.equal(stories.length, 2);
  assert.equal(stories[0].id, "quota");
});

test("Priority titles and avatar initials match the Mac presentation", () => {
  assert.equal(priorityTitle("token_reset"), "Quota / Token");
  assert.equal(priorityTitle("major_update"), "Major update");
  assert.equal(initials("Sam Altman", "sama"), "SA");
  assert.equal(initials("OpenAI", "OpenAI"), "O");
  assert.equal(initials("", "tibo"), "T");
});
