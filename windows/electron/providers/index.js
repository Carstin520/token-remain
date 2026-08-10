import { collectClaude } from "../collectors/claude.js";
import { collectCodex } from "../collectors/codex.js";
import { MANUAL_PROVIDER_IDS, normalizeProviderIDs } from "./catalog.js";
import {
  collectAntigravity,
  collectCopilot,
  collectCursor,
  collectDevin,
  collectGrok,
  collectKiro,
  collectOpenCode,
  collectWindsurf,
} from "./local-session.js";
import { collectManualProvider } from "./manual.js";

const AUTOMATIC_COLLECTORS = {
  claude: collectClaude,
  codex: collectCodex,
  cursor: collectCursor,
  copilot: collectCopilot,
  devin: collectDevin,
  windsurf: collectWindsurf,
  grok: collectGrok,
  antigravity: collectAntigravity,
  opencode: collectOpenCode,
  kiro: collectKiro,
};

export const LOCAL_PROVIDER_IDS = Object.freeze(normalizeProviderIDs([
  ...Object.keys(AUTOMATIC_COLLECTORS),
  ...MANUAL_PROVIDER_IDS,
]));

export async function collectProvider(providerID, options = {}) {
  if (MANUAL_PROVIDER_IDS.has(providerID)) return collectManualProvider(providerID, options);
  const collector = AUTOMATIC_COLLECTORS[providerID];
  if (!collector) throw new Error("This provider has no Windows-local adapter");
  return collector(options);
}

export async function collectEnabledProviders(providerIDs, options = {}) {
  const enabled = normalizeProviderIDs(providerIDs);
  const results = await Promise.allSettled(enabled.map((providerID) => collectProvider(providerID, {
    ...options,
    storedSecret: options.getStoredSecret?.(providerID),
  })));
  const providers = [];
  const notices = {};
  for (const [index, result] of results.entries()) {
    const providerID = enabled[index];
    if (result.status === "fulfilled") providers.push(result.value);
    else notices[providerID] = result.reason instanceof Error ? result.reason.message : String(result.reason);
  }
  return { providers, notices };
}
