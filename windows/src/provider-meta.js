export const PROVIDER_ORDER = [
  "claude",
  "codex",
  "cursor",
  "copilot",
  "devin",
  "windsurf",
  "grok",
  "openrouter",
  "antigravity",
  "opencode",
  "zai",
  "deepseek",
  "kimi",
  "minimax",
  "mimo",
  "qoder",
  "kiro",
  "volcengine",
  "ollama",
];

const PROVIDER_META = {
  claude: { name: "Claude", icon: "claude-code.svg", color: "var(--claude)" },
  codex: { name: "Codex", icon: "codex.svg", color: "var(--codex)" },
  cursor: { name: "Cursor", icon: "cursor.svg", color: "#a78bfa" },
  copilot: { name: "Copilot", icon: "copilot.svg", color: "#9da7b8" },
  devin: { name: "Devin", icon: "devin.svg", color: "#70b7ff" },
  windsurf: { name: "Windsurf", icon: "windsurf.png", color: "#55c8d9" },
  grok: { name: "Grok", icon: "grok.svg", color: "#c9cbd3" },
  openrouter: { name: "OpenRouter", icon: "openrouter.svg", color: "#b5a8ff" },
  antigravity: { name: "Antigravity", icon: "antigravity.svg", color: "#ee8db6" },
  opencode: { name: "OpenCode", icon: "opencode.svg", color: "#f2c464" },
  zai: { name: "Z.ai", icon: "zai.svg", color: "#67b3ff" },
  deepseek: { name: "DeepSeek", icon: "deepseek.svg", color: "#6585ff" },
  kimi: { name: "Kimi", icon: "kimi.svg", color: "#55b4d4" },
  minimax: { name: "MiniMax", icon: "minimax.svg", color: "#ef6f78" },
  mimo: { name: "MiMo", icon: "mimo.svg", color: "#ff9d57" },
  qoder: { name: "Qoder", icon: "qoder.svg", color: "#7eb6ff" },
  kiro: { name: "Kiro", icon: "kiro.svg", color: "#bd89ff" },
  volcengine: { name: "Volcengine", icon: "volcengine.svg", color: "#62a8ff" },
  ollama: { name: "Ollama", icon: "ollama.svg", color: "#c9cbd3" },
};

export function providerMeta(providerID) {
  return PROVIDER_META[providerID] || {
    name: providerID,
    icon: undefined,
    color: "var(--violet)",
  };
}

export function mergeProviders(local = [], remote = []) {
  const newest = new Map();
  for (const provider of [...remote, ...local]) {
    if (!provider?.providerID) continue;
    const previous = newest.get(provider.providerID);
    if (!previous || provider.capturedAt >= previous.capturedAt) {
      newest.set(provider.providerID, provider);
    }
  }
  const known = PROVIDER_ORDER.flatMap((id) => newest.has(id) ? [newest.get(id)] : []);
  const future = [...newest.values()]
    .filter((provider) => !PROVIDER_ORDER.includes(provider.providerID))
    .sort((left, right) => left.providerID.localeCompare(right.providerID));
  return [...known, ...future];
}
