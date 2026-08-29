import { collectClaude } from "../collectors/claude.js";
import { collectCodex } from "../collectors/codex.js";
import { detectHostAppRoute } from "../host-routing.js";
import { noticeFromError } from "../notification-policy.js";
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
  if (providerID === "claude" || providerID === "codex") {
    const route = await detectHostAppRoute(providerID, { env: options.env, home: options.home });
    if (route.external && route.rerouteProviderID) {
      try {
        const source = await collectManualProvider(route.rerouteProviderID, {
          ...options,
          routeCredential: route.credential,
          ...(route.rerouteProviderID === "zai"
            ? { zaiRegion: route.baseURL && /(?:^|\.)bigmodel\.cn$/i.test(new URL(route.baseURL).hostname) ? "china" : "global" }
            : {}),
        });
        return { ...source, providerID, attribution: route.attribution };
      } catch (error) {
        const routed = new Error(`${route.displayName}: ${error instanceof Error ? error.message : String(error)}`, { cause: error });
        if (error?.requiresSignIn === true) routed.requiresSignIn = true;
        throw routed;
      }
    }
    // Generic relays and MiMo are labeling-only in this Windows batch: there
    // is no compatible existing route credential collector to call safely.
    const source = await collector(options);
    return route.external ? { ...source, attribution: route.attribution } : source;
  }
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
  const notificationNotices = {};
  for (const [index, result] of results.entries()) {
    const providerID = enabled[index];
    if (result.status === "fulfilled") {
      const { collectorNotice, ...provider } = result.value;
      providers.push(provider);
      if (collectorNotice) {
        const notice = collectorNotice?.message ? collectorNotice : noticeFromError(collectorNotice);
        notices[providerID] = notice.message;
        notificationNotices[providerID] = notice;
      }
    } else {
      const notice = noticeFromError(result.reason);
      notices[providerID] = notice.message;
      notificationNotices[providerID] = notice;
    }
  }
  return { providers, notices, notificationNotices };
}
