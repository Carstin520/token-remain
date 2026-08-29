import { buildTodayUsage, rankOfficialQuotaProviders, summaryWindow } from "./overview-model.js";
import { providerMeta } from "./provider-meta.js";

/// The floating shortcut is a 72×72 coin, so it can carry at most two legible
/// concentric tracks. Geometry is positional: index 0 is the outer ring, which
/// is also the only ring a single-provider machine draws.
export const FLOATING_RING_GEOMETRY = [
  { radius: 30.75, width: 9.5 },
  { radius: 17.75, width: 9.5 },
];

/// The watch component starts just after twelve o'clock so a rounded cap
/// remains legible without making an empty ring look non-zero.
const ARC_START = 0.012;

/// Only providers the user actually enabled may reach the widget. `providers`
/// is normally pre-filtered by the main process, but Direct Sync can carry a
/// snapshot for a provider this PC has since switched off, and a ghost ring in
/// an 80px window is indistinguishable from a decal.
export function enabledQuotaProviders(state) {
  const enabled = Array.isArray(state?.enabledProviders) ? new Set(state.enabledProviders) : undefined;
  return (state?.providers || []).filter((provider) => provider?.providerID
    && (!enabled || enabled.has(provider.providerID)));
}

/// The rings show the providers this machine actually leans on: today's local
/// usage ranks them first, and a machine with no usage recorded yet falls back
/// to the quota-only order. This is `rankOfficialQuotaProviders` — the same
/// selection the Dashboard's Official Quota block makes — narrowed to enabled
/// providers, so the widget and the Dashboard can never disagree.
export function rankFloatingProviders(state, now = Date.now()) {
  const providers = enabledQuotaProviders(state);
  return rankOfficialQuotaProviders(providers, buildTodayUsage(state?.dailyUsageHistory, now));
}

/// One ring per qualifying provider — never a placeholder, because a full
/// circle in a provider's colour for a provider that is not installed is the
/// exact "static decal" the redesign exists to remove.
export function floatingRings(state, now = Date.now()) {
  const byID = new Map(enabledQuotaProviders(state).map((provider) => [provider.providerID, provider]));
  const rings = rankFloatingProviders(state, now)
    .flatMap((providerID) => {
      const window = summaryWindow(byID.get(providerID), state?.summaryStrategy);
      if (!window) return [];
      const meta = providerMeta(providerID);
      return [{
        providerID,
        name: meta.name,
        color: meta.color,
        remaining: clamp(Math.round(100 - window.usedPercent), 0, 100),
        windowMinutes: window.windowMinutes,
      }];
    })
    .slice(0, FLOATING_RING_GEOMETRY.length)
    .map((ring, index) => ({ ...ring, ...FLOATING_RING_GEOMETRY[index] }));
  const lowest = rings.length ? Math.min(...rings.map((ring) => ring.remaining)) : undefined;
  return { rings, lowest };
}

/// Arc length is the provider's remaining percentage, so a 60%-remaining
/// provider draws 60% of the circle. Returned in stroke-dash units.
export function ringArc(remaining, radius) {
  const circumference = 2 * Math.PI * radius;
  const fraction = Number.isFinite(remaining) ? clamp(remaining / 100, 0, 1) : 0;
  return {
    circumference,
    dash: Math.max(0, fraction - ARC_START) * circumference,
    gap: circumference,
    offset: -ARC_START * circumference,
  };
}

export function floatingLabel(lowest) {
  return Number.isFinite(lowest) ? `${lowest}%` : "—";
}

/// "Claude 62%, Codex 38%" — only the providers actually drawn, so the button's
/// accessible name can never announce a provider this PC does not have.
export function floatingProviderSummary(rings = [], separator = ", ") {
  return rings.map((ring) => `${ring.name} ${ring.remaining}%`).join(separator);
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}
