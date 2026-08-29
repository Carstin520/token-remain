import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  CodexSnapshotFileCache,
  codexQuotaFromSnapshots,
  codexWireScopeBase,
  collectCodexLocalSnapshot,
  parseCodexSessionSnapshots,
} from "../electron/codex-snapshots.js";
import { collectCodex } from "../electron/collectors/codex.js";
import { collectEnabledProviders } from "../electron/providers/index.js";

const RESET_AT = 1_800_000_000;

function tokenCount({
  timestamp,
  limitID,
  limitName,
  planType,
  usedPercent,
  windowMinutes,
  secondary,
  resetsAt = RESET_AT,
}) {
  const window = (percent, minutes) => ({
    used_percent: percent,
    window_minutes: minutes,
    ...(resetsAt === null ? {} : { resets_at: resetsAt }),
  });
  return {
    timestamp,
    payload: {
      type: "token_count",
      rate_limits: {
        ...(limitID ? { limit_id: limitID } : {}),
        ...(limitName ? { limit_name: limitName } : {}),
        ...(planType ? { plan_type: planType } : {}),
        primary: window(usedPercent, windowMinutes),
        ...(secondary ? { secondary: window(secondary.usedPercent, secondary.windowMinutes) } : {}),
      },
    },
  };
}

function jsonl(rows) {
  return `${rows.map((row) => JSON.stringify(row)).join("\n")}\n`;
}

async function temporaryCodexHome() {
  const home = await mkdtemp(join(tmpdir(), "tokenremain-codex-snapshots-"));
  await mkdir(join(home, "sessions"), { recursive: true });
  await mkdir(join(home, "archived_sessions"), { recursive: true });
  return home;
}

test("Codex tail parser keeps the canonical quota and newest model session/weekly pair", () => {
  const snapshots = parseCodexSessionSnapshots(jsonl([
    tokenCount({
      timestamp: "2026-07-17T11:35:06.513Z",
      limitID: "codex",
      planType: "prolite",
      usedPercent: 31,
      windowMinutes: 300,
      secondary: { usedPercent: 22, windowMinutes: 10_080 },
    }),
    tokenCount({
      timestamp: "2026-07-17T11:35:12.000Z",
      limitID: "codex_bengalfox",
      limitName: "GPT-5.3-Codex-Spark",
      usedPercent: 9,
      windowMinutes: 300,
      secondary: { usedPercent: 40, windowMinutes: 10_080 },
    }),
    tokenCount({
      timestamp: "2026-07-17T11:35:24.973Z",
      limitID: "codex_bengalfox",
      limitName: "GPT-5.3-Codex-Spark",
      usedPercent: 10,
      windowMinutes: 300,
      secondary: { usedPercent: 44, windowMinutes: 10_080 },
    }),
  ]));
  const quota = codexQuotaFromSnapshots(snapshots);

  assert.equal(quota.planName, "prolite");
  assert.deepEqual(quota.windows.map((window) => [window.usedPercent, window.windowMinutes]), [[31, 300], [22, 10_080]]);
  assert.deepEqual(quota.scopedWindows.map((scope) => scope.scopeID), [
    "codex_bengalfox_session",
    "codex_bengalfox_weekly",
  ]);
  assert.deepEqual(quota.scopedWindows.map((scope) => scope.window.usedPercent), [10, 44]);
});

test("Codex local snapshots keep missing reset times and stable collision-free long scope IDs", () => {
  const alpha = "codex_bengalfox_pro_extended_alpha";
  const beta = "codex_bengalfox_pro_extended_beta";
  const snapshots = parseCodexSessionSnapshots(jsonl([
    tokenCount({ timestamp: "2026-07-17T11:00:00Z", limitID: "codex", usedPercent: 31, windowMinutes: 300, resetsAt: null }),
    tokenCount({ timestamp: "2026-07-17T11:01:00Z", limitID: alpha, limitName: "Spark Alpha", usedPercent: 9, windowMinutes: 300, resetsAt: null }),
    tokenCount({ timestamp: "2026-07-17T11:02:00Z", limitID: beta, limitName: "Spark Beta", usedPercent: 77, windowMinutes: 300, resetsAt: null }),
  ]));
  const quota = codexQuotaFromSnapshots(snapshots);

  assert.equal(quota.windows[0].resetsAt, undefined);
  assert.equal(codexWireScopeBase(alpha), "codex_bengalfox_071fde96");
  assert.equal(codexWireScopeBase(beta), "codex_bengalfox_563343ac");
  assert.equal(new Set(quota.scopedWindows.map((scope) => scope.scopeID)).size, 2);
  assert.ok(quota.scopedWindows.every((scope) => scope.scopeID.length <= 32));
});

