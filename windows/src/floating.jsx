import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import appIcon from "../../site/assets/brand/appicon-mac.png";
import { providerMeta } from "./provider-meta.js";
import "./floating.css";

const previewState = {
  providers: [{ providerID: "codex", windows: [{ usedPercent: 63, windowMinutes: 300 }] }],
  notices: {},
};

const previewAPI = {
  getState: async () => previewState,
  togglePopupFromFloating: async () => true,
  onStateChanged: () => () => {},
};

const api = globalThis.tokenRemain ?? (import.meta.env.DEV ? previewAPI : undefined);

function tightestQuota(state) {
  return (state?.providers || []).flatMap((provider) => {
    const windows = (provider.windows || []).filter((window) => Number.isFinite(window.usedPercent));
    const window = windows.reduce((current, candidate) => (
      !current || (candidate.windowMinutes > 0 && candidate.windowMinutes < current.windowMinutes)
        ? candidate
        : current
    ), undefined);
    if (!window) return [];
    return [{
      id: provider.providerID,
      name: providerMeta(provider.providerID).name,
      remaining: Math.round(Math.min(100, Math.max(0, 100 - window.usedPercent))),
    }];
  }).sort((left, right) => left.remaining - right.remaining)[0];
}

function App() {
  const [state, setState] = useState();
  useEffect(() => {
    api?.getState().then(setState).catch(() => setState(previewState));
    return api?.onStateChanged?.(setState);
  }, []);
  const quota = tightestQuota(state);
  const attention = Boolean(state && (Object.keys(state.notices || {}).length || !quota));
  return (
    <div className="floating-shell" title="Drag the grip to move · right-click for more options">
      <span className="floating-grip" aria-hidden="true"><i /><i /><i /></span>
      <button
        className="floating-open"
        onClick={() => api?.togglePopupFromFloating?.()}
        aria-label={quota ? `Open Quick View. ${quota.name} has ${quota.remaining}% remaining.` : "Open TokenRemain Quick View"}
        title="Open Quick View"
      >
        <img src={appIcon} alt="" />
        <span>
          <strong>{quota ? `${quota.remaining}%` : "Quick View"}</strong>
          <small>{quota?.name || "TokenRemain"}</small>
        </span>
        {attention && <i className="floating-attention" aria-hidden="true" />}
      </button>
    </div>
  );
}

createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
