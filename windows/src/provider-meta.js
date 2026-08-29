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

// Identity hues mirror DashboardTheme.accent(for:) on the Mac: muted,
// contrast-matched expressions; semantic red stays reserved for critical quota.
const PROVIDER_META = {
  claude: { name: "Claude", icon: "claude-code.svg", color: "#BF8471" },
  codex: { name: "Codex", icon: "codex.svg", color: "#6687C5" },
  cursor: { name: "Cursor", icon: "cursor.svg", color: "#9684CD" },
  copilot: { name: "Copilot", icon: "copilot.svg", color: "#64ABB4" },
  devin: { name: "Devin", icon: "devin.svg", color: "#5AAA9F" },
  windsurf: { name: "Windsurf", icon: "windsurf.png", color: "#70AFA6" },
  grok: { name: "Grok", icon: "grok.svg", color: "#C1AD5C" },
  openrouter: { name: "OpenRouter", icon: "openrouter.svg", color: "#94A3B8" },
  antigravity: { name: "Antigravity", icon: "antigravity.svg", color: "#7499C3" },
  opencode: { name: "OpenCode", icon: "opencode.svg", color: "#63AB91" },
  zai: { name: "Z.ai", icon: "zai.svg", color: "#9CB766" },
  deepseek: { name: "DeepSeek", icon: "deepseek.svg", color: "#7382CA" },
  kimi: { name: "Kimi", icon: "kimi.svg", color: "#86B5C6" },
  minimax: { name: "MiniMax", icon: "minimax.svg", color: "#C06E7E" },
  mimo: { name: "MiMo", icon: "mimo.svg", color: "#C689A9" },
  qoder: { name: "Qoder", icon: "qoder.svg", color: "#A07FB0" },
  kiro: { name: "Kiro", icon: "kiro.svg", color: "#A292C7" },
  volcengine: { name: "Volcengine", icon: "volcengine.svg", color: "#6BA3C4" },
  ollama: { name: "Ollama", icon: "ollama.svg", color: "#CBD5E1" },
  gemini: { name: "Gemini", icon: undefined, color: "#6CA0C8" },
  amp: { name: "Amp", icon: undefined, color: "#D29B63" },
  droid: { name: "Droid", icon: undefined, color: "#7FB88B" },
  codebuff: { name: "Codebuff", icon: undefined, color: "#B28AC4" },
  hermes: { name: "Hermes", icon: undefined, color: "#C39A6B" },
  goose: { name: "Goose", icon: undefined, color: "#9EAEBD" },
  openclaw: { name: "OpenClaw", icon: undefined, color: "#C47B74" },
  kilo: { name: "Kilo", icon: undefined, color: "#78A99B" },
  qwen: { name: "Qwen", icon: undefined, color: "#7D8FD0" },
  pi: { name: "Pi", icon: undefined, color: "#B889A6" },
};

export function providerMeta(providerID) {
  return PROVIDER_META[providerID] || {
    name: String(providerID || "Unknown").replace(/(^|[-_.])([a-z])/g, (_, separator, letter) => `${separator ? " " : ""}${letter.toUpperCase()}`),
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

/// Device ownership beats capture time. Direct Sync is a fallback for a
/// provider that this PC cannot currently supply; it must never replace a
/// Windows-local snapshot merely because the Mac refreshed a few seconds later.
export function mergeLocalFirstProviders(local = [], remote = []) {
  const localIDs = new Set(local.filter((provider) => provider?.providerID).map((provider) => provider.providerID));
  return mergeProviders(local, remote.filter((provider) => !localIDs.has(provider?.providerID)));
}