test("Codex snapshot discovery searches nested sessions and archived_sessions and keeps the newest canonical event", async () => {
  const home = await temporaryCodexHome();
  try {
    const archived = join(home, "archived_sessions", "old.jsonl");
    const currentDirectory = join(home, "sessions", "2026", "08", "26");
    await mkdir(currentDirectory, { recursive: true });
    await writeFile(archived, jsonl([tokenCount({ timestamp: "2026-08-26T08:00:00Z", limitID: "codex", usedPercent: 80, windowMinutes: 300 })]));
    await writeFile(join(currentDirectory, "rollout-new.jsonl"), jsonl([
      tokenCount({ timestamp: "2026-08-26T10:00:00Z", limitID: "codex", planType: "pro", usedPercent: 55, windowMinutes: 300 }),
    ]));

    const quota = await collectCodexLocalSnapshot(home, { cache: new CodexSnapshotFileCache() });
    assert.equal(quota.windows[0].usedPercent, 55);
    assert.equal(quota.planName, "pro");
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("Codex snapshot cache trusts unchanged mtimes and invalidates rewritten files", async () => {
  const home = await temporaryCodexHome();
  let reads = 0;
  const cache = new CodexSnapshotFileCache({
    readTail: async (path) => {
      reads += 1;
      return readFile(path, "utf8");
    },
  });
  const path = join(home, "sessions", "session.jsonl");
  const pinned = new Date("2026-08-26T10:05:00Z");
  try {
    await writeFile(path, jsonl([tokenCount({ timestamp: "2026-08-26T10:00:00Z", limitID: "codex", usedPercent: 50, windowMinutes: 300 })]));
    await utimes(path, pinned, pinned);
    assert.equal((await collectCodexLocalSnapshot(home, { cache })).windows[0].usedPercent, 50);
    assert.equal(reads, 1);

    await writeFile(path, jsonl([tokenCount({ timestamp: "2026-08-26T10:01:00Z", limitID: "codex", usedPercent: 90, windowMinutes: 300 })]));
    await utimes(path, pinned, pinned);
    assert.equal((await collectCodexLocalSnapshot(home, { cache })).windows[0].usedPercent, 50);
    assert.equal(reads, 1);

    const changed = new Date(pinned.getTime() + 1_000);
    await utimes(path, changed, changed);
    assert.equal((await collectCodexLocalSnapshot(home, { cache })).windows[0].usedPercent, 90);
    assert.equal(reads, 2);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("A newly discovered Codex session survives an mtime rollback beyond the 24-hour early-stop allowance", async () => {
  const home = await temporaryCodexHome();
  const cache = new CodexSnapshotFileCache();
  try {
    const established = join(home, "sessions", "established.jsonl");
    await writeFile(established, jsonl([tokenCount({ timestamp: "2026-08-26T11:00:00Z", limitID: "codex", usedPercent: 40, windowMinutes: 300 })]));
    const establishedMtime = new Date("2026-08-26T11:05:00Z");
    await utimes(established, establishedMtime, establishedMtime);
    assert.equal((await collectCodexLocalSnapshot(home, { cache })).windows[0].usedPercent, 40);

    const rolledBack = join(home, "sessions", "rolled-back.jsonl");
    await writeFile(rolledBack, jsonl([tokenCount({ timestamp: "2026-08-26T12:00:00Z", limitID: "codex", usedPercent: 65, windowMinutes: 300 })]));
    const rolledBackMtime = new Date("2026-08-24T11:00:00Z");
    await utimes(rolledBack, rolledBackMtime, rolledBackMtime);

    assert.equal((await collectCodexLocalSnapshot(home, { cache })).windows[0].usedPercent, 65);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("Codex API sign-in failure returns a local quota while preserving the structured sign-in notice", async () => {
  const home = await temporaryCodexHome();
  try {
    await writeFile(join(home, "sessions", "fallback.jsonl"), jsonl([
      tokenCount({ timestamp: "2026-08-26T12:00:00Z", limitID: "codex", usedPercent: 65, windowMinutes: 300 }),
    ]));
    const quota = await collectCodex({ env: { CODEX_HOME: home }, snapshotCache: new CodexSnapshotFileCache() });

    assert.equal(quota.providerID, "codex");
    assert.equal(quota.windows[0].usedPercent, 65);
    assert.deepEqual(quota.collectorNotice, {
      message: "Codex is not signed in on this PC",
      kind: "signIn",
      requiresSignIn: true,
    });
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("Codex fallback notice reaches provider notifications without leaking the collector-only field", async () => {
  const home = await temporaryCodexHome();
  try {
    await writeFile(join(home, "sessions", "fallback.jsonl"), jsonl([
      tokenCount({ timestamp: "2026-08-26T12:00:00Z", limitID: "codex", usedPercent: 65, windowMinutes: 300 }),
    ]));
    const result = await collectEnabledProviders(["codex"], {
      env: { CODEX_HOME: home },
      snapshotCache: new CodexSnapshotFileCache(),
    });

    assert.equal(result.providers[0].windows[0].usedPercent, 65);
    assert.equal(result.providers[0].collectorNotice, undefined);
    assert.deepEqual(result.notificationNotices.codex, {
      message: "Codex is not signed in on this PC",
      kind: "signIn",
      requiresSignIn: true,
    });
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
