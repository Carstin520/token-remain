export const LOCAL_USAGE_SOURCE_CATALOG = Object.freeze([
  { id: "claude", displayName: "Claude Code" },
  { id: "codex", displayName: "Codex" },
  { id: "opencode", displayName: "OpenCode" },
  { id: "amp", displayName: "Amp" },
  { id: "droid", displayName: "Droid" },
  { id: "codebuff", displayName: "Codebuff" },
  { id: "hermes", displayName: "Hermes Agent" },
  { id: "pi", displayName: "pi-agent" },
  { id: "goose", displayName: "Goose" },
  { id: "openclaw", displayName: "OpenClaw" },
  { id: "kilo", displayName: "Kilo Code" },
  { id: "kimi", displayName: "Kimi CLI" },
  { id: "qwen", displayName: "Qwen CLI" },
  { id: "copilot", displayName: "GitHub Copilot CLI" },
  { id: "gemini", displayName: "Gemini" },
  { id: "trae-agent", displayName: "Trae Agent" },
].map(Object.freeze));

const SOURCE_BY_ID = new Map(LOCAL_USAGE_SOURCE_CATALOG.map((source) => [source.id, source]));
const SOURCE_INDEX_BY_ID = new Map(LOCAL_USAGE_SOURCE_CATALOG.map((source, index) => [source.id, index]));

export function canonicalLocalSourceID(value) {
  return String(value ?? "").trim().toLowerCase();
}

export function isWellFormedLocalSourceID(value) {
  return /^[a-z0-9][a-z0-9._-]{0,63}$/.test(canonicalLocalSourceID(value));
}

export function localSourceDisplayName(value) {
  const id = canonicalLocalSourceID(value);
  const known = SOURCE_BY_ID.get(id);
  if (known) return known.displayName;
  return id.split(/[-_]/).filter(Boolean).map((part) => (
    part ? `${part.charAt(0).toUpperCase()}${part.slice(1).toLowerCase()}` : ""
  )).join(" ");
}

export function compareLocalSourceIDs(left, right) {
  const leftID = canonicalLocalSourceID(left);
  const rightID = canonicalLocalSourceID(right);
  const leftIndex = SOURCE_INDEX_BY_ID.get(leftID) ?? LOCAL_USAGE_SOURCE_CATALOG.length;
  const rightIndex = SOURCE_INDEX_BY_ID.get(rightID) ?? LOCAL_USAGE_SOURCE_CATALOG.length;
  return leftIndex - rightIndex || leftID.localeCompare(rightID);
}

export function normalizeDisabledLocalUsageSources(value) {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.flatMap((item) => {
    if (typeof item !== "string") return [];
    const id = canonicalLocalSourceID(item);
    return isWellFormedLocalSourceID(id) ? [id] : [];
  }))].sort();
}

/// Only sources actually present in the bounded recent history become rows.
/// The catalog is a naming/order authority, not a reason to render undiscovered
/// agents on a machine that has never used them.
export function detectedLocalUsageSources(history) {
  const ids = new Set();
  for (const day of history?.days || []) {
    if (Array.isArray(day?.agents)) {
      for (const agent of day.agents) {
        const id = canonicalLocalSourceID(agent?.id);
        if (isWellFormedLocalSourceID(id)) ids.add(id);
      }
      continue;
    }
    if (Number.isFinite(day?.claudeTokens) && day.claudeTokens > 0) ids.add("claude");
    if (Number.isFinite(day?.codexTokens) && day.codexTokens > 0) ids.add("codex");
  }
  return [...ids].sort(compareLocalSourceIDs).map((id) => ({
    id,
    displayName: localSourceDisplayName(id),
    capturedAt: Number.isFinite(history?.capturedAt) ? history.capturedAt : undefined,
  }));
}
