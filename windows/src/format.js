// Formatting ported from the macOS app's UsageFormatting + English strings so
// both platforms describe quotas, resets, and freshness with identical rules.

export function formatPercent(value) {
  if (!Number.isFinite(value)) return "—";
  return Math.round(value) === value ? `${value}%` : `${value.toFixed(1)}%`;
}

export function formatMoney(value) {
  return `$${value.toFixed(2)}`;
}

export function compactUSD(value) {
  if (value >= 1_000_000) return `$${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `$${(value / 1_000).toFixed(1)}K`;
  return `$${value.toFixed(2)}`;
}

export function compactNumber(value) {
  if (!Number.isFinite(value)) return "—";
  const number = Math.abs(value);
  if (number >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(2)}B`;
  if (number >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M`;
  if (number >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return String(Math.round(value));
}

export function formatBalance(balance) {
  if (balance.currencyCode === "USD") return compactUSD(balance.amount);
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency: balance.currencyCode, maximumFractionDigits: 2 }).format(balance.amount);
  } catch {
    return `${balance.amount.toFixed(2)} ${balance.currencyCode}`;
  }
}

/// "X d Y hr" / "X hr Y min" / "X min" / "Less than 1 min" — Swift durationUntil.
export function durationUntil(target, now = Date.now()) {
  const remaining = Math.max(0, Math.floor((target - now) / 1_000));
  const days = Math.floor(remaining / 86_400);
  const hours = Math.floor((remaining % 86_400) / 3_600);
  const minutes = Math.floor((remaining % 3_600) / 60);
  if (days > 0) return `${days} d ${hours} hr`;
  if (hours > 0) return `${hours} hr ${minutes} min`;
  if (minutes > 0) return `${minutes} min`;
  return "Less than 1 min";
}

/// Reset label matching the Mac: countdown inside a day, weekday inside a week,
/// absolute date beyond, "Resetting" once passed. Missing dates are the
/// caller's "Waiting for the official reset time".
export function resetDescription(resetsAt, now = Date.now()) {
  if (!Number.isFinite(resetsAt)) return "Waiting for the official reset time";
  const interval = resetsAt - now;
  if (interval <= 0) return "Resetting";
  if (interval < 86_400_000) return `Resets in ${durationUntil(resetsAt, now)}`;
  const style = interval < 7 * 86_400_000
    ? { weekday: "short", hour: "2-digit", minute: "2-digit" }
    : { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" };
  return `Resets ${new Intl.DateTimeFormat(undefined, style).format(new Date(resetsAt))}`;
}

/// "Updated just now" → minutes → hours → days, same buckets as the Mac card
/// footer; `isStaleCapture` mirrors its 10-minute warning threshold.
export function freshnessDescription(capturedAt, now = Date.now()) {
  const age = Math.max(0, now - capturedAt);
  if (age < 60_000) return "Updated just now";
  if (age < 3_600_000) return `Updated ${Math.floor(age / 60_000)} min ago`;
  if (age < 86_400_000) return `Updated ${Math.floor(age / 3_600_000)} hr ago`;
  return `Updated ${Math.floor(age / 86_400_000)} d ago`;
}

export function isStaleCapture(capturedAt, now = Date.now()) {
  return now - capturedAt >= 600_000;
}

/// "5 hr" / "7 d" / "45 min"; the 0 sentinel is a non-rolling total balance.
export function windowName(minutes) {
  if (!minutes || minutes <= 0) return "Total";
  if (minutes % 1_440 === 0) return `${minutes / 1_440} d`;
  if (minutes % 60 === 0) return `${minutes / 60} hr`;
  return `${minutes} min`;
}

export function windowTitle(minutes) {
  return `${windowName(minutes)} window`;
}

export function formatClock(value) {
  return new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" }).format(new Date(value));
}

export function formatClockSeconds(value) {
  return new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit" }).format(new Date(value));
}

export function formatDayLabel(value) {
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(new Date(`${value}T00:00:00Z`));
}

/// Feed-post age in the Mac's relative style: "6 hr, 34 min" / "2 d, 3 hr".
export function relativeAge(value, now = Date.now()) {
  const minutes = Math.max(0, Math.floor((now - value) / 60_000));
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} hr, ${minutes % 60} min`;
  return `${Math.floor(hours / 24)} d, ${hours % 24} hr`;
}
