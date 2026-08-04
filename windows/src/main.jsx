import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import appIcon from "../../site/assets/brand/appicon-mac.png";
import claudeIcon from "../../site/assets/providers/claude-code.svg";
import codexIcon from "../../site/assets/providers/codex.svg";
import { buildOverviewSummary } from "./overview-model.js";
import "./styles.css";

const PROVIDERS = {
  claude: { name: "Claude", icon: claudeIcon, color: "var(--claude)" },
  codex: { name: "Codex", icon: codexIcon, color: "var(--codex)" },
};
const SECTIONS = {
  overview: { title: "Overview", subtitle: "Quota risk, official limits, and encrypted sync" },
  limits: { title: "Limits", subtitle: "Every active official quota window" },
  devices: { title: "Devices", subtitle: "Direct, encrypted sync on your local network" },
  settings: { title: "Settings", subtitle: "Windows collection and privacy" },
};
const api = window.tokenRemain ?? (import.meta.env.DEV ? createPreviewAPI() : undefined);

function App() {
  const [state, setState] = useState();
  const [section, setSection] = useState("overview");
  const [error, setError] = useState();

  useEffect(() => {
    api.getState().then(setState).catch((reason) => setError(reason.message));
    return api.onStateChanged(setState);
  }, []);

  async function action(operation) {
    setError(undefined);
    try { setState(await operation()); }
    catch (reason) { setError(reason.message); }
  }

  if (!state) return <div className="loading">Loading TokenRemain…</div>;
  return (
    <div className="app-shell">
      <Sidebar section={section} onSelect={setSection} />
      <main className="main-content">
        <Header state={state} section={section} onRefresh={() => action(api.refresh)} />
        {error && <div className="error-banner">{error}</div>}
        {section === "overview" && <Overview state={state} onSelect={setSection} />}
        {section === "limits" && <Limits state={state} />}
        {section === "devices" && <Devices state={state} action={action} />}
        {section === "settings" && <Settings state={state} />}
      </main>
    </div>
  );
}

function Sidebar({ section, onSelect }) {
  const items = [
    ["overview", "Overview", GridIcon],
    ["limits", "Limits", GaugeIcon],
    ["devices", "Devices", DevicesIcon],
    ["settings", "Settings", SettingsIcon],
  ];
  return (
    <aside className="sidebar">
      <div className="brand"><img src={appIcon} alt="" /><span>TokenRemain</span></div>
      <div className="nav-label">MONITOR</div>
      <nav>
        {items.slice(0, 3).map(([id, name, Icon]) => (
          <button key={id} className={section === id ? "selected" : ""} aria-current={section === id ? "page" : undefined} onClick={() => onSelect(id)}><Icon />{name}</button>
        ))}
      </nav>
      <div className="nav-label system-label">SYSTEM</div>
      <nav>
        {items.slice(3).map(([id, name, Icon]) => (
          <button key={id} className={section === id ? "selected" : ""} aria-current={section === id ? "page" : undefined} onClick={() => onSelect(id)}><Icon />{name}</button>
        ))}
      </nav>
      <div className="privacy-status"><span className="status-dot" />Credentials stay on this PC</div>
    </aside>
  );
}

function Header({ state, section, onRefresh }) {
  const meta = SECTIONS[section];
  return (
    <header>
      <div><h1>{meta.title}</h1><p>{meta.subtitle}</p></div>
      <div className="header-actions">
        <span>{state.lastUpdatedAt ? `Updated ${formatTime(state.lastUpdatedAt)}` : "Waiting for local data"}</span>
        <button className="refresh" onClick={onRefresh} disabled={state.isRefreshing}><RefreshIcon />{state.isRefreshing ? "Refreshing…" : "Refresh"}</button>
      </div>
    </header>
  );
}

