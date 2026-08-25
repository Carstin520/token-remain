import assert from "node:assert/strict";
import test from "node:test";
import {
  isAbnormalServiceStatus,
  normalizeProviderStatusPayload,
  ServiceStatusService,
} from "../electron/service-status.js";

const now = Date.parse("2026-08-21T08:00:00Z");

function response(indicator = "minor", description = "Minor Service Outage") {
  return new Response(JSON.stringify({ status: { indicator, description } }), { status: 200 });
}

test("Provider status payload normalizes every supported indicator", () => {
  for (const indicator of ["none", "minor", "major", "critical"]) {
    assert.deepEqual(normalizeProviderStatusPayload({
      status: { indicator, description: "  Provider status  " },
    }), { indicator, description: "Provider status" });
  }
});

test("Provider status payload rejects malformed and oversized fields", () => {
  for (const payload of [
    undefined,
    {},
    { status: [] },
    { status: { indicator: "maintenance", description: "Maintenance" } },
    { status: { indicator: "minor", description: "" } },
    { status: { indicator: "minor", description: "x".repeat(513) } },
  ]) assert.throws(() => normalizeProviderStatusPayload(payload));
});

test("Abnormal predicate accepts only minor, major, and critical", () => {
  assert.equal(isAbnormalServiceStatus({ indicator: "none" }), false);
  assert.equal(isAbnormalServiceStatus({ indicator: "minor" }), true);
  assert.equal(isAbnormalServiceStatus("major"), true);
  assert.equal(isAbnormalServiceStatus("critical"), true);
  assert.equal(isAbnormalServiceStatus({ indicator: "unknown" }), false);
});

test("Provider status cadence skips fetches before 300 seconds", async () => {
  let requests = 0;
  const service = new ServiceStatusService({
    fetchImpl: async () => {
      requests += 1;
      return response();
    },
  });
  assert.equal(await service.refreshIfNeeded(now), true);
  assert.equal(requests, 2);
  assert.equal(await service.refreshIfNeeded(now + 299_999), false);
  assert.equal(requests, 2);
  assert.equal(await service.refreshIfNeeded(now + 300_000), true);
  assert.equal(requests, 4);
});

test("Provider status failures retain the last result until the stale cutoff", async () => {
  let failing = false;
  const service = new ServiceStatusService({
    staleAfterMs: 600_000,
    fetchImpl: async () => {
      if (failing) throw new Error("offline");
      return response("critical", "Major Service Outage");
    },
  });
  await service.refreshIfNeeded(now);
  failing = true;
  await service.refreshIfNeeded(now + 300_000);
  assert.equal(service.getStatuses(now + 599_999).claude.indicator, "critical");
  assert.deepEqual(service.getStatuses(now + 600_000), {});
});

test("Provider status fetch rejects oversized responses without replacing last-known data", async () => {
  let oversized = false;
  const service = new ServiceStatusService({
    fetchImpl: async () => oversized
      ? new Response("{}", { status: 200, headers: { "content-length": String(256 * 1024 + 1) } })
      : response("major", "Partial System Outage"),
  });
  await service.refreshIfNeeded(now);
  oversized = true;
  await service.refreshIfNeeded(now + 300_000);
  assert.equal(service.getStatuses(now + 300_000).codex.indicator, "major");
});
