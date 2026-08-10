// Formatting ported from the macOS app's UsageFormatting + English strings so
// both platforms describe quotas, resets, and freshness with identical rules.
import { getActiveLanguage, trKey } from "./i18n.js";

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
    return new Intl.NumberFormat(getActiveLanguage(), { style: "currency", currency: balance.currencyCode, maximumFractionDigits: 2 }).format(balance.amount);
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
  if (days > 0) return trKey("duration.days_hours", [days, hours]);
  if (hours > 0) return trKey("duration.hours_minutes", [hours, minutes]);
  if (minutes > 0) return trKey("duration.minutes", [minutes]);
  return trKey("duration.less_than_minute");
}

/// Reset label matching the Mac: countdown inside a day, weekday inside a week,
/// absolute date beyond, "Resetting" once passed. Missing dates are the
/// caller's "Waiting for the official reset time".
export function resetDescription(resetsAt, now = Date.now()) {
  if (!Number.isFinite(resetsAt)) return trKey("quota.reset_pending");
  const interval = resetsAt - now;
  if (interval <= 0) return trKey("reset.in_progress");
  if (interval < 86_400_000) return trKey("reset.countdown", [durationUntil(resetsAt, now)]);
  const style = interval < 7 * 86_400_000
    ? { weekday: "short", hour: "2-digit", minute: "2-digit" }
    : { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" };
  return trKey("reset.on", [new Intl.DateTimeFormat(getActiveLanguage(), style).format(new Date(resetsAt))]);
}

/// "Updated just now" → minutes → hours → days, same buckets as the Mac card
/// footer; `isStaleCapture` mirrors its 10-minute warning threshold.
export function freshnessDescription(capturedAt, now = Date.now()) {
  const age = Math.max(0, now - capturedAt);
  if (age < 60_000) return trKey("freshness.just_now");
  if (age < 3_600_000) return trKey("freshness.minutes", [Math.floor(age / 60_000)]);
  if (age < 86_400_000) return trKey("freshness.hours", [Math.floor(age / 3_600_000)]);
  return trKey("freshness.days", [Math.floor(age / 86_400_000)]);
}

export function isStaleCapture(capturedAt, now = Date.now()) {
  return now - capturedAt >= 600_000;
}

/// "5 hr" / "7 d" / "45 min"; the 0 sentinel is a non-rolling total balance.
export function windowName(minutes) {
  if (!minutes || minutes <= 0) return trKey("duration.total");
  if (minutes % 1_440 === 0) return trKey("duration.days", [minutes / 1_440]);
  if (minutes % 60 === 0) return trKey("duration.hours", [minutes / 60]);
  return trKey("duration.minutes", [minutes]);
}

export function windowTitle(minutes) {
  return trKey("quota.window", [windowName(minutes)]);
}

export function formatClock(value) {
  return new Intl.DateTimeFormat(getActiveLanguage(), { hour: "2-digit", minute: "2-digit" }).format(new Date(value));
}

export function formatClockSeconds(value) {
  return new Intl.DateTimeFormat(getActiveLanguage(), { hour: "2-digit", minute: "2-digit", second: "2-digit" }).format(new Date(value));
}

export function formatDayLabel(value) {
  return new Intl.DateTimeFormat(getActiveLanguage(), { month: "short", day: "numeric" }).format(new Date(`${value}T00:00:00Z`));
}

/// Feed-post age in the Mac's relative style: "6 hr, 34 min" / "2 d, 3 hr".
export function relativeAge(value, now = Date.now()) {
  const minutes = Math.max(0, Math.floor((now - value) / 60_000));
  if (minutes < 1) return trKey("time.now", [], "now");
  if (minutes < 60) return trKey("duration.minutes", [minutes]);
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return trKey("feed.age.hours_minutes", [hours, minutes % 60]);
  return trKey("feed.age.days_hours", [Math.floor(hours / 24), hours % 24]);
}
