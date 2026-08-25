import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { GlassCircle } from "./glass/GlassSurface.jsx";
import { activateLanguage, SYSTEM_LANGUAGE, tr, trKey } from "./i18n.js";
import {
  FLOATING_RING_GEOMETRY,
  floatingLabel,
  floatingProviderSummary,
  floatingRings,
  ringArc,
} from "./floating-model.js";
import "./floating.css";

const previewParameters = new URLSearchParams(globalThis.location?.search || "");

/// DEV-only fixtures for /floating.html?preview=…. They exist to make the four
/// states the redesign has to survive reachable by eye without Electron: two
/// rings, one ring, no ring at all, and two partial arcs in provider colours
/// that are neither Claude's nor Codex's, which is what proves the arcs and the
/// hues are read from the state rather than painted in.
const PREVIEW_FIXTURES = {
  two: { claude: { usedPercent: 54, tokens: 820_000 }, codex: { usedPercent: 37, tokens: 410_000 } },
  one: { codex: { usedPercent: 37, tokens: 410_000 } },
  zero: {},
  partial: { cursor: { usedPercent: 38, tokens: 640_000 }, copilot: { usedPercent: 62, tokens: 220_000 } },
};

function buildPreviewState(name = "two", now = Date.now()) {
  const fixture = PREVIEW_FIXTURES[name] || PREVIEW_FIXTURES.two;
  const entries = Object.entries(fixture);
  const day = new Date(now).toISOString().slice(0, 10);
  return {
    reducedMotion: false,
    summaryStrategy: "shortestWindow",
    enabledProviders: entries.map(([providerID]) => providerID),
    providers: entries.map(([providerID, value]) => ({
      providerID,
      windows: [{ usedPercent: value.usedPercent, windowMinutes: 300, resetsAt: now + 90 * 60_000 }],
    })),
    dailyUsageHistory: {
      sourceDay: day,
      capturedAt: now,
      days: [{ day, agents: entries.map(([providerID, value]) => ({ id: providerID, tokens: value.tokens, cost: value.tokens / 1_000_000 })) }],
    },
    notices: {},
    languagePreference: previewParameters.get("lang") || SYSTEM_LANGUAGE,
    systemLocale: previewParameters.get("systemLocale") || globalThis.navigator?.language || "en",
  };
}

const previewState = buildPreviewState(previewParameters.get("preview") || "two");

const previewAPI = {
  getState: async () => previewState,
  togglePopupFromFloating: async () => true,
  startFloatingDrag: () => {},
  moveFloatingWidget: () => {},
  endFloatingDrag: () => {},
  onStateChanged: () => () => {},
  onPopoverVisibility: (listener) => {
    queueMicrotask(() => listener(false));
    return () => {};
  },
};

const api = globalThis.tokenRemain ?? (import.meta.env.DEV ? previewAPI : undefined);

function ActivityRing({ ring }) {
  const arc = ringArc(ring.remaining, ring.radius);
  return (
    <g>
      <circle className="activity-track" cx="36" cy="36" r={ring.radius} stroke={ring.color} strokeWidth={ring.width} />
      <circle
        className="activity-value"
        cx="36"
        cy="36"
        r={ring.radius}
        stroke={ring.color}
        strokeWidth={ring.width}
        strokeDasharray={`${arc.dash} ${arc.gap}`}
        strokeDashoffset={arc.offset}
      />
    </g>
  );
}

/// One ring per provider actually being tracked — two, one, or none. The empty
/// state keeps the outer track alone so the coin still reads as a meter that is
/// waiting for data rather than a meter reporting zero.
function ActivityRings({ rings, label }) {
  return (
    <svg className="activity-rings" viewBox="0 0 72 72" aria-hidden="true">
      {rings.length ? rings.map((ring) => <ActivityRing key={ring.providerID} ring={ring} />) : (
        <circle
          className="activity-track"
          cx="36"
          cy="36"
          r={FLOATING_RING_GEOMETRY[0].radius}
          stroke="currentColor"
          strokeWidth={FLOATING_RING_GEOMETRY[0].width}
        />
      )}
      <text className="activity-label" x="36" y="36" dominantBaseline="central" textAnchor="middle">{label}</text>
    </svg>
  );
}