function Overview({ state, onSelect }) {
  const summary = buildOverviewSummary(state.providers);
  const nextResetMeta = summary.nextReset ? PROVIDERS[summary.nextReset.providerID] : undefined;
  const syncPresentation = syncSummary(state.sync);
  const trackedProviders = state.providers
    .filter((provider) => provider.windows?.length)
    .map((provider) => PROVIDERS[provider.providerID]?.name)
    .filter(Boolean)
    .join(" · ");
  return (
    <section className="content-section overview-section">
      <div className="overview-summary">
        <MetricCard
          label="Lowest remaining quota"
          value={summary.tightest ? formatPercent(summary.tightest.remaining) : "—"}
          detail={summary.risk ? `${summary.risk} risk` : "Waiting for quota"}
          tone={summary.risk || "muted"}
        />
        <MetricCard
          compact
          label="Next reset"
          value={summary.nextReset ? formatReset(summary.nextReset.resetsAt) : "—"}
          detail={nextResetMeta?.name || "No reset scheduled"}
          tone="violet"
        />
        <MetricCard
          label="Tracked providers"
          value={String(summary.trackedCount)}
          detail={trackedProviders || "Waiting for quota"}
        />
        <MetricCard
          compact
          label="Sync status"
          value={syncPresentation.value}
          detail={syncPresentation.detail}
          tone={syncPresentation.tone}
        />
      </div>
      <div className="overview-panels">
        <OfficialQuota state={state} risk={summary.risk} />
        <DirectSyncPanel state={state} onManage={() => onSelect("devices")} />
      </div>
    </section>
  );
}

function Limits({ state }) {
  return (
    <section className="content-section">
      <div className="quota-grid">
        {["claude", "codex"].map((id) => <ProviderCard detailed key={id} provider={state.providers.find((item) => item.providerID === id)} notice={state.notices[id]} id={id} />)}
      </div>
    </section>
  );
}

function MetricCard({ compact = false, icon, label, value, detail, tone }) {
  return (
    <article className={`metric-card ${compact ? "compact-value" : ""} ${tone ? `tone-${tone}` : ""}`}>
      <span className="metric-label">{label}</span>
      <div className="metric-value-row">
        {icon && <span className="metric-icon">{icon}</span>}
        <strong>{value}</strong>
      </div>
      <span className="metric-detail">{detail}</span>
    </article>
  );
}

function OfficialQuota({ state, risk }) {
  const fresh = state.lastUpdatedAt && Date.now() - state.lastUpdatedAt < 120_000;
  return (
    <section className="official-quota">
      <div className="panel-heading panel-heading-row">
        <div><h2>Official Quota</h2><p>Tightest windows from your active providers</p></div>
        {fresh && <span className="badge badge-live">LIVE</span>}
      </div>
      <div className="compact-quota-list">
        {["claude", "codex"].map((id) => (
          <CompactQuotaRow
            key={id}
            id={id}
            provider={state.providers.find((item) => item.providerID === id)}
            notice={state.notices[id]}
          />
        ))}
      </div>
      <div className="risk-footer">
        <span>Risk level</span>
        <strong className={`badge badge-${risk || "unknown"}`}>{risk?.toUpperCase() || "UNKNOWN"}</strong>
      </div>
    </section>
  );
}

function CompactQuotaRow({ provider, notice, id }) {
  const meta = PROVIDERS[id];
  const primary = provider?.windows?.[0];
  const remaining = primary ? Math.max(0, 100 - primary.usedPercent) : undefined;
  return (
    <article className="compact-quota-row">
      {primary ? (
        <>
          <div className="compact-quota-head">
            <div className="compact-provider"><img src={meta.icon} alt="" /><div><h3>{meta.name}</h3><p>{provider?.planName || "Official usage"}</p></div></div>
            <strong className="compact-percent" style={{ color: meta.color }}>{formatPercent(remaining)}</strong>
          </div>
          <Meter value={remaining} color={meta.color} />
          <div className="compact-quota-meta">
            <span>{formatWindow(primary.windowMinutes)}</span>
            <span>Resets <strong>{formatReset(primary.resetsAt)}</strong> · Captured {formatTime(provider.capturedAt)}</span>
          </div>
        </>
      ) : <div className="compact-empty"><div className="compact-provider"><img src={meta.icon} alt="" /><div><h3>{meta.name}</h3><p>Official usage</p></div></div><span>{notice || `${meta.name} is not signed in on this PC.`}</span></div>}
    </article>
  );
}

