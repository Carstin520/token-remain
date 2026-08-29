import assert from "node:assert/strict";
import test from "node:test";
import {
  compareVersionCores,
  fetchLatestRelease,
  isAllowedReleaseURL,
  isDue,
  normalizeUpdateCheckState,
  parseVersionCore,
  validateReleasePayload,
} from "../electron/update-check.js";

const HOUR_MS = 60 * 60_000;
const now = Date.parse("2026-08-21T08:00:00Z");

test("Version comparison uses only the numeric leading semver core", () => {
  assert.deepEqual(parseVersionCore("1.2.6-windows.2"), [1, 2, 6]);
  assert.deepEqual(parseVersionCore("v1.3.6"), [1, 3, 6]);
  assert.equal(compareVersionCores("1.2.6-windows.2", "v1.3.6"), -1);
  assert.equal(compareVersionCores("1.3.6-windows.2", "v1.3.6"), 0);
  assert.equal(compareVersionCores("1.4.0-windows.1", "v1.3.6"), 1);
});

test("Malformed versions do not participate in comparison", () => {
  for (const value of [undefined, "", "1.2", "1.2.3.4", "release-1.2.3", "01.2.3"]) {
    assert.equal(parseVersionCore(value), undefined, String(value));
  }
  assert.equal(compareVersionCores("broken", "1.3.6"), undefined);
  assert.equal(compareVersionCores("1.2.6", "broken"), undefined);
});

test("No-update checks become due after six hours", () => {
  assert.equal(isDue({ lastCheckedAt: now, outcome: "no-update", now: now + 6 * HOUR_MS - 1 }), false);
  assert.equal(isDue({ lastCheckedAt: now, outcome: "no-update", now: now + 6 * HOUR_MS }), true);
  assert.equal(isDue({ outcome: "no-update", now }), true);
});

test("Available-update checks become due after twelve hours", () => {
  assert.equal(isDue({ lastCheckedAt: now, outcome: "update-available", now: now + 12 * HOUR_MS - 1 }), false);
  assert.equal(isDue({ lastCheckedAt: now, outcome: "update-available", now: now + 12 * HOUR_MS }), true);
});

test("Failure retries back off from one to three to six hours and then cap", () => {
  for (const [failureCount, hours] of [[1, 1], [2, 3], [3, 6], [20, 6]]) {
    assert.equal(isDue({ lastCheckedAt: now, outcome: "failure", failureCount, now: now + hours * HOUR_MS - 1 }), false);
    assert.equal(isDue({ lastCheckedAt: now, outcome: "failure", failureCount, now: now + hours * HOUR_MS }), true);
  }
});

test("Release payload validation returns a normalized version and canonical URL", () => {
  assert.deepEqual(validateReleasePayload({
    tag_name: "v1.3.6",
    html_url: "https://github.com/Carstin520/token-remain/releases/tag/v1.3.6",
  }), {
    version: "1.3.6",
    tagName: "v1.3.6",
    url: "https://github.com/Carstin520/token-remain/releases/tag/v1.3.6",
  });
});

test("Release payload validation rejects malformed tags, URLs, and mismatched tags", () => {
  assert.throws(() => validateReleasePayload({ tag_name: "latest", html_url: "https://github.com/Carstin520/token-remain/releases/latest" }), /tag/i);
  assert.throws(() => validateReleasePayload({ tag_name: "v1.3.6", html_url: "https://example.com/Carstin520/token-remain/releases/tag/v1.3.6" }), /URL/i);
  assert.throws(() => validateReleasePayload({ tag_name: "v1.3.6", html_url: "https://github.com/Carstin520/token-remain/releases/tag/v1.3.5" }), /match/i);
});

test("Release URL allow-list accepts only HTTPS pages in the intended GitHub repository", () => {
  assert.equal(isAllowedReleaseURL("https://github.com/Carstin520/token-remain/releases"), true);
  assert.equal(isAllowedReleaseURL("https://github.com/Carstin520/token-remain/releases/latest"), true);
  assert.equal(isAllowedReleaseURL("https://github.com/Carstin520/token-remain/releases/tag/v1.3.6"), true);
  assert.equal(isAllowedReleaseURL("http://github.com/Carstin520/token-remain/releases/tag/v1.3.6"), false);
  assert.equal(isAllowedReleaseURL("https://github.com/other/token-remain/releases/tag/v1.3.6"), false);
  assert.equal(isAllowedReleaseURL("https://github.com/Carstin520/token-remain/releases/download/v1.3.6/app.exe"), false);
  assert.equal(isAllowedReleaseURL("https://github.com/Carstin520/token-remain/releases/tag/v1.3.6?download=1"), false);
});

test("Persisted update bookkeeping is bounded and validated", () => {
  assert.deepEqual(normalizeUpdateCheckState({
    lastCheckedAt: now,
    etag: ' W/"release-etag" ',
    availableVersion: "v1.3.6",
    availableURL: "https://github.com/Carstin520/token-remain/releases/tag/v1.3.6",
    failureCount: 99,
  }, { now }), {
    lastCheckedAt: now,
    etag: 'W/"release-etag"',
    availableVersion: "1.3.6",
    availableURL: "https://github.com/Carstin520/token-remain/releases/tag/v1.3.6",
    failureCount: 3,
  });
  assert.deepEqual(normalizeUpdateCheckState({
    lastCheckedAt: now + 1,
    etag: "x".repeat(300),
    availableVersion: "1.3.6",
    availableURL: "https://example.com/releases/tag/v1.3.6",
    failureCount: -1,
  }, { now }), { failureCount: 0 });
});

test("Latest-release fetch sends an ETag and accepts a 304 without reading a body", async () => {
  let request;
  const result = await fetchLatestRelease({
    etag: 'W/"cached"',
    fetchImpl: async (url, options) => {
      request = { url: String(url), options };
      return {
        status: 304,
        ok: false,
        headers: { get: (name) => name === "etag" ? 'W/"cached"' : undefined },
      };
    },
  });
  assert.match(request.url, /api\.github\.com\/repos\/Carstin520\/token-remain\/releases\/latest$/);
  assert.equal(request.options.headers["If-None-Match"], 'W/"cached"');
  assert.deepEqual(result, { notModified: true, etag: 'W/"cached"' });
});
