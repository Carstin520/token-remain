import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import appIcon from "../../site/assets/brand/appicon-mac.png";
import { DirectReorderGrid, usePersistentOrder } from "./direct-reorder.jsx";
import { LIMITS_ORDER_KEY, normalizeOrder } from "./layout.js";
import { buildOverviewSummary, buildTodayUsage } from "./overview-model.js";
import { PROVIDER_ORDER, providerMeta } from "./provider-meta.js";
import "./styles.css";

const PROVIDER_ICON_MODULES = import.meta.glob("../../site/assets/providers/*.{svg,png}", { eager: true, import: "default" });
const PROVIDER_ICONS = Object.fromEntries(Object.entries(PROVIDER_ICON_MODULES).map(([path, url]) => [path.split("/").pop(), url]));
const SECTIONS = {
  overview: { title: "Overview", subtitle: "Quota risk, today's usage, and estimated cost" },
  limits: { title: "Limits", subtitle: "Every active official quota window" },
  trends: { title: "Trends", subtitle: "Multi-day usage synced from your Mac" },
  devices: { title: "Devices", subtitle: "Direct, encrypted sync on your local network" },
  dataSources: { title: "Data Sources", subtitle: "Local collectors, synced data, and source health" },
  settings: { title: "Settings", subtitle: "Direct sync, Windows collection, and privacy" },
};
const api = window.tokenRemain ?? (import.meta.env.DEV ? createPreviewAPI() : undefined);

function providerPresentation(providerID) {
  const meta = providerMeta(providerID);
  return { ...meta, icon: PROVIDER_ICONS[meta.icon] };
}

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

  async function openExternal(url) {
    setError(undefined);
    try { await api.openExternal(url); }
    catch (reason) { setError(reason.message); }
  }

  if (!state) return <div className="loading">Loading TokenRemain…</div>;
  return (
    <div className="app-shell">
      <Sidebar section={section} onSelect={setSection} />
      <main className="main-content">
        <Header state={state} section={section} onRefresh={() => action(api.refresh)} />
        {error && <div className="error-banner">{error}</div>}
        {section === "overview" && <Overview state={state} onSelect={setSection} onOpen={openExternal} />}
        {section === "limits" && <Limits state={state} />}
        {section === "trends" && <Trends state={state} />}
        {section === "devices" && <Devices state={state} action={action} />}
        {section === "dataSources" && <DataSources state={state} />}
        {section === "settings" && <Settings state={state} onSelect={setSection} />}
      </main>
    </div>
  );
}

