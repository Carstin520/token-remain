export const PROVIDER_CATALOG = Object.freeze([
  { id: "claude", access: "local-session", product: "Claude Desktop / Claude Code" },
  { id: "codex", access: "local-session", product: "ChatGPT / Codex" },
  { id: "cursor", access: "local-session", product: "Cursor" },
  { id: "copilot", access: "local-session", product: "GitHub Copilot" },
  { id: "devin", access: "local-session", product: "Devin" },
  { id: "windsurf", access: "local-session", product: "Windsurf" },
  { id: "grok", access: "local-session", product: "Grok CLI" },
  { id: "openrouter", access: "local-credential", credentialKind: "API key", environmentKeys: ["OPENROUTER_API_KEY"] },
  { id: "antigravity", access: "local-session", product: "Antigravity" },
  { id: "opencode", access: "local-session", product: "OpenCode" },
  { id: "zai", access: "local-credential", product: "ZCode", localSessionFirst: true, credentialKind: "API key", environmentKeys: ["ZAI_API_KEY"] },
  { id: "deepseek", access: "local-credential", credentialKind: "API key", environmentKeys: ["DEEPSEEK_API_KEY"] },
  { id: "kimi", access: "local-credential", product: "Kimi Code", localSessionFirst: true, credentialKind: "API key or kimi-auth token", environmentKeys: ["KIMI_CODE_API_KEY", "KIMI_API_KEY"] },
  { id: "minimax", access: "local-credential", credentialKind: "API key", environmentKeys: ["MINIMAX_API_KEY"] },
  { id: "mimo", access: "local-credential", credentialKind: "Cookie", environmentKeys: ["MIMO_COOKIE"] },
  { id: "qoder", access: "local-credential", product: "Qoder / QoderCN", localSessionFirst: true, credentialKind: "Cookie fallback", environmentKeys: ["QODER_COOKIE"] },
  { id: "kiro", access: "local-session", product: "Kiro / kiro-cli" },
  { id: "volcengine", access: "local-credential", credentialKind: "AccessKeyId:SecretAccessKey", environmentKeys: ["VOLCENGINE_ACCESS_KEY"] },
  { id: "ollama", access: "local-credential", credentialKind: "Ollama Cloud Cookie", environmentKeys: ["OLLAMA_COOKIE"] },
]);

export const PROVIDER_IDS = Object.freeze(PROVIDER_CATALOG.map((provider) => provider.id));
export const PROVIDER_ID_SET = new Set(PROVIDER_IDS);
export const MANUAL_PROVIDER_IDS = new Set(
  PROVIDER_CATALOG.filter((provider) => provider.access === "local-credential").map((provider) => provider.id),
);

export function providerDefinition(id) {
  return PROVIDER_CATALOG.find((provider) => provider.id === id);
}

export function normalizeProviderIDs(values) {
  const requested = new Set(Array.isArray(values) ? values : []);
  return PROVIDER_IDS.filter((id) => requested.has(id));
}
