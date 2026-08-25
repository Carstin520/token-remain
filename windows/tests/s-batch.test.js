import assert from "node:assert/strict";
import test from "node:test";
import {
  BACKGROUND_DEPTH_STEP,
  DEFAULT_BACKGROUND_DEPTH,
  MAXIMUM_BACKGROUND_BLEND,
  backgroundDepthCSSPercentage,
  normalizeBackgroundDepth,
} from "../electron/background-depth.js";
import { CODEX_USAGE_URL, isAllowedCodexUsageURL } from "../electron/codex-usage.js";

test("Background depth mirrors the macOS range, grid, default, and 25% blend cap", () => {
  assert.equal(DEFAULT_BACKGROUND_DEPTH, 0);
  assert.equal(BACKGROUND_DEPTH_STEP, 0.02);
  assert.equal(MAXIMUM_BACKGROUND_BLEND, 0.25);
  assert.equal(normalizeBackgroundDepth(0.431), 0.44);
  assert.equal(normalizeBackgroundDepth(-1), 0);
  assert.equal(normalizeBackgroundDepth(2), 1);
  assert.equal(backgroundDepthCSSPercentage(0), "0%");
  assert.equal(backgroundDepthCSSPercentage(0.5), "12.5%");
  assert.equal(backgroundDepthCSSPercentage(1), "25%");
});

test("Codex usage links accept only the exact HTTPS management page", () => {
  assert.equal(CODEX_USAGE_URL, "https://chatgpt.com/codex/settings/usage");
  assert.equal(isAllowedCodexUsageURL(CODEX_USAGE_URL), true);
  for (const value of [
    "http://chatgpt.com/codex/settings/usage",
    "https://chatgpt.com/codex/settings/usage?next=1",
    "https://chatgpt.com/codex/settings/usage#credits",
    "https://chatgpt.com/codex/settings/usage/more",
    "https://example.com/codex/settings/usage",
    "javascript:alert(1)",
  ]) assert.equal(isAllowedCodexUsageURL(value), false, value);
});