function Sidebar({ section, onSelect }) {
  const items = [
    ["overview", "Overview", GridIcon],
    ["limits", "Limits", GaugeIcon],
    ["trends", "Trends", TrendsIcon],
    ["devices", "Devices", DevicesIcon],
    ["dataSources", "Data Sources", DataSourcesIcon],
    ["settings", "Settings", SettingsIcon],
  ];
  return (
    <aside className="sidebar">
      <div className="brand"><img src={appIcon} alt="" /><span>TokenRemain</span></div>
      <div className="nav-label">MONITOR</div>
      <nav>
        {items.slice(0, 4).map(([id, name, Icon]) => (
          <button key={id} className={section === id ? "selected" : ""} aria-current={section === id ? "page" : undefined} onClick={() => onSelect(id)}><Icon />{name}</button>
        ))}
      </nav>
      <div className="nav-label system-label">SYSTEM</div>
      <nav>
        {items.slice(4).map(([id, name, Icon]) => (
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

function Overview({ state, onSelect, onOpen }) {
  const summary = buildOverviewSummary(state.providers);
  const today = buildTodayUsage(state.dailyUsageHistory);
  const risk = summary.riskNotes;
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
          label="Today's Tokens"
          value={today?.totalTokens ? compactNumber(today.totalTokens) : "—"}
          detail={state.dailyUsageHistory ? "Synced from Mac history" : "Daily history not shared"}
        />
        <MetricCard
          label="Today's Est. Cost"
          value={Number.isFinite(today?.totalCost) ? formatMoney(today.totalCost) : "—"}
          detail={today?.totalTokens && !Number.isFinite(today?.totalCost) ? "Cost unavailable in synced aggregate" : "Estimated from Mac history"}
        />
        <MetricCard
          compact
          label={risk.projectedRunOutAt ? "Projected runway" : "Quota sustainability"}
          value={risk.projectedRunOutAt ? formatDurationUntil(risk.projectedRunOutAt) : summary.risk ? "To reset" : "—"}
          detail={risk.projectedRunOutAt ? `${risk.window.providerName} ${formatWindowShort(risk.window.windowMinutes)} · before reset` : "At the current window pace"}
          tone={risk.projectedRunOutAt ? "medium" : summary.risk === "low" ? "healthy" : summary.risk}
        />
      </div>
      <div className="overview-grid">
        <UsageCostCard state={state} today={today} onManage={() => onSelect("devices")} />
        <OfficialQuota state={state} risk={summary.risk} />
        <TrendingCard state={state} onOpen={onOpen} />
        <RiskNotes risk={risk} />
      </div>
    </section>
  );
}

function UsageCostCard({ state, today, onManage }) {
  const hasEntries = Boolean(today?.entries?.length);
  let rotation = 0;
  const stops = Number.isFinite(today?.totalCost) && today.totalCost > 0
    ? today.entries.flatMap((entry) => {
      const start = rotation;
      rotation += entry.costShare;
      const color = providerPresentation(entry.id).color;
      return [`${color} ${start}%`, `${color} ${rotation}%`];
    }).join(", ")
    : "#2a2c35 0 100%";
  return (
    <section className="dashboard-panel usage-cost-card">
      <PanelHeading title="Today's Usage & Cost" subtitle="By provider · synced daily aggregate" />
      {hasEntries ? (
        <>
          <div className="usage-composition">
            <div className="donut" style={{ background: `conic-gradient(${stops})` }}>
              <div><strong>{Number.isFinite(today.totalCost) ? formatMoney(today.totalCost) : "—"}</strong><span>{Number.isFinite(today.totalCost) ? "Est. today" : "Cost unavailable"}</span></div>
            </div>
            <div className="usage-provider-list">
              {today.entries.map((entry) => (
                <div className="usage-provider-row" key={entry.id}>
                  <span className="provider-dot" style={{ background: providerPresentation(entry.id).color }} />
                  <strong>{entry.displayName}</strong>
                  <span>{compactNumber(entry.tokens)} · {entry.cost > 0 ? formatMoney(entry.cost) : "—"}</span>
                  <b>{Number.isFinite(entry.costShare) ? formatPercent(entry.costShare) : "—"}</b>
                </div>
              ))}
            </div>
          </div>
          <p className="panel-source">Captured {formatTime(today.capturedAt)} on Mac · daily aggregate only</p>
        </>
      ) : (
        <PanelEmpty
          title={!state.sync.paired ? "Pair your Mac to see today's usage" : state.dailyUsageHistory ? "Nothing recorded today yet" : "No usage history from your Mac yet"}
          message={!state.sync.paired ? "Direct sync can bring the same daily aggregate to this PC." : state.dailyUsageHistory ? "TokenRemain will show this card after Claude or Codex records usage for the source Mac's current day." : "Turn on “Share daily usage with paired devices” in TokenRemain › Devices on your Mac."}
          action={!state.sync.paired ? <button className="inline-action" onClick={onManage}>Manage devices</button> : undefined}
        />
      )}
    </section>
  );
}

function TrendingCard({ state, onOpen }) {
  const posts = state.trending || [];
  return (
    <section className="dashboard-panel trending-card">
      <PanelHeading title="Trending" subtitle="What matters most right now" trailing={<span className="badge badge-hot">HOT</span>} />
      {posts.length ? (
        <div className="trending-list">
          {posts.slice(0, 2).map((post, index) => (
            <button className={`trend-row trend-${index + 1}`} key={post.id} onClick={() => onOpen(post.url)}>
              <div className="trend-meta"><strong><span>{index === 0 ? "♨" : "ϟ"}</span> #{index + 1}</strong><b>{post.displayName}</b><time>{relativeTime(post.publishedAt)}</time><span className="open-arrow">↗</span></div>
              <p>{post.text}</p>
              <div className="trend-metrics"><span>▢ {compactNumber(post.metrics.replies)}</span><span>⇄ {compactNumber(post.metrics.reposts)}</span><span>♡ {compactNumber(post.metrics.likes)}</span></div>
            </button>
          ))}
          <p className="panel-source">Public TokenRemain feed{state.feedError ? ` · cached (${state.feedError})` : ""}</p>
        </div>
      ) : <PanelEmpty title={state.feedLoading ? "Loading trending…" : state.feedError ? "Trending is temporarily unavailable" : "Nothing trending right now"} message={state.feedError || "The public feed has no current stories."} />}
    </section>
  );
}

function RiskNotes({ risk }) {
  if (!risk.window) return (
    <section className="dashboard-panel risk-notes">
      <PanelHeading title="Risk Notes" subtitle="Based on the tightest quota window" />
      <PanelEmpty title="Waiting for official quota" message="No official quota snapshot yet. TokenRemain will retry automatically." />
    </section>
  );
  return (
    <section className="dashboard-panel risk-notes">
      <PanelHeading title="Risk Notes" subtitle="Based on the tightest quota window" />
      <div className="risk-headline"><span className={`badge badge-${risk.level}`}>{risk.level.toUpperCase()}</span><strong>{risk.headline}</strong></div>
      <p className="risk-summary">{risk.summary}</p>
      <div className="risk-details">
        <Info label="Tightest window" value={`${risk.window.providerName} · ${formatWindowShort(risk.window.windowMinutes)}`} />
        <Info label="Remaining quota" value={formatPercent(risk.window.remaining)} />
        {risk.projectedRunOutAt && <Info label="Projected depletion" value={formatDurationUntil(risk.projectedRunOutAt)} />}
        {risk.window.resetsAt && <Info label="Projected reset" value={`Resets ${formatReset(risk.window.resetsAt)}`} />}
      </div>
    </section>
  );
}

function PanelHeading({ title, subtitle, trailing }) {
  return <div className="panel-heading panel-heading-row"><div><h2>{title}</h2><p>{subtitle}</p></div>{trailing}</div>;
}

function PanelEmpty({ title, message, action }) {
  return <div className="panel-empty"><strong>{title}</strong><p>{message}</p>{action}</div>;
}

function Limits({ state }) {
  const knownProviderIDs = PROVIDER_ORDER.filter((id) => (
    id === "claude" || id === "codex" || state.providers.some((provider) => provider.providerID === id)
  ));
  const providerIDs = [
    ...knownProviderIDs,
    ...state.providers.map((provider) => provider.providerID).filter((id) => !PROVIDER_ORDER.includes(id)),
  ];
  const [order, setOrder] = usePersistentOrder(providerIDs, LIMITS_ORDER_KEY);
  return (
    <section className="content-section">
      <DirectReorderGrid
        className="quota-grid"
        order={normalizeOrder(order, providerIDs)}
        onOrderChange={setOrder}
        renderItem={(id) => <ProviderCard detailed provider={state.providers.find((item) => item.providerID === id)} notice={state.notices[id]} id={id} />}
      />
    </section>
  );
}

function Trends({ state }) {
  const days = (state.dailyUsageHistory?.days || []).slice(-14);
  const totals = days.map((day) => (day.claudeTokens || 0) + (day.codexTokens || 0));
  const maximum = Math.max(1, ...totals);
  const today = buildTodayUsage(state.dailyUsageHistory);
  return (
    <section className="content-section trends-section">
      <section className="dashboard-panel trend-history-panel">
        <PanelHeading title="Daily Usage" subtitle="Claude and Codex tokens · latest 14 synced days" />
        {days.length >= 2 ? (
          <>
            <div className="trend-chart" role="img" aria-label="Daily token usage for the latest synced days">
              {days.map((day, index) => {
                const total = totals[index];
                const claudeHeight = day.claudeTokens / maximum * 100;
                const codexHeight = day.codexTokens / maximum * 100;
                return (
                  <div className="trend-column" key={day.day} title={`${day.day}: ${compactNumber(total)} tokens`}>
                    <div className="trend-bar">
                      <i className="trend-codex" style={{ height: `${codexHeight}%` }} />
                      <i className="trend-claude" style={{ height: `${claudeHeight}%` }} />
                    </div>
                    <span>{formatDay(day.day)}</span>
                  </div>
                );
              })}
            </div>
            <div className="trend-legend"><span><i className="provider-dot codex-dot" />Codex</span><span><i className="provider-dot claude-dot" />Claude</span></div>
            <p className="panel-source">Captured {formatTime(state.dailyUsageHistory.capturedAt)} on Mac · synced daily aggregate</p>
          </>
        ) : (
          <PanelEmpty title="Building your trend" message="At least two synced days are needed. Keep Direct Sync enabled and TokenRemain will add each Mac day automatically." />
        )}
      </section>
      <div className="trends-summary-grid">
        <div className="settings-card policy-list">
          <div className="card-heading"><div><h3>Current snapshot</h3><p>Same daily aggregate used by Overview</p></div></div>
          <Info label="Today's tokens" value={today?.totalTokens ? compactNumber(today.totalTokens) : "—"} />
          <Info label="Today's estimated cost" value={Number.isFinite(today?.totalCost) ? formatMoney(today.totalCost) : "—"} />
          {today?.entries?.map((entry) => <Info key={entry.id} label={entry.displayName} value={`${compactNumber(entry.tokens)} · ${entry.cost > 0 ? formatMoney(entry.cost) : "—"}`} />)}
        </div>
        <div className="settings-card policy-list">
          <div className="card-heading"><div><h3>History coverage</h3><p>Privacy-minimized data received from your Mac</p></div></div>
          <Info label="Synced days" value={String(days.length)} />
          <Info label="Oldest day" value={days[0]?.day || "Waiting"} />
          <Info label="Latest day" value={days.at(-1)?.day || "Waiting"} />
          <Info label="Quota history" value="Current snapshots only" />
        </div>
      </div>
    </section>
  );
}

function DataSources({ state }) {
  const local = new Map((state.localProviders || []).map((provider) => [provider.providerID, provider]));
  const remoteCount = state.sync.paired ? state.providers.filter((provider) => {
    const localProvider = local.get(provider.providerID);
    return !localProvider || provider.capturedAt > localProvider.capturedAt;
  }).length : 0;
  return (
    <section className="content-section data-sources-section">
      <div className="settings-card source-list">
        <div className="card-heading"><div><h3>Source status</h3><p>Only normalized quota and usage values enter the dashboard.</p></div></div>
        {["claude", "codex"].map((id) => (
          <SourceRow
            key={id}
            name={`${providerPresentation(id).name} CLI`}
            detail={state.notices[id] || "Read-only local credential and quota check"}
            healthy={local.has(id) && !state.notices[id]}
            capturedAt={local.get(id)?.capturedAt}
          />
        ))}
        <SourceRow
          name="Mac Direct Sync"
          detail={state.sync.error || (state.sync.paired ? `${remoteCount} fresher provider snapshot${remoteCount === 1 ? "" : "s"}` : "Open Devices to pair a Mac")}
          healthy={state.sync.paired && !state.sync.error}
          capturedAt={state.sync.lastSyncAt}
        />
        <SourceRow
          name="Synced daily usage"
          detail="Claude and Codex daily aggregate; no prompts, paths, or credentials"
          healthy={Boolean(state.dailyUsageHistory)}
          capturedAt={state.dailyUsageHistory?.capturedAt}
        />
        <SourceRow
          name="TokenRemain AI Feed"
          detail={state.feedError || "Public curated feed"}
          healthy={!state.feedError && Boolean(state.feedUpdatedAt || state.trending?.length)}
          capturedAt={state.feedUpdatedAt}
        />
      </div>
      <div className="settings-card policy-list">
        <div className="card-heading"><div><h3>Privacy boundary</h3><p>Windows keeps provider secrets local and sync payloads minimal.</p></div></div>
        <Info label="Credential access" value="Read-only local CLI files" />
        <Info label="Direct Sync" value="AES-256-GCM encrypted LAN snapshots" />
        <Info label="Shared usage" value="Optional daily aggregate only" />
        <Info label="CloudKit / phone sync" value="Not used on Windows" />
      </div>
    </section>
  );
}

function SourceRow({ name, detail, healthy, capturedAt }) {
  return (
    <div className="source-row">
      <span className={healthy ? "source-status healthy-source" : "source-status"}><span className="status-dot" />{healthy ? "Healthy" : "Needs setup"}</span>
      <div><strong>{name}</strong><small>{detail}</small></div>
      <time>{capturedAt ? formatTime(capturedAt) : "Not available"}</time>
    </div>
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
        {["codex", "claude"].map((id) => (
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
  const meta = providerPresentation(id);
  const primary = provider?.windows?.[0];
  const remaining = primary ? Math.max(0, 100 - primary.usedPercent) : undefined;
  return (
    <article className="compact-quota-row">
      {primary ? (
        <>
          <div className="compact-quota-head">
            <div className="compact-provider"><ProviderMark meta={meta} /><div><h3>{meta.name}</h3><p>{provider?.planName || "Official usage"}</p></div></div>
            <strong className="compact-percent" style={{ color: meta.color }}>{formatPercent(remaining)}</strong>
          </div>
          <Meter value={remaining} color={meta.color} />
          <div className="compact-quota-meta">
            <span>{formatWindow(primary.windowMinutes)}</span>
            <span>Resets <strong>{formatReset(primary.resetsAt)}</strong> · Captured {formatTime(provider.capturedAt)}</span>
          </div>
        </>
      ) : <div className="compact-empty"><div className="compact-provider"><ProviderMark meta={meta} /><div><h3>{meta.name}</h3><p>Official usage</p></div></div><span>{notice || `${meta.name} is not signed in on this PC.`}</span></div>}
    </article>
  );
}

function ProviderCard({ provider, notice, id, detailed = false }) {
  const meta = providerPresentation(id);
  const primary = provider?.windows?.[0];
  const remaining = primary ? Math.max(0, 100 - primary.usedPercent) : undefined;
  return (
    <article className="provider-card">
      <div className="provider-title"><ProviderMark meta={meta} /><div><h3>{meta.name}</h3><p>{provider?.planName || "Official usage"}</p></div></div>
      {primary ? (
        <>
          <div className="quota-summary"><div><span>Remaining</span><strong style={{ color: meta.color }}>{formatPercent(remaining)}</strong></div><div className="reset"><span>Resets</span><strong>{formatReset(primary.resetsAt)}</strong></div></div>
          <Meter value={remaining} color={meta.color} />
          <div className="window-row"><span>{formatWindow(primary.windowMinutes)}</span><span>Captured {formatTime(provider.capturedAt)}</span></div>
          {primary.remainingBalance && <div className="secondary-window"><div><strong>Remaining balance</strong><span>{primary.remainingBalance.currencyCode}</span></div><span>{formatBalance(primary.remainingBalance)}</span></div>}
          {detailed && provider.windows.slice(1).map((window) => (
            <div className="secondary-window" key={window.windowMinutes}><div><strong>{formatWindow(window.windowMinutes)}</strong><span>{formatPercent(100 - window.usedPercent)} remaining</span></div><span>{formatReset(window.resetsAt)}</span></div>
          ))}
          {detailed && (provider.scopedWindows || []).map((scope) => (
            <div className="secondary-window" key={`${scope.scopeID}-${scope.window.windowMinutes}`}><div><strong>{scope.displayName}</strong><span>{formatPercent(100 - scope.window.usedPercent)} remaining · {formatWindow(scope.window.windowMinutes)}</span></div><span>{formatReset(scope.window.resetsAt)}</span></div>
          ))}
        </>
      ) : <div className="empty-provider"><strong>No quota yet</strong><span>{notice || `${meta.name} is not signed in on this PC.`}</span></div>}
    </article>
  );
}

function ProviderMark({ meta }) {
  return meta.icon
    ? <img src={meta.icon} alt="" />
    : <span className="provider-mark-fallback" aria-hidden="true">{meta.name.slice(0, 2).toUpperCase()}</span>;
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
        <div className="card-heading"><div><h3>Mac direct sync</h3><p>Quota snapshots and optional daily aggregates; provider credentials never leave either device.</p></div><span className={state.sync.paired ? "healthy" : "muted"}>{state.sync.paired ? "Paired" : "Not paired"}</span></div>
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

function Settings({ state, onSelect }) {
  return (
    <section className="content-section settings-section">
      <DirectSyncPanel state={state} onManage={() => onSelect("devices")} />
      <div className="settings-card policy-list"><Info label="Refresh interval" value="1 minute" /><Info label="Credential access" value="Read-only local CLI files" /><Info label="Sync transport" value="Encrypted LAN snapshots" /><Info label="CloudKit / phone sync" value="Not used in this Windows branch" /></div>
    </section>
  );
}

function Info({ label, value }) { return <div className="info-row"><span>{label}</span><strong>{value}</strong></div>; }

function formatPercent(value) { return `${Math.round(value)}%`; }
function formatMoney(value) { return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value); }
function formatBalance(balance) {
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency: balance.currencyCode, maximumFractionDigits: 2 }).format(balance.amount);
  } catch {
    return `${balance.amount.toFixed(2)} ${balance.currencyCode}`;
  }
}
function compactNumber(value) {
  if (!Number.isFinite(value)) return "—";
  if (Math.abs(value) >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(value >= 10_000_000_000 ? 1 : 2).replace(/\.0+$/, "")}B`;
  if (Math.abs(value) >= 1_000_000) return `${(value / 1_000_000).toFixed(value >= 10_000_000 ? 1 : 2).replace(/\.0+$/, "")}M`;
  if (Math.abs(value) >= 1_000) return `${(value / 1_000).toFixed(value >= 10_000 ? 1 : 2).replace(/\.0+$/, "")}K`;
  return String(Math.round(value));
}
function formatTime(value) { return new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" }).format(new Date(value)); }
function formatDay(value) { return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(new Date(`${value}T00:00:00Z`)); }
function formatReset(value) { return value ? relativeTime(value, "Unknown") : "Unknown"; }
function formatDurationUntil(value, now = Date.now()) {
  const minutes = Math.max(0, Math.floor((value - now) / 60_000));
  const days = Math.floor(minutes / 1_440);
  const hours = Math.floor(minutes % 1_440 / 60);
  const remainder = minutes % 60;
  return [days ? `${days} d` : "", hours ? `${hours} hr` : "", !days && remainder ? `${remainder} min` : ""].filter(Boolean).join(" ") || "now";
}
function relativeTime(value, fallback = "Never") {
  if (!value) return fallback;
  const minutes = Math.round((value - Date.now()) / 60_000);
  if (Math.abs(minutes) < 1) return "now";
  if (minutes > 0) return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} hr ${minutes % 60} min`;
  const ago = Math.abs(minutes);
  return `${ago < 60 ? `${ago} min` : `${Math.floor(ago / 60)} hr`} ago`;
}
function formatWindow(minutes) { if (!minutes) return "Total"; if (minutes % 10080 === 0) return `${minutes / 10080} week window`; if (minutes % 1440 === 0) return `${minutes / 1440} day window`; if (minutes % 60 === 0) return `${minutes / 60} hr window`; return `${minutes} min window`; }
function formatWindowShort(minutes) { if (!minutes) return "Total"; if (minutes % 1440 === 0) return `${minutes / 1440} d`; if (minutes % 60 === 0) return `${minutes / 60} hr`; return `${minutes} min`; }

function syncSummary(sync) {
  if (sync.error) return { value: "Needs attention", detail: sync.error, tone: "warning" };
  if (sync.paired) return { value: "Connected", detail: "Encrypted direct sync", tone: "healthy" };
  return { value: "Windows only", detail: "Pair a Mac in Devices", tone: "violet" };
}

function Icon({ children }) { return <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">{children}</svg>; }
function GridIcon() { return <Icon><rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><rect x="14" y="14" width="6" height="6" rx="1"/></Icon>; }
function GaugeIcon() { return <Icon><path d="M5 17a8 8 0 1 1 14 0"/><path d="m12 13 4-4"/><path d="M8 19h8"/></Icon>; }
function TrendsIcon() { return <Icon><path d="M4 18V6"/><path d="M4 18h16"/><path d="m7 14 4-4 3 2 5-6"/></Icon>; }
function DevicesIcon() { return <Icon><rect x="3" y="5" width="13" height="10" rx="1.5"/><path d="M7 19h5M9.5 15v4"/><rect x="17" y="9" width="4" height="8" rx="1"/></Icon>; }
function DataSourcesIcon() { return <Icon><ellipse cx="12" cy="5" rx="7" ry="3"/><path d="M5 5v6c0 1.7 3.1 3 7 3s7-1.3 7-3V5"/><path d="M5 11v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"/></Icon>; }
function SettingsIcon() { return <Icon><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3A1.7 1.7 0 0 0 10 3V2.8h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z"/></Icon>; }
function RefreshIcon() { return <Icon><path d="M20 7v5h-5"/><path d="M4 17v-5h5"/><path d="M6.1 8a7 7 0 0 1 11.5-2.6L20 7M4 17l2.4 1.6A7 7 0 0 0 17.9 16"/></Icon>; }
function LockIcon() { return <Icon><rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></Icon>; }
function ChevronRightIcon() { return <Icon><path d="m9 6 6 6-6 6"/></Icon>; }

function createPreviewAPI() {
  const previewNow = Date.now();
  const previewDay = new Date(previewNow).toISOString().slice(0, 10);
  const previewHistoryDays = Array.from({ length: 7 }, (_, index) => {
    const day = new Date(previewNow - (6 - index) * 24 * 60 * 60_000).toISOString().slice(0, 10);
    return {
      day,
      claudeTokens: 4_800_000 + index * 1_050_000,
      claudeCost: 3.4 + index * 0.72,
      codexTokens: 13_200_000 + index * 3_140_000,
      codexCost: 9.45 + index * 2.25,
    };
  });
  const previewLocalProviders = [
    { providerID: "claude", capturedAt: previewNow, planName: "Max 20x", windows: [{ usedPercent: 43, windowMinutes: 300, resetsAt: previewNow + 10_320_000 }, { usedPercent: 18, windowMinutes: 10_080, resetsAt: previewNow + 421_200_000 }] },
    { providerID: "codex", capturedAt: previewNow, planName: "Pro 5x", windows: [{ usedPercent: 63, windowMinutes: 300, resetsAt: previewNow + 43_200_000 }, { usedPercent: 31, windowMinutes: 10_080, resetsAt: previewNow + 331_200_000 }] },
  ];
  let preview = {
    sourceInstanceID: "8ad9c4b2-5ac9-44d7-b313-ae4f3fc59fb0",
    deviceName: "Windows PC",
    lastUpdatedAt: previewNow,
    isRefreshing: false,
    notices: {},
    localProviders: previewLocalProviders,
    providers: [
      ...previewLocalProviders,
      { providerID: "cursor", capturedAt: previewNow - 30_000, planName: "Pro", windows: [{ usedPercent: 26, windowMinutes: 10_080, resetsAt: previewNow + 284_400_000 }] },
      { providerID: "openrouter", capturedAt: previewNow - 30_000, planName: "Credits", windows: [{ usedPercent: 12, windowMinutes: 0, remainingBalance: { amount: 42.75, currencyCode: "USD" } }] },
    ],
    dailyUsageHistory: { sourceDay: previewDay, capturedAt: previewNow, days: previewHistoryDays },
    trending: [
      { id: "1", displayName: "OpenAI", text: "An internal version of our next major model produced new results on long-standing open problems in mathematics and theoretical computer science.", publishedAt: previewNow - 12 * 60 * 60_000, url: "https://x.com/OpenAI/status/1234567890123456789", metrics: { replies: 377, reposts: 587, likes: 8_900 } },
      { id: "2", displayName: "Tibo", text: "A week of efficiency improvements is rolling out, with refreshed usage limits for coding workflows.", publishedAt: previewNow - 3 * 24 * 60 * 60_000, url: "https://x.com/thsottiaux/status/1234567890123456790", metrics: { replies: 2_900, reposts: 1_100, likes: 23_900 } },
    ],
    feedLoading: false,
    feedUpdatedAt: previewNow,
    sync: { paired: true, macURL: "http://mac-studio.local:47831/", deviceName: "Mac Studio", lastSyncAt: previewNow - 60_000, encryption: "AES-256-GCM" },
  };
  return {
    getState: async () => preview,
    refresh: async () => ({ ...preview, lastUpdatedAt: Date.now() }),
    pair: async () => preview,
    disconnect: async () => (preview = { ...preview, sync: { paired: false } }),
    openExternal: async () => true,
    onStateChanged: () => () => {},
  };
}

createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