function App() {
  const [state, setState] = useState();
  const [popupOpen, setPopupOpen] = useState(false);
  const dragRef = useRef();
  const dragFrameRef = useRef(0);
  activateLanguage(state?.languagePreference || SYSTEM_LANGUAGE, state?.systemLocale);
  useEffect(() => {
    api?.getState().then(setState).catch(() => setState(previewState));
    const offState = api?.onStateChanged?.(setState);
    const offVisibility = api?.onPopoverVisibility?.(setPopupOpen);
    return () => { offState?.(); offVisibility?.(); };
  }, []);
  useLayoutEffect(() => {
    document.documentElement.dataset.reducedMotion = state?.reducedMotion ? "true" : "false";
  }, [state?.reducedMotion]);
  useEffect(() => () => {
    cancelAnimationFrame(dragFrameRef.current);
    if (dragRef.current) api?.endFloatingDrag?.();
  }, []);

  const flushDragMove = () => {
    dragFrameRef.current = 0;
    const drag = dragRef.current;
    if (drag) api?.moveFloatingWidget?.({ dx: drag.dx, dy: drag.dy });
  };
  const onDragPointerDown = (event) => {
    if (!event.isPrimary || event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    dragRef.current = {
      pointerId: event.pointerId,
      screenX: event.screenX,
      screenY: event.screenY,
      dx: 0,
      dy: 0,
    };
    api?.startFloatingDrag?.();
  };
  const onDragPointerMove = (event) => {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    drag.dx = event.screenX - drag.screenX;
    drag.dy = event.screenY - drag.screenY;
    if (!dragFrameRef.current) dragFrameRef.current = requestAnimationFrame(flushDragMove);
  };
  const onDragPointerEnd = (event) => {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    if (dragFrameRef.current) {
      cancelAnimationFrame(dragFrameRef.current);
      flushDragMove();
    }
    dragRef.current = undefined;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
    api?.endFloatingDrag?.();
  };
  const { rings, lowest } = useMemo(() => floatingRings(state), [state]);
  const label = floatingLabel(lowest);
  // Only the providers on screen are announced, and their real values: the old
  // fixed "Claude …, Codex …" name read out a Claude quota on machines that
  // have never installed Claude.
  const detail = rings.length
    ? tr("Lowest remaining %1$@. %2$@.", [label, floatingProviderSummary(rings, trKey("floating.provider_separator", [], ", "))])
    : tr("Quota is not available yet");

  return (
    <div className={`floating-shell ${popupOpen ? "is-open" : ""}`} title={tr("Drag the top grip to move · right-click for more options")}>
      <span
        className="floating-drag-handle"
        aria-hidden="true"
        onPointerDown={onDragPointerDown}
        onPointerMove={onDragPointerMove}
        onPointerUp={onDragPointerEnd}
        onPointerCancel={onDragPointerEnd}
      ><i /><i /><i /></span>
      {/* The window is always on screen while it exists, so the glass never has
          to be unmounted and the surface needs no visibility channel.

          `backdrop="none"` is not a preference here: this is an 80×80
          `transparent: true` window with no backgroundMaterial, so there is
          never a system backdrop to refract. A backdrop-filter anywhere in the
          document makes Chromium paint the whole backdrop root opaque, which
          showed up on Windows 11 as a black square around the button. */}
      <GlassCircle
        className="floating-open"
        backdrop="none"
        onClick={() => api?.togglePopupFromFloating?.()}
        aria-label={`${tr(popupOpen ? "Close" : "Open")} TokenRemain ${tr("Quick View")}. ${detail}`}
        aria-expanded={popupOpen}
        title={`${tr(popupOpen ? "Close" : "Open")} ${tr("Quick View")}`}
      >
        <ActivityRings rings={rings} label={label} />
      </GlassCircle>
    </div>
  );
}

createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
