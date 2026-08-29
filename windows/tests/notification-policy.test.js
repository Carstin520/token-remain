import assert from "node:assert/strict";
import test from "node:test";
import { collectEnabledProviders } from "../electron/providers/index.js";
import {
  decideProviderNotifications,
  MAX_FEED_SEEN_IDS,
  noticeFromError,
  PROVIDER_ALERT_SILENCE_MS,
  requiresSignInNotice,
  selectFeedNotifications,
  signInRequiredError,
  truncateNotificationBody,
} from "../electron/notification-policy.js";

test("Sign-in-required notices prefer a structured marker and recognize legacy message shapes", () => {
  const structured = noticeFromError(signInRequiredError("Provider session needs attention"));
  assert.deepEqual(structured, { message: "Provider session needs attention", kind: "signIn", requiresSignIn: true });
  assert.equal(requiresSignInNotice({ message: "signed out", requiresSignIn: false }), false);

  for (const message of [
    "Claude Code is not signed in on this PC",
    "The account was signed out",
    "Local credential was rejected (401)",
    "Please log in again",
    "Cursor sign-in is stale; open Cursor once to renew it",
  ]) {
    assert.equal(requiresSignInNotice(message), true, message);
  }
});

test("Provider collection carries the structured marker without changing the UI notice", async () => {
  const result = await collectEnabledProviders(["codex"], {
    env: { CODEX_HOME: "/definitely-missing-tokenremain-codex-home" },
  });
  assert.equal(result.notices.codex, "Codex is not signed in on this PC");
  assert.deepEqual(result.notificationNotices.codex, {
    message: result.notices.codex,
    kind: "signIn",
    requiresSignIn: true,
  });
});

test("Chromium network failures are classified without exposing them as sign-in errors", () => {
  const cases = new Map([
    ["net::ERR_CONNECTION_TIMED_OUT", "timeout"],
    ["net::ERR_TIMED_OUT", "timeout"],
    ["net::ERR_INTERNET_DISCONNECTED", "network"],
    ["net::ERR_NAME_NOT_RESOLVED", "network"],
    ["net::ERR_CONNECTION_RESET", "network"],
    ["net::ERR_CONNECTION_REFUSED", "network"],
    ["net::ERR_PROXY_CONNECTION_FAILED", "network"],
    ["net::ERR_PROXY_CERTIFICATE_INVALID", "network"],
  ]);
  for (const [message, kind] of cases) {
    assert.deepEqual(noticeFromError(new Error(message)), { message, kind, requiresSignIn: false });
  }
});

test("AbortSignal and Node transport failures receive timeout or network kinds", () => {
  for (const name of ["AbortError", "TimeoutError"]) {
    const error = new Error("The operation was aborted");
    error.name = name;
    assert.equal(noticeFromError(error).kind, "timeout", name);
  }
  for (const [code, kind] of [
    ["ENOTFOUND", "network"],
    ["ECONNRESET", "network"],
    ["ECONNREFUSED", "network"],
    ["ETIMEDOUT", "timeout"],
  ]) {
    const error = new Error("fetch failed", { cause: Object.assign(new Error(code), { code }) });
    assert.equal(noticeFromError(error).kind, kind, code);
  }
});

test("HTTP 429 failures are classified as rate limits", () => {
  assert.equal(noticeFromError(new Error("Provider request failed (429)")).kind, "rateLimit");
  assert.equal(noticeFromError(Object.assign(new Error("Request failed"), { status: 429 })).kind, "rateLimit");
});

test("Provider alerts observe a 24-hour silence and recovery clears it", () => {
  const now = Date.parse("2026-08-21T08:00:00Z");
  const notices = { codex: { message: "Codex is signed out", requiresSignIn: true } };
  const first = decideProviderNotifications({ notices, attemptedProviderIDs: ["codex"], now });
  assert.deepEqual(first.providerIDs, ["codex"]);

  const quiet = decideProviderNotifications({
    notices,
    attemptedProviderIDs: ["codex"],
    bookkeeping: first.bookkeeping,
    now: now + PROVIDER_ALERT_SILENCE_MS - 1,
  });
  assert.deepEqual(quiet.providerIDs, []);

  const repeated = decideProviderNotifications({
    notices,
    attemptedProviderIDs: ["codex"],
    bookkeeping: quiet.bookkeeping,
    now: now + PROVIDER_ALERT_SILENCE_MS,
  });
  assert.deepEqual(repeated.providerIDs, ["codex"]);

  const recovered = decideProviderNotifications({
    notices: {},
    attemptedProviderIDs: ["codex"],
    bookkeeping: repeated.bookkeeping,
    now: now + PROVIDER_ALERT_SILENCE_MS + 1,
  });
  assert.deepEqual(recovered.bookkeeping.providerSilencedAt, {});

  const signedOutAgain = decideProviderNotifications({
    notices,
    attemptedProviderIDs: ["codex"],
    bookkeeping: recovered.bookkeeping,
    now: now + PROVIDER_ALERT_SILENCE_MS + 2,
  });
  assert.deepEqual(signedOutAgain.providerIDs, ["codex"]);
});

test("Plain network and timeout errors never produce provider alerts", () => {
  for (const message of [
    "Provider request failed (502)",
    "Codex quota request timed out. Check the Windows proxy or firewall, then refresh.",
    "fetch failed",
  ]) {
    const decision = decideProviderNotifications({
      notices: { codex: noticeFromError(new Error(message)) },
      attemptedProviderIDs: ["codex"],
      now: 1_000,
    });
    assert.deepEqual(decision.providerIDs, [], message);
  }
});

test("Feed notifications select only new important posts, cap at three, and bound seen IDs", () => {
  const posts = [
    { id: "seen", priority: "major_update" },
    { id: "token-1", priority: "token_reset" },
    { id: "normal", priority: "normal" },
    { id: "major-1", priority: "major_update" },
    { id: "token-2", priority: "token_reset" },
    { id: "major-2", priority: "major_update" },
  ];
  const result = selectFeedNotifications({ posts, seenIDs: ["seen"], enabled: true });
  assert.deepEqual(result.posts.map((post) => post.id), ["token-1", "major-1", "token-2"]);
  assert.deepEqual(result.seenIDs.slice(0, posts.length), posts.map((post) => post.id));

  const bounded = selectFeedNotifications({
    posts: [],
    seenIDs: Array.from({ length: MAX_FEED_SEEN_IDS + 50 }, (_, index) => `post-${index}`),
    enabled: true,
  });
  assert.equal(bounded.seenIDs.length, MAX_FEED_SEEN_IDS);
});

test("Disabled feed notifications stay quiet while marking fetched posts seen", () => {
  const disabled = selectFeedNotifications({
    posts: [{ id: "new-major", priority: "major_update" }],
    seenIDs: [],
    enabled: false,
  });
  assert.deepEqual(disabled.posts, []);
  assert.deepEqual(disabled.seenIDs, ["new-major"]);

  const enabledLater = selectFeedNotifications({
    posts: [{ id: "new-major", priority: "major_update" }],
    seenIDs: disabled.seenIDs,
    enabled: true,
  });
  assert.deepEqual(enabledLater.posts, []);
});

test("Notification bodies are truncated to 180 user-visible characters", () => {
  const body = truncateNotificationBody("a".repeat(180));
  assert.equal(body.length, 180);
  const truncated = truncateNotificationBody(`${"a".repeat(180)}b`);
  assert.equal(Array.from(truncated).length, 180);
  assert.match(truncated, /…$/);
});
