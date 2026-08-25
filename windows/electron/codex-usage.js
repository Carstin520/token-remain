export const CODEX_USAGE_URL = "https://chatgpt.com/codex/settings/usage";

export function isAllowedCodexUsageURL(value) {
  if (typeof value !== "string") return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:"
      && url.hostname === "chatgpt.com"
      && url.pathname === "/codex/settings/usage"
      && !url.username
      && !url.password
      && !url.port
      && !url.search
      && !url.hash;
  } catch {
    return false;
  }
}