function ProviderCard({ provider, notice, id, detailed = false }) {
  const meta = PROVIDERS[id];
  const primary = provider?.windows?.[0];
  const remaining = primary ? Math.max(0, 100 - primary.usedPercent) : undefined;
  return (
    <article className="provider-card">
      <div className="provider-title"><img src={meta.icon} alt="" /><div><h3>{meta.name}</h3><p>{provider?.planName || "Official usage"}</p></div></div>
      {primary ? (
        <>
          <div className="quota-summary"><div><span>Remaining</span><strong style={{ color: meta.color }}>{formatPercent(remaining)}</strong></div><div className="reset"><span>Resets</span><strong>{formatReset(primary.resetsAt)}</strong></div></div>
          <Meter value={remaining} color={meta.color} />
          <div className="window-row"><span>{formatWindow(primary.windowMinutes)}</span><span>Captured {formatTime(provider.capturedAt)}</span></div>
          {detailed && provider.windows.slice(1).map((window) => (
            <div className="secondary-window" key={window.windowMinutes}><div><strong>{formatWindow(window.windowMinutes)}</strong><span>{formatPercent(100 - window.usedPercent)} remaining</span></div><span>{formatReset(window.resetsAt)}</span></div>
          ))}
        </>
      ) : <div className="empty-provider"><strong>No quota yet</strong><span>{notice || `${meta.name} is not signed in on this PC.`}</span></div>}
    </article>
  );
}

function Meter({ value, color }) {
  const segments = 12;
  const active = Math.round((value / 100) * segments);
  return <div className="meter" role="meter" aria-label="Quota remaining" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(value)} aria-valuetext={`${formatPercent(value)} remaining`}>{Array.from({ length: segments }, (_, index) => <i className={index < active ? "active" : ""} key={index} style={{ background: index < active ? color : undefined }} />)}</div>;
}

function DirectSyncPanel({ state, onManage }) {
  return (
    <section className="direct-sync-panel">
      <div className="panel-heading"><h2>Direct Sync</h2><p>Encrypted direct sync between your devices</p></div>
      <SyncStrip sync={state.sync} deviceName={state.deviceName} />
      <button className="manage-devices" onClick={onManage}><SettingsIcon /><span>Manage devices</span><ChevronRightIcon /></button>
    </section>
  );
}

function SyncStrip({ sync, deviceName }) {
  return (
    <div className="sync-strip">
      <div><DevicesIcon /><span><strong>{deviceName}</strong><small>This PC</small></span></div>
      <div className={sync.paired ? "sync-link connected" : "sync-link"}><span /><LockIcon /><span /><small>{sync.paired ? "Encrypted direct sync" : "Not paired"}</small></div>
      <div className="mac-end"><span><strong>{sync.deviceName || "Mac"}</strong><small>{sync.lastSyncAt ? `Last sync ${relativeTime(sync.lastSyncAt)}` : sync.error || "Open Devices to pair"}</small></span><DevicesIcon /></div>
    </div>
  );
}

function Devices({ state, action }) {
  const [macURL, setMacURL] = useState(state.sync.macURL || "http://mac.local:47831");
  const [pairingCode, setPairingCode] = useState("");
  const [busy, setBusy] = useState(false);
  async function pair(event) {
    event.preventDefault(); setBusy(true);
    await action(() => api.pair({ macURL, pairingCode }));
    setPairingCode(""); setBusy(false);
  }
  return (
    <section className="content-section">
      <div className="settings-card">
        <div className="card-heading"><div><h3>This Windows PC</h3><p>{state.deviceName} · source {state.sourceInstanceID.slice(0, 6).toUpperCase()}</p></div><span className="healthy"><span className="status-dot" />Monitoring</span></div>
      </div>
      <div className="settings-card">
        <div className="card-heading"><div><h3>Mac direct sync</h3><p>Quota snapshots only; provider credentials never leave either device.</p></div><span className={state.sync.paired ? "healthy" : "muted"}>{state.sync.paired ? "Paired" : "Not paired"}</span></div>
        {state.sync.paired ? (
          <div className="paired-details"><Info label="Mac" value={state.sync.deviceName || "Mac"} /><Info label="Address" value={state.sync.macURL} /><Info label="Encryption" value={state.sync.encryption} /><Info label="Last sync" value={state.sync.lastSyncAt ? relativeTime(state.sync.lastSyncAt) : state.sync.error || "Waiting"} /><button className="secondary danger" onClick={() => action(api.disconnect)}>Disconnect</button></div>
        ) : (
          <form className="pair-form" onSubmit={pair}>
            <label>Mac address<input value={macURL} onChange={(event) => setMacURL(event.target.value)} placeholder="http://mac.local:47831" /></label>
            <label>One-time pairing code<input type="password" autoComplete="off" value={pairingCode} onChange={(event) => setPairingCode(event.target.value)} placeholder="Shown in TokenRemain on Mac" /></label>
            <button className="primary" disabled={busy || !pairingCode.trim()}>{busy ? "Pairing…" : "Pair Mac"}</button>
          </form>
        )}
      </div>
    </section>
  );
}

