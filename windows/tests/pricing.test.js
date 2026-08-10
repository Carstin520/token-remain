import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  mergeRuntimeConfiguration,
  MINIMUM_VALID_PRICE_COUNT,
  parsePublicPricing,
  PublicPricingService,
} from "../electron/pricing.js";

function publicTable() {
  const result = {
    "claude-opus-5": {
      input_cost_per_token: 0.000005,
      output_cost_per_token: 0.000025,
      cache_creation_input_token_cost: 0.00000625,
      cache_read_input_token_cost: 0.0000005,
      max_input_tokens: 200_000,
    },
    "gpt-test": { input_cost_per_token: 0.000001, output_cost_per_token: 0.000002 },
    "claude-opus-5-0": { input_cost_per_token: 0.000005, output_cost_per_token: 0.000025 },
  };
  for (let index = 0; index < MINIMUM_VALID_PRICE_COUNT - 3; index += 1) {
    result[`model-${index}`] = { input_cost_per_token: 0.000001, output_cost_per_token: 0.000002 };
  }
  return result;
}

test("LiteLLM public rows become validated ccusage pricing overrides", () => {
  const values = parsePublicPricing(JSON.stringify(publicTable()));
  assert.equal(Object.keys(values).length, MINIMUM_VALID_PRICE_COUNT);
  assert.equal(values["claude-opus-5"].inputCostPerToken, 0.000005);
  assert.equal(values["claude-opus-5"].cacheReadInputTokenCost, 0.0000005);
  assert.equal(values["claude-opus-5"].maxInputTokens, 200_000);
});

test("App price configuration calculates locally while preserving user overrides", () => {
  const values = parsePublicPricing(JSON.stringify(publicTable()));
  const config = mergeRuntimeConfiguration(values, {
    defaults: {
      pricingOverrides: {
        "claude-opus-5": { outputCostPerToken: 0.123 },
        "private-model": { inputCostPerToken: 0.4, outputCostPerToken: 0.5 },
      },
    },
  });
  assert.equal(config.defaults.mode, "calculate");
  assert.equal(config.defaults.pricingOverrides["claude-opus-5"].inputCostPerToken, 0.000005);
  assert.equal(config.defaults.pricingOverrides["claude-opus-5"].outputCostPerToken, 0.123);
  assert.equal(config.defaults.pricingOverrides["private-model"].outputCostPerToken, 0.5);
  assert.deepEqual(
    config.defaults.pricingOverrides["claude-5.0-opus"],
    config.defaults.pricingOverrides["claude-opus-5-0"],
  );
});

test("Public prices cache locally and conditional refresh keeps the last good table", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tokenremain-windows-pricing-"));
  try {
    let requests = 0;
    const first = new PublicPricingService({
      cacheDirectory: directory,
      homeDirectory: directory,
      environment: {},
      fetchImpl: async (_url, options) => {
        requests += 1;
        assert.equal(options.method, "GET");
        assert.equal(options.body, undefined);
        return new Response(JSON.stringify(publicTable()), {
          status: 200,
          headers: { etag: '"pricing-v1"', "last-modified": "Sun, 10 Aug 2026 00:00:00 GMT" },
        });
      },
    });
    const firstPath = await first.configurationPath(Date.parse("2026-08-10T00:00:00Z"));
    const config = JSON.parse(await readFile(firstPath, "utf8"));
    assert.equal(config.defaults.mode, "calculate");
    assert.ok(config.defaults.pricingOverrides["gpt-test"]);
    assert.equal(first.getStatus().modelCount, MINIMUM_VALID_PRICE_COUNT);

    const second = new PublicPricingService({
      cacheDirectory: directory,
      homeDirectory: directory,
      environment: {},
      fetchImpl: async (_url, options) => {
        requests += 1;
        assert.equal(options.headers["If-None-Match"], '"pricing-v1"');
        return new Response(null, { status: 304, headers: { etag: '"pricing-v1"' } });
      },
    });
    await second.configurationPath(Date.parse("2026-08-10T07:00:00Z"));
    assert.equal(second.getStatus().modelCount, MINIMUM_VALID_PRICE_COUNT);
    assert.equal(requests, 2);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
