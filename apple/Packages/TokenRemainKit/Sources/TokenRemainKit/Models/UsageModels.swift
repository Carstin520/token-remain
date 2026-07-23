import Foundation

/// Ported unchanged in shape from `Sources/UsageDock/Models/UsageModels.swift`.
/// Duplicated rather than imported: the macOS sources are outside this subtree
/// and must not be touched.
public struct QuotaWindow: Sendable, Codable, Equatable {
    public let usedPercent: Double
    public let windowMinutes: Int
    /// Claude can report a freshly-reset window before it knows the next reset time.
    /// Keep that official "unknown" state instead of carrying forward an expired date.
    public let resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public struct ProviderQuota: Sendable, Codable, Equatable {
    public let provider: Provider
    public let primary: QuotaWindow
    public let secondary: QuotaWindow?
    public let planName: String?
    public let capturedAt: Date

    public enum Provider: String, Sendable, Codable, CaseIterable {
        case claude = "Claude Code"
        case codex = "Codex"
        case cursor = "Cursor"
        case grok = "Grok"
        case zai = "Z.ai"
        case copilot = "Copilot"
        case devin = "Devin"
        case openrouter = "OpenRouter"
        case antigravity = "Antigravity"
        case opencode = "OpenCode"
        case deepseek = "DeepSeek"
        case kimi = "Kimi"
        case minimax = "MiniMax"
        case mimo = "MiMo Code"
        case qoder = "Qoder"
        case kiro = "Kiro"
        case volcengine = "Volcengine"
        case ollama = "Ollama"

        /// Short name used across compact surfaces.
        public var shortName: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .cursor: return "Cursor"
            case .grok: return "Grok"
            case .zai: return "Z.ai"
            case .copilot: return "Copilot"
            case .devin: return "Devin"
            case .openrouter: return "OpenRouter"
            case .antigravity: return "Antigravity"
            case .opencode: return "OpenCode"
            case .deepseek: return "DeepSeek"
            case .kimi: return "Kimi"
            case .minimax: return "MiniMax"
            case .mimo: return "MiMo"
            case .qoder: return "Qoder"
            case .kiro: return "Kiro"
            case .volcengine: return "Volcengine"
            case .ollama: return "Ollama"
            }
        }

        /// Stable CloudKit wire identifier. Never derive this from the display
        /// name because UI copy and legacy cache values may change independently.
        public var syncID: String {
            switch self {
            case .claude: return "claude"
            case .codex: return "codex"
            case .cursor: return "cursor"
            case .grok: return "grok"
            case .zai: return "zai"
            case .copilot: return "copilot"
            case .devin: return "devin"
            case .openrouter: return "openrouter"
            case .antigravity: return "antigravity"
            case .opencode: return "opencode"
            case .deepseek: return "deepseek"
            case .kimi: return "kimi"
            case .minimax: return "minimax"
            case .mimo: return "mimo"
            case .qoder: return "qoder"
            case .kiro: return "kiro"
            case .volcengine: return "volcengine"
            case .ollama: return "ollama"
            }
        }

        public init?(syncID: String) {
            guard let value = Self.allCases.first(where: { $0.syncID == syncID }) else {
                return nil
            }
            self = value
        }

        /// Compact fallback mark for providers without bundled artwork.
        public var systemImage: String {
            switch self {
            case .claude: return "sparkles"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            case .cursor: return "cube.fill"
            case .grok: return "xmark.circle.fill"
            case .zai: return "z.circle.fill"
            case .copilot: return "person.2.wave.2.fill"
            case .devin: return "hammer.fill"
            case .openrouter: return "arrow.triangle.branch"
            case .antigravity: return "a.circle.fill"
            case .opencode: return "terminal.fill"
            case .deepseek: return "water.waves"
            case .kimi: return "moon.stars.fill"
            case .minimax: return "square.stack.3d.up.fill"
            case .mimo: return "bubble.left.fill"
            case .qoder: return "q.circle.fill"
            case .kiro: return "k.circle.fill"
            case .volcengine: return "flame.fill"
            case .ollama: return "network"
            }
        }
    }

    public init(
        provider: Provider,
        primary: QuotaWindow,
        secondary: QuotaWindow?,
        planName: String?,
        capturedAt: Date
    ) {
        self.provider = provider
        self.primary = primary
        self.secondary = secondary
        self.planName = planName
        self.capturedAt = capturedAt
    }
}

/// Demo-only per-agent token split. Never populated in `.none` origin.
public struct AgentTokens: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let tokens: Int64
    public let estimatedCost: Double

    public init(id: String, tokens: Int64, estimatedCost: Double) {
        self.id = id
        self.tokens = tokens
        self.estimatedCost = estimatedCost
    }
}