function Settings() {
  return (
    <section className="content-section">
      <div className="settings-card policy-list"><Info label="Refresh interval" value="1 minute" /><Info label="Credential access" value="Read-only local CLI files" /><Info label="Sync transport" value="Encrypted LAN snapshots" /><Info label="CloudKit / phone sync" value="Not used in this Windows branch" /></div>
    </section>
  );
}

function Info({ label, value }) { return <div className="info-row"><span>{label}</span><strong>{value}</strong></div>; }

function formatPercent(value) { return `${Math.round(value)}%`; }
function formatTime(value) { return new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" }).format(new Date(value)); }
function formatReset(value) { return value ? relativeTime(value, "Unknown") : "Unknown"; }
function relativeTime(value, fallback = "Never") {
  if (!value) return fallback;
  const minutes = Math.round((value - Date.now()) / 60_000);
  if (Math.abs(minutes) < 1) return "now";
  if (minutes > 0) return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} hr ${minutes % 60} min`;
  const ago = Math.abs(minutes);
  return `${ago < 60 ? `${ago} min` : `${Math.floor(ago / 60)} hr`} ago`;
}
function formatWindow(minutes) { if (!minutes) return "Total"; if (minutes % 10080 === 0) return `${minutes / 10080} week window`; if (minutes % 1440 === 0) return `${minutes / 1440} day window`; if (minutes % 60 === 0) return `${minutes / 60} hr window`; return `${minutes} min window`; }

function syncSummary(sync) {
  if (sync.error) return { value: "Needs attention", detail: sync.error, tone: "warning" };
  if (sync.paired) return { value: "Connected", detail: "Encrypted direct sync", tone: "healthy" };
  return { value: "Windows only", detail: "Pair a Mac in Devices", tone: "violet" };
}

function Icon({ children }) { return <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">{children}</svg>; }
function GridIcon() { return <Icon><rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><rect x="14" y="14" width="6" height="6" rx="1"/></Icon>; }
function GaugeIcon() { return <Icon><path d="M5 17a8 8 0 1 1 14 0"/><path d="m12 13 4-4"/><path d="M8 19h8"/></Icon>; }
function DevicesIcon() { return <Icon><rect x="3" y="5" width="13" height="10" rx="1.5"/><path d="M7 19h5M9.5 15v4"/><rect x="17" y="9" width="4" height="8" rx="1"/></Icon>; }
function SettingsIcon() { return <Icon><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3A1.7 1.7 0 0 0 10 3V2.8h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z"/></Icon>; }
function RefreshIcon() { return <Icon><path d="M20 7v5h-5"/><path d="M4 17v-5h5"/><path d="M6.1 8a7 7 0 0 1 11.5-2.6L20 7M4 17l2.4 1.6A7 7 0 0 0 17.9 16"/></Icon>; }
function LockIcon() { return <Icon><rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></Icon>; }
function ChevronRightIcon() { return <Icon><path d="m9 6 6 6-6 6"/></Icon>; }

function createPreviewAPI() {
  let preview = {
    sourceInstanceID: "8ad9c4b2-5ac9-44d7-b313-ae4f3fc59fb0",
    deviceName: "Windows PC",
    lastUpdatedAt: Date.now(),
    isRefreshing: false,
    notices: {},
    providers: [
      { providerID: "claude", capturedAt: Date.now(), planName: "Max 20x", windows: [{ usedPercent: 43, windowMinutes: 300, resetsAt: Date.now() + 10_320_000 }, { usedPercent: 18, windowMinutes: 10_080, resetsAt: Date.now() + 421_200_000 }] },
      { providerID: "codex", capturedAt: Date.now(), planName: "Pro 5x", windows: [{ usedPercent: 63, windowMinutes: 300, resetsAt: Date.now() + 43_200_000 }, { usedPercent: 31, windowMinutes: 10_080, resetsAt: Date.now() + 331_200_000 }] },
    ],
    sync: { paired: true, macURL: "http://mac-studio.local:47831/", deviceName: "Mac Studio", lastSyncAt: Date.now() - 60_000, encryption: "AES-256-GCM" },
  };
  return {
    getState: async () => preview,
    refresh: async () => ({ ...preview, lastUpdatedAt: Date.now() }),
    pair: async () => preview,
    disconnect: async () => (preview = { ...preview, sync: { paired: false } }),
    onStateChanged: () => () => {},
  };
}

createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
