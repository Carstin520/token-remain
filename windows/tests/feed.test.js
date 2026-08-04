import assert from "node:assert/strict";
import test from "node:test";
import { decodeCuratedFeed, fetchCuratedFeed, isAllowedPostURL } from "../electron/feed.js";

const now = Date.parse("2026-08-04T08:00:00Z");

function item(overrides = {}) {
  return {
    id: "1234567890123456789",
    text: "A useful product update.",
    author: { username: "OpenAI", displayName: "OpenAI" },
    publishedAt: "2026-08-04T07:00:00Z",
    url: "https://x.com/OpenAI/status/1234567890123456789",
    priority: "normal",
    tier: "primary",
    metrics: { likes: 12, reposts: 3, replies: 4 },
    ...overrides,
  };
}

test("Feed decoder keeps valid items, skips malformed neighbors, and tolerates future enums", () => {
  const decoded = decodeCuratedFeed({ items: [
    item(),
    item({ id: "bad", url: "javascript:alert(1)" }),
    item({ id: "2234567890123456789", url: "https://x.com/OpenAI/status/2234567890123456789", priority: "future_priority", tier: "future_tier" }),
  ] }, { now });
  assert.equal(decoded.length, 2);
  assert.equal(decoded[1].priority, "normal");
  assert.equal(decoded[1].tier, "primary");
});

test("Feed links are restricted to canonical HTTPS post URLs", () => {
  assert.equal(isAllowedPostURL("https://x.com/OpenAI/status/1234567890123456789"), true);
  assert.equal(isAllowedPostURL("http://x.com/OpenAI/status/1234567890123456789"), false);
  assert.equal(isAllowedPostURL("https://example.com/OpenAI/status/1234567890123456789"), false);
  assert.equal(isAllowedPostURL("https://x.com/OpenAI/home"), false);
});

test("Feed fetch rejects oversized payloads before parsing", async () => {
  await assert.rejects(fetchCuratedFeed({
    now,
    fetchImpl: async () => ({
      ok: true,
      headers: { get: () => String(300 * 1024) },
      arrayBuffer: async () => new ArrayBuffer(0),
    }),
  }), /too large/i);
});
