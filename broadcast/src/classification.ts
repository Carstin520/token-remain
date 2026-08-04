import type { FeedPriority } from "./types";

const usageLimitTerms = [
  "context window",
  "usage limit",
  "rate limit",
  "quota",
  "message limit",
  "compute limit",
  "weekly limit",
  "hourly limit",
  "token limit",
  "token budget",
  "paid user",
  "all plans",
  "reset bank",
  "banked reset",
  "额度",
  "配额",
  "速率限制",
  "上下文窗口",
] as const;

const limitChangeTerms = [
  "reset",
  "refill",
  "refresh",
  "renew",
  "rolling window",
  "increase",
  "decrease",
  "restore",
  "back to 100%",
  "on the house",
  "double",
  "2x",
  "unlimited",
  "重置",
  "恢复",
  "刷新",
  "提升",
  "下调",
  "翻倍",
] as const;

const releaseEventTerms = [
  "introducing",
  "we're launching",
  "we are launching",
  "now available",
  "rolling out",
  "we shipped",
  "we're announcing",
  "we are announcing",
  "announcing our",
  "general availability",
  "public beta",
  "now live",
  "breaking change",
  "deprecat",
  "sunset",
  "pricing update",
  "price change",
  "price reduction",
  "price cut",
  "outage",
  "incident",
  "degraded",
  "back online",
  "resolved",
  "service restored",
  "推出",
  "发布",
  "上线",
  "正式可用",
  "公开测试",
  "重大更新",
  "弃用",
  "停止支持",
  "价格调整",
  "降价",
  "故障",
  "中断",
  "服务恢复",
] as const;

const aiProductTerms = [
  "model",
  "api",
  "claude",
  "gpt",
  "chatgpt",
  "openai",
  "anthropic",
  "codex",
  "grok",
  "xai",
  "agent",
  "context",
  "token",
  "模型",
  "接口",
  "智能体",
  "上下文",
  "额度",
] as const;

export function classify(text: string): FeedPriority {
  const normalized = text.toLocaleLowerCase();
  if (
    containsAny(normalized, usageLimitTerms)
    && containsAny(normalized, limitChangeTerms)
  ) {
    return "token_reset";
  }
  if (
    containsAny(normalized, releaseEventTerms)
    && containsAny(normalized, aiProductTerms)
  ) {
    return "major_update";
  }
  return "normal";
}

function containsAny(value: string, candidates: readonly string[]): boolean {
  return candidates.some((candidate) => value.includes(candidate));
}
