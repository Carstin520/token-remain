import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  LOCAL_AI_ACTIVITY_GRACE_MS,
  LocalAISessionActivityMonitor,
  latestSessionModificationAt,
  resolveLocalAISessionRoots,
} from "../electron/session-activity.js";

test("Session activity roots honor Codex and Claude overrides plus the Windows Claude Desktop root", () => {
  assert.deepEqual(resolveLocalAISessionRoots({
    env: {
      CODEX_HOME: "%USERPROFILE%\\codex-home",
      CLAUDE_CONFIG_DIR: "~/.claude-work",
      USERPROFILE: "C:\\Users\\Test",
      APPDATA: "C:\\Users\\Test\\AppData\\Roaming",
    },
    home: "C:\\Users\\Test",
  }), [
    join("C:\\Users\\Test\\codex-home", "sessions"),
    join("C:\\Users\\Test", ".claude-work", "projects"),
    join("C:\\Users\\Test\\AppData\\Roaming", "Claude", "local-agent-mode-sessions"),
  ]);
});

test("Recent JSONL activity is seeded, bounded against future mtimes, and ages out after three minutes", async () => {
  const root = await mkdtemp(join(tmpdir(), "tokenremain-session-activity-"));
  const now = Date.parse("2026-08-26T10:00:00Z");
  try {
    const nested = join(root, "nested");
    await mkdir(nested);
    await writeFile(join(nested, "notes.txt"), "not a session");
    const session = join(nested, "session.jsonl");
    await writeFile(session, "{}\n");
    const future = new Date(now + 86_400_000);
    await utimes(session, future, future);

    assert.equal(await latestSessionModificationAt([root], { now }), now);
    const monitor = new LocalAISessionActivityMonitor({ roots: [root] });
    await monitor.sweep(now);
    assert.equal(monitor.lastActivityAt, now);
    assert.equal(monitor.hasRecentSessionActivity(now), true);
    assert.equal(monitor.hasRecentSessionActivity(now + LOCAL_AI_ACTIVITY_GRACE_MS), true);
    assert.equal(monitor.hasRecentSessionActivity(now + LOCAL_AI_ACTIVITY_GRACE_MS + 1), false);
    monitor.stop();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("A session root created after launch is discovered and seeded on the next sweep", async () => {
  const parent = await mkdtemp(join(tmpdir(), "tokenremain-late-session-root-"));
  const root = join(parent, "sessions");
  const now = Date.parse("2026-08-26T10:00:00Z");
  const monitor = new LocalAISessionActivityMonitor({ roots: [root] });
  try {
    await monitor.sweep(now);
    assert.equal(monitor.hasRecentSessionActivity(now), false);

    await mkdir(root);
    const session = join(root, "late.jsonl");
    await writeFile(session, "{}\n");
    const modifiedAt = new Date(now - 30_000);
    await utimes(session, modifiedAt, modifiedAt);
    await monitor.sweep(now);

    assert.equal(monitor.lastActivityAt, modifiedAt.getTime());
    assert.equal(monitor.hasRecentSessionActivity(now), true);
  } finally {
    monitor.stop();
    await rm(parent, { recursive: true, force: true });
  }
});

test("Recursive watch failure falls back to a root watcher while stat sweeps cover nested files", async () => {
  const root = await mkdtemp(join(tmpdir(), "tokenremain-watch-fallback-"));
  const calls = [];
  const fakeWatcher = { on() {}, unref() {}, close() {} };
  const watchImpl = (...args) => {
    calls.push(args);
    if (typeof args[1] === "object") throw new Error("recursive watch unsupported");
    return fakeWatcher;
  };
  const monitor = new LocalAISessionActivityMonitor({ roots: [root], watchImpl });
  try {
    await monitor.sweep();
    assert.equal(calls.length, 2);
    assert.deepEqual(calls[0][1], { recursive: true });
    assert.equal(typeof calls[1][1], "function");
  } finally {
    monitor.stop();
    await rm(root, { recursive: true, force: true });
  }
});
