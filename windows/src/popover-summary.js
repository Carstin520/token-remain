// Plain-text Copy Summary builders for the popover widgets.
//
// Every builder reads only the popover's presentation model — the same
// already-formatted strings the widget renders — so the clipboard can never
// pick up credentials, raw snapshots, or telemetry the user has not seen.

/// The provider card: one line per quota window — account windows first, then
/// scoped windows, each exactly once — plus the freshness read and any notice,
/// exactly as the expanded card shows them.
export function providerSummaryText(card) {
  const lines = [`${card.name} — official quota`];
  const allWindows = [...(card.windows || []), ...(card.scopedWindows || [])];
  const windows = allWindows.length
    ? allWindows
    : [{ title: card.windowTitle, remainingText: card.remainingText, resetText: card.resetText }];
  for (const window of windows) {
    lines.push(`${window.title}: ${window.remainingText} · ${window.resetText}${window.aheadOfPace ? " · ahead of pace" : ""}`);
  }
  if (card.capturedText) lines.push(card.capturedText);
  if (card.notice) lines.push(`Notice: ${card.notice}`);
  return lines.join("\n");
}

/// The local-usage digest, or the honest reason it is empty.
export function usageSummaryText(usage, empty) {
  if (!usage) return `Today's Local Usage — ${empty?.title || "No data"}`;
  return [
    "Today's Local Usage",
    `Today: ${usage.today.label}`,
    `Yesterday: ${usage.yesterday.label}`,
    `Last 30 Days: ${usage.last30Days.label}`,
  ].join("\n");
}

/// The feed's visible stories with their public URLs, or its current status.
export function feedSummaryText(feed) {
  if (!feed?.items?.length) {
    return `AI Feed — ${feed?.error ? "temporarily unavailable" : "no important updates right now"}`;
  }
  return [
    "AI Feed — important updates",
    ...feed.items.map((item) => `${item.source} · ${item.age}: ${item.title} (${item.url})`),
  ].join("\n");
}
