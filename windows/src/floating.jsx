import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { activateLanguage, SYSTEM_LANGUAGE, tr } from "./i18n.js";
import { providerMeta } from "./provider-meta.js";
import "./floating.css";

const previewParameters = new URLSearchParams(globalThis.location?.search || "");
const previewState = {
  providers: [
    { providerID: "claude", windows: [{ usedPercent: 54, windowMinutes: 300 }] },
    { providerID: "codex", windows: [{ usedPercent: 37, windowMinutes: 300 }] },
  ],
  notices: {},
  languagePreference: previewParameters.get("lang") || SYSTEM_LANGUAGE,
  systemLocale: previewParameters.get("systemLocale") || globalThis.navigator?.language || "en",
};

const previewAPI = {
  getState: async () => previewState,
  togglePopupFromFloating: async () => true,
  onStateChanged: () => () => {},
  onPopoverVisibility: (listener) => {
    queueMicrotask(() => listener(false));
    return () => {};
  },
};

const api = globalThis.tokenRemain ?? (import.meta.env.DEV ? previewAPI : undefined);

function remainingForProvider(provider) {
  const windows = (provider?.windows || []).filter((window) => Number.isFinite(window.usedPercent));
  const shortest = windows.reduce((current, candidate) => {
    if (!current) return candidate;
    const currentDuration = current.windowMinutes > 0 ? current.windowMinutes : Number.POSITIVE_INFINITY;
    const candidateDuration = candidate.windowMinutes > 0 ? candidate.windowMinutes : Number.POSITIVE_INFINITY;
    return candidateDuration < currentDuration ? candidate : current;
  }, undefined);
  return shortest ? Math.round(Math.min(100, Math.max(0, 100 - shortest.usedPercent))) : undefined;
}

function ringValues(state) {
  const remaining = new Map((state?.providers || []).flatMap((provider) => {
    const value = remainingForProvider(provider);
    return value === undefined ? [] : [[provider.providerID, value]];
  }));
  const lowest = remaining.size ? Math.min(...remaining.values()) : undefined;
  return {
    lowest,
    claude: remaining.get("claude") ?? lowest ?? 0,
    codex: remaining.get("codex") ?? lowest ?? 0,
  };
}

function ActivityRing({ remaining, radius, width, color }) {
  const fraction = Math.min(1, Math.max(0, remaining / 100));
  const circumference = 2 * Math.PI * radius;
  // The watch component starts just after twelve o'clock so a rounded cap
  // remains legible without making an empty ring look non-zero.
  const start = 0.012;
  const arc = Math.max(0, fraction - start);
  return (
    <g>
      <circle className="activity-track" cx="36" cy="36" r={radius} stroke={color} strokeWidth={width} />
      <circle
        className="activity-value"
        cx="36"
        cy="36"
        r={radius}
        stroke={color}
        strokeWidth={width}
        strokeDasharray={`${arc * circumference} ${circumference}`}
        strokeDashoffset={-start * circumference}
      />
    </g>
  );
}

function ActivityRings({ claude, codex, label }) {
  return (
    <svg className="activity-rings" viewBox="0 0 72 72" aria-hidden="true">
      <ActivityRing remaining={claude} radius={30.75} width={9.5} color={providerMeta("claude").color} />
      <ActivityRing remaining={codex} radius={17.75} width={9.5} color={providerMeta("codex").color} />
      <text className="activity-label" x="36" y="36" dominantBaseline="central" textAnchor="middle">{label}</text>
    </svg>
  );
}

function App() {
  const [state, setState] = useState();
  const [popupOpen, setPopupOpen] = useState(false);
  activateLanguage(state?.languagePreference || SYSTEM_LANGUAGE, state?.systemLocale);
  useEffect(() => {
    api?.getState().then(setState).catch(() => setState(previewState));
    const offState = api?.onStateChanged?.(setState);
    const offVisibility = api?.onPopoverVisibility?.(setPopupOpen);
    return () => { offState?.(); offVisibility?.(); };
  }, []);
  const rings = useMemo(() => ringValues(state), [state]);
  const label = rings.lowest === undefined ? "—" : `${rings.lowest}%`;
  const detail = rings.lowest === undefined
    ? tr("Quota is not available yet")
    : tr("Lowest remaining %1$@. Claude %2$@, Codex %3$@.", [`${rings.lowest}%`, `${rings.claude}%`, `${rings.codex}%`]);

  return (
    <div className={`floating-shell ${popupOpen ? "is-open" : ""}`} title={tr("Drag the top grip to move · right-click for more options")}>
      <span className="floating-drag-handle" aria-hidden="true"><i /><i /><i /></span>
      <button
        className="floating-open"
        onClick={() => api?.togglePopupFromFloating?.()}
        aria-label={`${tr(popupOpen ? "Close" : "Open")} TokenRemain ${tr("Quick View")}. ${detail}`}
        aria-expanded={popupOpen}
        title={`${tr(popupOpen ? "Close" : "Open")} ${tr("Quick View")}`}
      >
        <ActivityRings claude={rings.claude} codex={rings.codex} label={label} />
      </button>
    </div>
  );
}

createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
