import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import appIcon from "../../site/assets/brand/appicon-mac.png";
import { DirectReorderGrid, usePersistentOrder } from "./direct-reorder.jsx";
import { curateForDisplay, initials, morePosts, priorityTitle, selectImportantForDisplay, topStories } from "./feed-model.js";
import {
  compactNumber,
  durationUntil,
  formatBalance,
  formatClock,
  formatClockSeconds,
  formatDayLabel,
  formatMoney,
  formatPercent,
  freshnessDescription,
  isStaleCapture,
  relativeAge,
  resetDescription,
  windowName,
  windowTitle,
} from "./format.js";
import {
  AlertIcon,
  ArrowUpRightIcon,
  BoltIcon,
  CheckCircleIcon,
  ChevronRightIcon,
  DataSourcesIcon,
  DevicesIcon,
  FlameIcon,
  GaugeIcon,
  GridIcon,
  HeartIcon,
  InfoIcon,
  LockIcon,
  MoonIcon,
  MinusIcon,
  PieIcon,
  PlusIcon,
  PowerIcon,
  RadioIcon,
  RefreshIcon,
  ReplyIcon,
  RepostIcon,
  ResetIcon,
  RestartIcon,
  SettingsIcon,
  SwitchIcon,
  TrendsIcon,
} from "./icons.jsx";
import { LIMITS_ORDER_KEY, normalizeOrder } from "./layout.js";
import { activateLanguage, languageOptions, SYSTEM_LANGUAGE, tr, trKey } from "./i18n.js";
import { buildOverviewSummary, buildTodayUsage, rankOfficialQuotaProviders, summaryWindow, usagePace } from "./overview-model.js";
import { providerMeta } from "./provider-meta.js";
import { compactAxisValue, linePoints, quotaTrendRows, TREND_RANGES, usageTrendModel } from "./trends-model.js";
import { usageProviderIDs } from "./usage-history.js";
import "./styles.css";

const PROVIDER_ICON_MODULES = import.meta.glob("../../site/assets/providers/*.{svg,png}", { eager: true, import: "default" });
const PROVIDER_ICONS = Object.fromEntries(Object.entries(PROVIDER_ICON_MODULES).map(([path, url]) => [path.split("/").pop(), url]));

// Section metadata mirrors the Mac's DashboardSection titles/subtitles, with
// honest wording where the Windows data source differs from the Mac.
const SECTIONS = {
  overview: { title: "Overview", subtitle: "Quota risk, today's usage, and estimated cost" },
  limits: { title: "Limits", subtitle: "Official quota windows across your AI coding tools" },
  trends: { title: "Trends", subtitle: "Usage over time · local on this PC, optionally synced from Mac" },
  devices: { title: "Devices", subtitle: "This PC and its encrypted Mac link" },
  dataSources: { title: "Data Sources", subtitle: "Data-source status and privacy" },
  settings: { title: "Settings", subtitle: "Quick View, startup, and app controls" },
};
const NAV_GROUPS = [
  { label: "MONITOR", items: ["overview", "limits", "trends", "devices"] },
  { label: "SYSTEM", items: ["dataSources", "settings"] },
];
const NAV_ICONS = { overview: GridIcon, limits: GaugeIcon, trends: TrendsIcon, devices: DevicesIcon, dataSources: DataSourcesIcon, settings: SettingsIcon };
const RISK_HEX = { low: "#57D19A", medium: "#FFB554", high: "#FF6B6B" };
const CYAN = "#3ECFE0";
const VIOLET = "#9B8AFB";
const VIOLET_DIM = "#6357B8";

const api = window.tokenRemain ?? (import.meta.env.DEV ? createPreviewAPI() : undefined);

function providerPresentation(providerID) {
  const meta = providerMeta(providerID);
  return { ...meta, id: providerID, icon: PROVIDER_ICONS[meta.icon] };
}

/// Quota meters reserve red for the same critical threshold as the Mac.
function quotaAccent(color, remaining) {
  return remaining < 10 ? "var(--danger)" : color;
}

function feedAccent(priority, fallback) {
  if (priority === "token_reset") return CYAN;
  if (priority === "major_update") return VIOLET_DIM;
  return fallback;
}

function hexAlpha(hex, alpha) {
  const value = hex.replace("#", "");
  const r = parseInt(value.slice(0, 2), 16);
  const g = parseInt(value.slice(2, 4), 16);
  const b = parseInt(value.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function timeAgo(value, fallback = "Never") {
  if (!value) return tr(fallback);
  if (Date.now() - value < 60_000) return tr("just now");
  const age = relativeAge(value);
  return tr("%1$@ ago", [age]);
}

function initialSection() {
  const requested = new URLSearchParams(globalThis.location?.search || "").get("section");
  return SECTIONS[requested] ? requested : "overview";
}

function App() {
  const [state, setState] = useState();
  const [section, setSection] = useState(initialSection);
  const [error, setError] = useState();
  activateLanguage(state?.languagePreference || SYSTEM_LANGUAGE, state?.systemLocale);

  useEffect(() => {
    api.getState().then(setState).catch((reason) => setError(reason.message));
    return api.onStateChanged(setState);
  }, []);

  // The tray popover keeps this window alive and hidden, so "Settings" from the
  // popover has to navigate the already-loaded dashboard instead of reloading.
  useEffect(() => api.onNavigate?.((requested) => {
    if (SECTIONS[requested]) setSection(requested);
  }), []);

  async function action(operation) {
    setError(undefined);
    try {
      const next = await operation();
      if (next) setState(next);
    } catch (reason) {
      setError(reason.message);
    }
  }

  async function openExternal(url) {
    setError(undefined);
    try { await api.openExternal(url); }
    catch (reason) { setError(reason.message); }
  }

  if (!state) return <div className="loading">{tr("Loading data…")}</div>;
  if (!state.onboarding?.completed) {
    return (
      <div className="window-frame onboarding-frame">
        <div className="window-drag-strip" aria-hidden="true" />
        <Onboarding state={state} action={action} error={error} />
      </div>
    );
  }
  return (
    <div className="window-frame">
      <div className="window-drag-strip" aria-hidden="true" />
      <div className="app-shell">
        <Sidebar
          state={state}
          section={section}
          onSelect={setSection}
          onRefresh={() => action(api.refresh)}
          onOpenPopup={() => action(api.openPopup)}
        />
        <main className="main-content">
          <div className="content-column">
            <SectionTitleHeader
              title={tr(SECTIONS[section].title)}
              subtitle={tr(SECTIONS[section].subtitle)}
              trailing={state.lastUpdatedAt ? trKey("common.updated_at", [formatClockSeconds(state.lastUpdatedAt)]) : undefined}
            />
            {error && <div className="error-banner" role="alert">{error}</div>}
            {section === "overview" && <Overview state={state} onSelect={setSection} onOpen={openExternal} />}
            {section === "limits" && <Limits state={state} action={action} />}
            {section === "trends" && <Trends state={state} />}
            {section === "devices" && <Devices state={state} action={action} />}
            {section === "dataSources" && <DataSources state={state} action={action} />}
            {section === "settings" && <Settings state={state} action={action} onSelect={setSection} />}
          </div>
        </main>
      </div>
    </div>
  );
}

// MARK: - First launch

function Onboarding({ state, action, error }) {
  const catalog = state.providerCatalog || [];
  const detectedIDs = catalog.filter((provider) => provider.installed).map((provider) => provider.id);
  const detectedSignature = detectedIDs.join("|");
  const [selection, setSelection] = useState(() => new Set(detectedIDs));
  const [manuallyAdded, setManuallyAdded] = useState(() => new Set());
  const [addOpen, setAddOpen] = useState(false);
  const visible = catalog.filter((provider) => provider.installed || manuallyAdded.has(provider.id));
  const addable = catalog.filter((provider) => !provider.installed && !manuallyAdded.has(provider.id));

  useEffect(() => {
    setSelection((current) => new Set([...current, ...detectedIDs]));
  }, [detectedSignature]); // eslint-disable-line react-hooks/exhaustive-deps

  function toggle(id) {
    setSelection((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  function add(id) {
    setManuallyAdded((current) => new Set([...current, id]));
    setSelection((current) => new Set([...current, id]));
    setAddOpen(false);
  }

  return (
    <main className="onboarding">
      <div className="onboarding-brand">
        <img src={appIcon} alt="" />
        <span className="wordmark">Token<b>Remain</b></span>
      </div>
      <section className="onboarding-card">
        <header>
          <img src={appIcon} alt="" />
          <h1>{tr("Welcome to TokenRemain")}</h1>
          <p>{tr("We scanned this Windows PC. Detected AI tools are already checked; choose what TokenRemain should monitor locally.")}</p>
        </header>
        {error && <div className="error-banner" role="alert">{error}</div>}
        <div className="onboarding-list">
          {visible.length ? visible.map((provider) => {
            const meta = providerPresentation(provider.id);
            const selected = selection.has(provider.id);
            return (
              <button
                key={provider.id}
                className={`onboarding-provider ${selected ? "selected" : ""}`}
                onClick={() => toggle(provider.id)}
                aria-pressed={selected}
              >
                <ProviderMark meta={meta} size={24} />
                <span><strong>{meta.name}{provider.installed && <i>{tr("Detected")}</i>}</strong><small>{tr(provider.detail)}</small></span>
                <CheckCircleIcon />
              </button>
            );
          }) : <p className="onboarding-empty">{tr("No installed AI coding tools detected; add one manually with + below, or install one later and TokenRemain will ask before connecting it.")}</p>}
          <div className="onboarding-add">
            <button className="onboarding-add-trigger" onClick={() => setAddOpen((value) => !value)} aria-expanded={addOpen}>
              <PlusIcon /><span>{tr("Add another app")}</span><ChevronRightIcon />
            </button>
            {addOpen && (
              <div className="onboarding-add-menu" role="menu">
                {addable.map((provider) => {
                  const meta = providerPresentation(provider.id);
                  return <button key={provider.id} role="menuitem" onClick={() => add(provider.id)}><ProviderMark meta={meta} size={18} /><span><strong>{meta.name}</strong><small>{provider.localSessionFirst ? `Local app session · ${provider.credentialKind}` : provider.access === "local-credential" ? `Local ${provider.credentialKind}` : "Local app sign-in"}</small></span><PlusIcon /></button>;
                })}
              </div>
            )}
          </div>
        </div>
        <footer>
          <button className="secondary" onClick={() => action(api.rescanProviders)}><RefreshIcon />{tr("Scan again")}</button>
          <button className="primary onboarding-start" onClick={() => action(() => api.completeOnboarding([...selection]))}>
            {selection.size ? trKey("onboarding.start_tracking", [selection.size]) : tr("Start without tracking")}
          </button>
          <p>{tr("Detection is local and read-only. Credentials stay on this PC and are never sent to your Mac.")}</p>
        </footer>
      </section>
    </main>
  );
}

// MARK: - Sidebar

function Sidebar({ state, section, onSelect, onRefresh, onOpenPopup }) {
  return (
    <aside className="sidebar">
      <div className="brand">
        <img src={appIcon} alt="" />
        <span className="wordmark">Token<b>Remain</b></span>
      </div>
      <div className="sidebar-nav">
        {NAV_GROUPS.map((group) => (
          <div className="nav-group" key={group.label}>
            <div className="nav-label">{tr(group.label)}</div>
            <nav>
              {group.items.map((id) => {
                const Icon = NAV_ICONS[id];
                return (
                  <button key={id} className={section === id ? "selected" : ""} aria-current={section === id ? "page" : undefined} onClick={() => onSelect(id)}>
                    <Icon />{tr(SECTIONS[id].title)}
                  </button>
                );
              })}
            </nav>
          </div>
        ))}
      </div>
      <SyncFooter state={state} onRefresh={onRefresh} onOpenPopup={onOpenPopup} />
    </aside>
  );
}

/// The Mac sidebar footer: a "Sync status" glass card owning the refresh
/// action and a green/amber/muted health readout.
function SyncFooter({ state, onRefresh, onOpenPopup }) {
  const needsAttention = Object.keys(state.notices || {}).length > 0 || state.sync?.error || state.feedError;
  const loading = !state.lastUpdatedAt;
  const health = loading
    ? { tone: "muted", text: tr("Loading data…") }
    : needsAttention
      ? { tone: "warning", text: tr("Some sources need attention") }
      : { tone: "success", text: tr("All sources healthy") };
  return (
    <div className="sync-footer">
      <div className="sync-footer-head">
        <span>{tr("Sync status")}</span>
        <button
          className="round-refresh"
          onClick={onRefresh}
          disabled={state.isRefreshing}
          aria-label={tr("Refresh")}
          title={tr("Refresh every data source now")}
        >
          <RefreshIcon spinning={state.isRefreshing} />
        </button>
      </div>
      <div className={`status-line tone-${health.tone}`}><span className="status-dot" />{health.text}</div>
      <button className="quick-view-link" onClick={onOpenPopup}><RadioIcon />{tr("Open Quick View")}</button>
    </div>
  );
}

function SectionTitleHeader({ title, subtitle, trailing }) {
  return (
    <header className="section-title">
      <div>
        <h1>{title}</h1>
        <p>{subtitle}</p>
      </div>
      {trailing && <span className="section-updated">{trailing}</span>}
    </header>
  );
}

// MARK: - Shared chrome

function PanelHeader({ title, subtitle, trailing }) {
  return (
    <div className="panel-heading">
      <div>
        <h2>{title}</h2>
        {subtitle && <p>{subtitle}</p>}
      </div>
      {trailing}
    </div>
  );
}

function Badge({ text, tone, filled = false }) {
  return <span className={`badge tone-${tone || "muted"} ${filled ? "filled" : ""}`}>{text}</span>;
}

function RiskBadge({ level }) {
  const normalized = level || "unknown";
  return <Badge text={normalized === "unknown" ? tr("Unknown") : trKey(`risk.badge.${normalized}`, [], normalized.toUpperCase())} tone={normalized} filled={level === "high"} />;
}

function Divider() {
  return <hr className="divider" />;
}

function InfoRow({ label, value, tone }) {
  return <div className="info-row"><span>{label}</span><strong className={tone ? `tone-${tone}` : undefined}>{value}</strong></div>;
}

function StatusDotLabel({ tone, text }) {
  return <span className={`status-line tone-${tone}`}><span className="status-dot" />{text}</span>;
}

function EmptyState({ icon: Icon, title, message, action }) {
  return (
    <div className="empty-state">
      {Icon && <Icon className="empty-icon" />}
      <strong>{title}</strong>
      <p>{message}</p>
      {action}
    </div>
  );
}

/// The Mac SegmentBar: block meter of `segments` cells; any non-zero remainder
/// lights at least one cell so a near-empty window never reads as depleted.
function SegmentBar({ remaining, color, segments = 14, height = 6 }) {
  const clamped = Math.min(100, Math.max(0, remaining));
  const raw = (clamped / 100) * segments;
  const filled = clamped > 0 && raw < 1 ? 1 : Math.min(segments, Math.round(raw));
  const accent = quotaAccent(color, clamped);
  return (
    <div className="segment-bar" style={{ height }} role="meter" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(clamped)} aria-valuetext={tr("%1$@ remaining", [formatPercent(clamped)])} aria-label={tr("Quota remaining")}>
      {Array.from({ length: segments }, (_, index) => (
        <i key={index} style={index < filled ? { background: accent } : undefined} />
      ))}
    </div>
  );
}

function ProviderMark({ meta, size = 20 }) {
  return meta.icon
    ? <img className="provider-mark" data-provider={meta.id} style={{ width: size, height: size }} src={meta.icon} alt="" />
    : <span className="provider-mark provider-mark-fallback" style={{ width: size, height: size }} aria-hidden="true">{meta.name.slice(0, 2).toUpperCase()}</span>;
}

// MARK: - Overview

function Overview({ state, onSelect, onOpen }) {
  const summary = buildOverviewSummary(state.providers);
  const today = buildTodayUsage(state.dailyUsageHistory);
  const risk = summary.riskNotes;
  return (
    <section className="content-section overview-section">
      <div className="overview-summary">
        <MetricCard
          label={tr("Lowest remaining quota")}
          value={summary.tightest ? formatPercent(summary.tightest.remaining) : "—"}
          valueTone={summary.risk}
          caption={summary.risk ? trKey(`risk.badge.${summary.risk}`, [], summary.risk.toUpperCase()) : tr("Unknown")}
          captionTone={summary.risk || "muted"}
        />
        <MetricCard
          label={tr("Today's Tokens")}
          value={today?.totalTokens ? compactNumber(today.totalTokens) : "—"}
          caption={tr(state.localUsage?.source || "Waiting for local history")}
        />
        <MetricCard
          label={tr("Today's Est. Cost")}
          value={Number.isFinite(today?.totalCost) ? formatMoney(today.totalCost) : "—"}
          caption={tr(today?.totalTokens && !Number.isFinite(today?.totalCost) ? "Price unavailable" : "API list-price estimate")}
          captionTone={today?.totalTokens && !Number.isFinite(today?.totalCost) ? "warning" : undefined}
        />
        <MetricCard
          label={tr(risk.projectedRunOutAt ? "Projected runway" : "Quota sustainability")}
          value={risk.projectedRunOutAt ? durationUntil(risk.projectedRunOutAt) : summary.risk ? tr("Lasts to reset") : "—"}
          valueTone={risk.projectedRunOutAt ? "medium" : undefined}
          caption={risk.projectedRunOutAt
            ? trKey("overview.kpi.window_before_reset", [risk.window.providerName, windowName(risk.window.windowMinutes)])
            : tr("At the current window's average pace")}
          captionTone={risk.projectedRunOutAt ? "medium" : summary.risk ? "low" : "muted"}
        />
      </div>
      <div className="overview-grid">
        <UsageCostCard state={state} today={today} onManage={() => onSelect("dataSources")} />
        <OfficialQuota state={state} today={today} risk={summary.risk} />
        <TrendingCard state={state} onOpen={onOpen} />
        <RiskNotes risk={risk} />
      </div>
      <AIFeed state={state} onOpen={onOpen} />
    </section>
  );
}

function MetricCard({ label, value, caption, valueTone, captionTone }) {
  return (
    <article className="metric-card">
      <span className="metric-label">{label}</span>
      <strong className={`metric-value ${valueTone ? `tone-${valueTone}` : ""}`}>{value}</strong>
      {caption && <span className={`metric-caption ${captionTone ? `tone-${captionTone}` : ""}`}>{caption}</span>}
    </article>
  );
}

function UsageCostCard({ state, today, onManage }) {
  const hasEntries = Boolean(today?.entries?.length);
  let rotation = 0;
  const stops = today?.totalTokens > 0
    ? today.entries.flatMap((entry) => {
      const start = rotation;
      rotation += Number.isFinite(today.totalCost) && today.totalCost > 0
        ? entry.costShare
        : entry.tokens / today.totalTokens * 100;
      const color = providerPresentation(entry.id).color;
      return [`${color} ${start}%`, `${color} ${rotation}%`];
    }).join(", ")
    : "var(--track) 0 100%";
  return (
    <section className="dashboard-panel usage-cost-card">
      <PanelHeader title={tr("Today's Usage & Cost")} subtitle={`${tr("By provider")} · ${tr(state.localUsage?.source || "local ccusage")}`} />
      {hasEntries ? (
        <>
          <div className="usage-composition">
            <div className="donut" style={{ background: `conic-gradient(${stops})` }}>
              <div>
                <strong>{Number.isFinite(today.totalCost) ? formatMoney(today.totalCost) : "—"}</strong>
                <span>{tr(Number.isFinite(today.totalCost) ? "Est. today" : "Price unavailable")}</span>
              </div>
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
          <p className="panel-source">{trKey("usage.snapshot_note")} {tr("Captured %1$@ from %2$@.", [formatClock(today.capturedAt), tr(state.localUsage?.source || "this PC")])}</p>
        </>
      ) : (
        <EmptyState
          icon={PieIcon}
          title={tr(state.localUsage?.error ? "Local usage could not be read" : state.dailyUsageHistory ? "No local usage today" : "No local usage history yet")}
          message={state.localUsage?.error || (state.dailyUsageHistory
            ? "This card fills in after a supported coding agent records usage on this PC or a paired Mac."
            : "Built-in ccusage reads local agent logs automatically; pairing a Mac is optional.")}
          action={<button className="inline-action" onClick={onManage}>{tr("View data sources")}</button>}
        />
      )}
    </section>
  );
}

function OfficialQuota({ state, today, risk }) {
  const ranked = rankOfficialQuotaProviders(state.providers, today);
  return (
    <section className="dashboard-panel official-quota">
      <PanelHeader
        title={tr("Official Quota")}
        subtitle={tr("Tightest windows of your most-used providers")}
        trailing={<Badge text="LIVE" tone="codex" />}
      />
      {ranked.length ? (
        <>
          <div className="official-quota-rows">
            {ranked.map((id) => (
              <OfficialQuotaRow key={id} id={id} provider={state.providers.find((item) => item.providerID === id)} />
            ))}
          </div>
          <div className="risk-footer">
            <span>{tr("Risk level")}</span>
            <RiskBadge level={risk} />
          </div>
        </>
      ) : (
        <EmptyState
          icon={GaugeIcon}
          title={tr("Reading official quota")}
          message={tr("Server-side quota snapshots for Claude and Codex will appear here automatically.")}
        />
      )}
    </section>
  );
}

/// A provider's selected account-level window as a mini progress summary —
/// the Mac's OfficialQuotaRow.
function OfficialQuotaRow({ id, provider }) {
  const meta = providerPresentation(id);
  const window = summaryWindow(provider);
  if (!window) return null;
  const remaining = Math.min(100, Math.max(0, 100 - window.usedPercent));
  return (
    <article className="official-quota-row">
      <div className="official-quota-head">
        <ProviderMark meta={meta} size={18} />
        <h3>{meta.name}</h3>
        <strong>{formatPercent(remaining)}</strong>
      </div>
      <SegmentBar remaining={remaining} color={meta.color} height={5} />
      <div className="official-quota-meta">
        <span>{windowTitle(window.windowMinutes)}</span>
        <span>{resetDescription(window.resetsAt)}</span>
      </div>
    </article>
  );
}

function TrendingCard({ state, onOpen }) {
  const posts = topStories(state.trending || []);
  return (
    <section className="dashboard-panel trending-card">
      <PanelHeader title={tr("Trending")} subtitle={tr("What matters most right now")} trailing={<Badge text="HOT" tone="cyan" />} />
      {posts.length ? (
        <>
          <div className="trending-list">
            {posts.map((post, index) => <TrendingRow key={post.id} post={post} rank={index + 1} onOpen={onOpen} />)}
          </div>
          <p className="panel-source">{tr("Public TokenRemain feed")}{state.feedError ? ` · ${tr("Cached")} (${state.feedError})` : ""}</p>
        </>
      ) : (
        <EmptyState
          icon={RadioIcon}
          title={state.feedLoading ? "Catching trending updates…" : state.feedError ? "Trending is temporarily unavailable" : "Nothing trending right now"}
          message={state.feedError || "The public feed has no current stories."}
        />
      )}
    </section>
  );
}

/// Rank 1 keeps the hot cyan accent and glow; rank 2 is quieter violet.
/// Priority-specific feed semantics override the hue, exactly like the Mac.
function TrendingRow({ post, rank, onOpen }) {
  const accent = feedAccent(post.priority, rank === 1 ? CYAN : VIOLET);
  const style = {
    "--trend-accent": accent,
    background: hexAlpha(accent, rank === 1 ? 0.13 : 0.08),
    borderColor: hexAlpha(accent, rank === 1 ? 0.55 : 0.30),
    boxShadow: rank === 1 ? `0 0 9px ${hexAlpha(accent, 0.28)}` : undefined,
  };
  return (
    <button className="trend-row" style={style} onClick={() => onOpen(post.url)}>
      <div className="trend-meta">
        <strong style={{ color: accent }}>{rank === 1 ? <FlameIcon /> : <BoltIcon />}#{rank}</strong>
        <b>{post.displayName}</b>
        <time>{relativeAge(post.publishedAt)}</time>
        <span className="open-arrow"><ArrowUpRightIcon /></span>
      </div>
      <p>{post.text}</p>
      <div className="trend-metrics">
        <span><ReplyIcon />{compactNumber(post.metrics.replies)}</span>
        <span><RepostIcon />{compactNumber(post.metrics.reposts)}</span>
        <span><HeartIcon />{compactNumber(post.metrics.likes)}</span>
      </div>
    </button>
  );
}

function RiskNotes({ risk }) {
  const summary = risk.projectedRunOutAt && risk.window
    ? trKey("risk.summary.projected_runout", [risk.window.providerName, windowName(risk.window.windowMinutes), durationUntil(risk.projectedRunOutAt)])
    : trKey(`risk.summary.${risk.level || "unknown"}`, [], risk.summary);
  return (
    <section className="dashboard-panel risk-notes">
      <PanelHeader title={tr("Risk Notes")} subtitle={tr("Based on the tightest quota window")} />
      {risk.window ? (
        <>
          <div className="risk-headline">
            <RiskBadge level={risk.level} />
            <strong>{tr(risk.headline)}</strong>
          </div>
          <p className="risk-summary">{summary}</p>
          <div className="risk-details">
            <Divider />
            <InfoRow label={tr("Tightest window")} value={`${risk.window.providerName} · ${windowName(risk.window.windowMinutes)}`} />
            <InfoRow label={tr("Remaining quota")} value={formatPercent(risk.window.remaining)} tone={risk.level} />
            {risk.projectedRunOutAt && <InfoRow label={tr("Projected depletion")} value={durationUntil(risk.projectedRunOutAt)} tone="medium" />}
            {risk.window.resetsAt && <InfoRow label={tr("Projected reset")} value={resetDescription(risk.window.resetsAt)} />}
          </div>
        </>
      ) : (
        <EmptyState
          icon={GaugeIcon}
          title="Waiting for official quota"
          message="No official quota snapshot yet. TokenRemain will retry automatically."
        />
      )}
    </section>
  );
}

// MARK: - AI Feed

function AIFeed({ state, onOpen }) {
  const curated = curateForDisplay(state.trending || []);
  const important = selectImportantForDisplay(curated);
  const regular = morePosts(curated);
  return (
    <div className="ai-feed">
      <SectionTitleHeader
        title={tr("AI Feed")}
        subtitle={tr("Curated updates directly relevant to your quota and workflow")}
        trailing={state.feedUpdatedAt ? trKey("common.updated_at", [formatClockSeconds(state.feedUpdatedAt)]) : undefined}
      />
      {state.feedError && (
        <div className="settings-card feed-unavailable">
          <AlertIcon />The curated feed can't update right now; the app will retry in the background.
        </div>
      )}
      {important.length > 0 && (
        <FeedGroup title={tr("Important")} subtitle={tr("Quota, pricing, product launches, and service status first")} posts={important} onOpen={onOpen} />
      )}
      {curated.length === 0 && !state.feedError && (
        <div className="settings-card">
          <EmptyState
            icon={RadioIcon}
            title={state.feedLoading ? "Syncing curated updates" : "No important updates"}
            message={state.feedLoading
              ? "Filtering for what directly affects your quota and workflow."
              : "New items worth your attention will appear here automatically."}
          />
        </div>
      )}
      {regular.length > 0 && (
        <FeedGroup title={tr("More worth watching")} subtitle={tr("Ranked by relevance, recency, and engagement quality")} posts={regular} onOpen={onOpen} />
      )}
    </div>
  );
}

function FeedGroup({ title, subtitle, posts, onOpen }) {
  return (
    <div className="feed-group">
      <PanelHeader title={title} subtitle={subtitle} />
      <div className="feed-list">
        {posts.map((post) => <FeedPostCard key={post.id} post={post} onOpen={onOpen} />)}
      </div>
    </div>
  );
}

function FeedPostCard({ post, onOpen }) {
  const prioritized = post.priority !== "normal";
  const accent = feedAccent(post.priority, VIOLET);
  const avatarColor = ["claudeai", "anthropicai"].includes(post.username.toLowerCase())
    ? providerMeta("claude").color
    : ["openai", "sama"].includes(post.username.toLowerCase())
      ? providerMeta("codex").color
      : VIOLET;
  const style = prioritized
    ? { borderColor: hexAlpha(accent, 0.8), boxShadow: `0 0 5px ${hexAlpha(accent, 0.11)}` }
    : undefined;
  return (
    <button className="feed-post" style={style} onClick={() => onOpen(post.url)}>
      {prioritized && <span className="priority-edge" style={{ background: hexAlpha(accent, 0.82) }} aria-hidden="true" />}
      <div className="feed-post-head">
        <span className="feed-avatar" style={{ background: hexAlpha(avatarColor, 0.18), color: avatarColor }}>
          {initials(post.displayName, post.username)}
        </span>
        <span className="feed-author">
          <span className="feed-names"><strong>{post.displayName}</strong><i>@{post.username}</i></span>
          <time>{relativeAge(post.publishedAt)}</time>
        </span>
        {prioritized && (
          <span className="priority-badge" style={{ color: accent, borderColor: hexAlpha(accent, 0.52) }}>
            {post.priority === "token_reset" ? <GaugeIcon /> : <BoltIcon />}{tr(priorityTitle(post.priority))}
          </span>
        )}
        <span className="open-arrow"><ArrowUpRightIcon /></span>
      </div>
      <p>{post.text}</p>
      <div className="feed-metrics">
        <span><ReplyIcon />{compactNumber(post.metrics.replies)}</span>
        <span><RepostIcon />{compactNumber(post.metrics.reposts)}</span>
        <span><HeartIcon />{compactNumber(post.metrics.likes)}</span>
        <span className="view-link">{tr("View on X")}</span>
      </div>
    </button>
  );
}

// MARK: - Limits

function Limits({ state, action }) {
  const providerIDs = state.enabledProviders || [];
  const hiddenIDs = (state.providerCatalog || []).map((provider) => provider.id).filter((id) => !providerIDs.includes(id));
  const [order, setOrder] = usePersistentOrder(providerIDs, LIMITS_ORDER_KEY);
  const showProvider = (id) => action(() => api.setProviderEnabled(id, true));
  const hideProvider = (id) => action(() => api.setProviderEnabled(id, false));
  return (
    <section className="content-section limits-section">
      <div className="limits-toolbar">
        <span>{tr("%1$d apps shown · drag cards to reorder", [providerIDs.length])}</span>
        <ProviderAddMenu
          providerIDs={hiddenIDs}
          providers={state.providers}
          catalog={state.providerCatalog}
          onAdd={showProvider}
        />
      </div>
      <DirectReorderGrid
        className="quota-grid"
        order={normalizeOrder(order, providerIDs)}
        onOrderChange={setOrder}
        renderItem={(id) => (
          <QuotaCard
            provider={state.providers.find((item) => item.providerID === id)}
            notice={state.notices[id]}
            id={id}
            canRemove
            onRemove={() => hideProvider(id)}
          />
        )}
      />
      <div className="settings-card about-windows">
        <PanelHeader title={tr("About quota windows")} />
        <p>{tr("Percentages show the remaining quota within a window; usage-based services show the remaining monetary balance directly. Windows come from each provider's servers: Claude, Codex, and Z.ai usually include a 5-hour session window and a 7-day window; Cursor uses a monthly billing window; Grok uses a weekly pool.")}</p>
        <p>{tr("Use Add app and the minus control to choose which Windows-local adapters TokenRemain monitors. Automatic adapters reuse the app's existing sign-in; credential adapters are configured locally in Data Sources.")}</p>
        <p>{tr("Mac Direct Sync is fallback-only: it fills a provider only when this PC has no local snapshot, and never replaces a Windows-local reading.")}</p>
        <p>{tr("Drag a full card to reorder it — Alt plus arrow keys also works — and both order and visibility are remembered on this PC.")}</p>
        <p>{tr("Reset times come from official snapshots; when a window has no reset time yet, it shows \"Waiting for the official reset time\".")}</p>
      </div>
    </section>
  );
}

/// Full provider quota card matching the Mac's QuotaCard: brand row + plan
/// pill, then one row per official window with meter, reset, and pace.
function ProviderAddMenu({ providerIDs, providers, catalog, onAdd }) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const dismiss = (event) => {
      if (!rootRef.current?.contains(event.target)) setOpen(false);
    };
    document.addEventListener("pointerdown", dismiss, true);
    return () => document.removeEventListener("pointerdown", dismiss, true);
  }, [open]);
  return (
    <div className="provider-add" ref={rootRef}>
      <button
        className="secondary provider-add-trigger"
        onClick={() => setOpen((value) => !value)}
        aria-haspopup="menu"
        aria-expanded={open}
        disabled={!providerIDs.length}
      >
        <PlusIcon />{tr("Add app")}
      </button>
      {open && (
        <div className="provider-add-popover" role="menu" aria-label={tr("Add an app to Limits")}>
          {providerIDs.map((id) => {
            const meta = providerPresentation(id);
            const available = providers.some((provider) => provider.providerID === id);
            const definition = catalog?.find((provider) => provider.id === id);
            return (
              <button key={id} role="menuitem" onClick={() => { onAdd(id); setOpen(false); }}>
                <ProviderMark meta={meta} size={18} />
                <span><strong>{meta.name}</strong><small>{available ? tr("Windows-local quota available") : definition?.localSessionFirst ? tr("Uses %1$@ first; %2$@ is optional", [definition.product, definition.credentialKind]) : definition?.access === "local-credential" ? tr("Configure %1$@ locally", [definition.credentialKind]) : definition?.installed ? tr("Detected on this PC") : tr("Supported Windows-local adapter")}</small></span>
                <PlusIcon />
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

function QuotaCard({ provider, notice, id, canRemove, onRemove }) {
  const meta = providerPresentation(id);
  const windows = provider?.windows || [];
  return (
    <article className="provider-card" title={tr("Drag the card to reorder")}>
      <div className="provider-card-head">
        <ProviderMark meta={meta} />
        <h3>{meta.name}</h3>
        {windows.length > 0 && notice && (
          <span className="notice-pill" title={notice}><AlertIcon />{tr("Refresh issue")}</span>
        )}
        {provider?.planName && <Badge text={provider.planName} tone="plan" />}
        <button
          className="quota-remove"
          onClick={onRemove}
          disabled={!canRemove}
          aria-label={tr("Remove %1$@ from Limits", [meta.name])}
          title={canRemove ? tr("Remove %1$@ from Limits", [meta.name]) : tr("At least one app must remain")}
        ><MinusIcon /></button>
      </div>
      {windows.length ? (
        <>
          {windows.map((window, index) => (
            <React.Fragment key={`${window.windowMinutes}-${index}`}>
              {index > 0 && <Divider />}
              <QuotaWindowRow window={window} color={meta.color} />
            </React.Fragment>
          ))}
          {(provider.scopedWindows || []).map((scope) => (
            <React.Fragment key={scope.scopeID}>
              <Divider />
              <QuotaWindowRow window={scope.window} color={meta.color} scopeName={scope.displayName} />
            </React.Fragment>
          ))}
          <CaptureFreshness capturedAt={provider.capturedAt} />
        </>
      ) : (
        <div className="empty-provider">
          <MoonIcon />
          <span>{notice || tr("%1$@ is waiting for its Windows-local sign-in or credential.", [meta.name])}</span>
        </div>
      )}
    </article>
  );
}

function QuotaWindowRow({ window, color, scopeName }) {
  const remaining = Math.min(100, Math.max(0, 100 - window.usedPercent));
  const pace = usagePace(window);
  const title = scopeName ? `${scopeName} · ${windowTitle(window.windowMinutes)}` : windowTitle(window.windowMinutes);
  const remainingText = window.remainingBalance
    ? tr("%1$@ remaining", [formatBalance(window.remainingBalance)])
    : tr("%1$@ remaining", [formatPercent(remaining)]);
  return (
    <div className="quota-window">
      <div className="quota-window-head">
        <span className="quota-window-title">{title}</span>
        {pace?.status === "deficit" && <AlertIcon className="pace-alert" title={tr("Current usage is ahead of pace")} />}
        <strong>{remainingText}</strong>
      </div>
      <SegmentBar remaining={remaining} color={color} />
      <div className="quota-reset"><ResetIcon />{resetDescription(window.resetsAt)}</div>
      {pace && <QuotaPaceRow pace={pace} />}
    </div>
  );
}

/// "On track / x% reserve / x% ahead" plus whether the window survives to its
/// reset — the Mac's QuotaPaceRow with the same semantic tinting.
function QuotaPaceRow({ pace }) {
  const tone = pace.status === "reserve" ? "success"
    : pace.status === "deficit" ? (pace.willLastUntilReset ? "warning" : "danger")
      : "secondary";
  const label = pace.status === "onTrack" ? tr("On track")
    : pace.status === "reserve" ? tr("%1$@ reserve", [formatPercent(Math.abs(pace.deltaPercent))])
      : tr("%1$@ ahead", [formatPercent(Math.abs(pace.deltaPercent))]);
  const outcome = pace.willLastUntilReset
    ? tr("Lasts until reset")
    : pace.estimatedRunOutAt
      ? tr("Projected to run out in %1$@", [durationUntil(pace.estimatedRunOutAt)])
      : tr("Projected to run out early");
  return (
    <div className={`quota-pace tone-${tone}`}>
      {pace.willLastUntilReset ? <CheckCircleIcon /> : <AlertIcon />}
      <span>{label}</span>
      <em>{outcome}</em>
    </div>
  );
}

function CaptureFreshness({ capturedAt }) {
  if (!Number.isFinite(capturedAt)) return null;
  const stale = isStaleCapture(capturedAt);
  return (
    <div className={`capture-freshness ${stale ? "tone-warning" : ""}`}>
      {stale ? <AlertIcon /> : <CheckCircleIcon />}
      {freshnessDescription(capturedAt)}
    </div>
  );
}

// MARK: - Trends

function TrendSegmentedControl({ label, options, value, onChange }) {
  return (
    <div className="trend-segmented" role="group" aria-label={label}>
      {options.map((option) => {
        const normalized = typeof option === "object" ? option : { value: option, label: trKey("trends.range_days", [option]) };
        return (
          <button
            key={normalized.value}
            className={value === normalized.value ? "selected" : ""}
            aria-pressed={value === normalized.value}
            onClick={() => onChange(normalized.value)}
          >
            {normalized.label}
          </button>
        );
      })}
    </div>
  );
}

function trendValue(value, metric) {
  return metric === "cost" ? formatMoney(value) : `${compactNumber(Math.round(value))} tokens`;
}

function numericDayLabel(value) {
  const date = new Date(`${value}T00:00:00Z`);
  return `${date.getUTCMonth() + 1}/${date.getUTCDate()}`;
}

function DailyUsageTrendCard({ history }) {
  const [range, setRange] = useState(14);
  const [metric, setMetric] = useState("tokens");
  const [activeIndex, setActiveIndex] = useState();
  const providerIDs = usageProviderIDs(history);
  const model = usageTrendModel(history, { range, metric, providerIDs });
  const fresh = history?.capturedAt && Date.now() - history.capturedAt < 30 * 60_000;
  const stride = model.days.length <= 7 ? 1 : model.days.length <= 14 ? 2 : 5;
  const ticks = [1, 0.75, 0.5, 0.25];
  const activeDay = Number.isInteger(activeIndex) ? model.days[activeIndex] : undefined;

  return (
    <section className="dashboard-panel trend-history-panel">
      <PanelHeader
        title={tr("Daily Usage Trend")}
        subtitle={tr("Detected apps stacked · local and synced aggregate")}
        trailing={fresh ? <Badge text="LIVE" tone="codex" /> : undefined}
      />
      <div className="trend-card-controls">
        <div className="trend-series-legend" aria-label={tr("Visible providers")}>
          {providerIDs.map((id) => {
            const meta = providerPresentation(id);
            return (
              <span key={id}>
                <ProviderMark meta={meta} size={13} />
                <b>{meta.name}</b>
                <i style={{ background: meta.color }} />
              </span>
            );
          })}
        </div>
        <div className="trend-control-groups">
          <TrendSegmentedControl label={tr("History range")} options={TREND_RANGES} value={range} onChange={setRange} />
          <TrendSegmentedControl
            label={tr("Metric")}
            options={[{ value: "tokens", label: tr("Tokens") }, { value: "cost", label: tr("Cost") }]}
            value={metric}
            onChange={setMetric}
          />
        </div>
      </div>

      <div className="trend-total-row">
        <span>{tr("Total trend")}</span>
        <svg viewBox="0 0 100 20" preserveAspectRatio="none" aria-hidden="true">
          <polyline points={linePoints(model.days.map((day) => day.total))} />
        </svg>
      </div>

      <div className="trend-chart-detailed" onMouseLeave={() => setActiveIndex(undefined)}>
        <div className="trend-y-axis" aria-hidden="true">
          {ticks.map((fraction) => (
            <span key={fraction} style={{ bottom: `${fraction * 100}%` }}>{compactAxisValue(model.maximum * fraction, metric)}</span>
          ))}
        </div>
        <div className="trend-plot">
          {ticks.map((fraction) => <i className="trend-gridline" key={fraction} style={{ bottom: `${fraction * 100}%` }} />)}
          <i className="trend-baseline" />
          <div className={`trend-columns range-${range}`} style={{ gridTemplateColumns: `repeat(${Math.max(1, model.days.length)}, minmax(0, 1fr))` }}>
            {model.days.map((day, index) => {
              const dimmed = activeDay && index !== activeIndex;
              const labelVisible = (model.days.length - 1 - index) % stride === 0;
              const aria = `${formatDayLabel(day.day)} · ${providerIDs.map((id) => `${providerMeta(id).name} ${trendValue(day.values[id], metric)}`).join(" · ")} · Total ${trendValue(day.total, metric)}`;
              return (
                <button
                  className={`trend-day-column ${dimmed ? "dimmed" : ""}`}
                  key={day.day}
                  aria-label={aria}
                  onMouseEnter={() => setActiveIndex(index)}
                  onFocus={() => setActiveIndex(index)}
                  onBlur={() => setActiveIndex(undefined)}
                >
                  <span className="trend-stack">
                    {providerIDs.map((id) => day.values[id] > 0 && (
                      <i
                        key={id}
                        style={{ height: `${day.values[id] / model.maximum * 100}%`, background: providerMeta(id).color }}
                      />
                    ))}
                  </span>
                  <span className="trend-day-label">{labelVisible ? numericDayLabel(day.day) : ""}</span>
                </button>
              );
            })}
          </div>
          {activeDay && (
            <div className="trend-tooltip" style={{ left: `${Math.min(92, Math.max(8, (activeIndex + 0.5) / model.days.length * 100))}%` }}>
              <strong>{formatDayLabel(activeDay.day)}</strong>
              {providerIDs.map((id) => (
                <span key={id}><i style={{ background: providerMeta(id).color }} />{providerMeta(id).name}<b>{trendValue(activeDay.values[id], metric)}</b></span>
              ))}
              <span className="trend-tooltip-total">{tr("Total")}<b>{trendValue(activeDay.total, metric)}</b></span>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}

function QuotaSparkline({ row, color }) {
  const latestPoint = row.points.split(" ").at(-1)?.split(",").map(Number);
  const latestPosition = latestPoint && latestPoint.every(Number.isFinite)
    ? {
        "--quota-latest-x": `${latestPoint[0]}%`,
        "--quota-latest-y": `${latestPoint[1] / 38 * 100}%`,
        "--quota-accent": color,
      }
    : undefined;
  return (
    <div className={`quota-sparkline-frame ${row.samples.length > 1 ? "has-trend" : "is-collecting"}`} style={latestPosition}>
      <svg className="quota-sparkline" viewBox="0 0 100 38" preserveAspectRatio="none" aria-hidden="true">
        <line x1="0" x2="100" y1="0.5" y2="0.5" />
        <line x1="0" x2="100" y1="19" y2="19" />
        <line x1="0" x2="100" y1="37.5" y2="37.5" />
        {row.samples.length > 1 && <polyline className="quota-sparkline-line" points={row.points} style={{ stroke: color }} />}
      </svg>
      {latestPosition && <i className="quota-sparkline-latest" aria-hidden="true" />}
      {row.samples.length === 1 && <span className="quota-sparkline-status">{tr("1 snapshot · collecting")}</span>}
    </div>
  );
}

function QuotaConsumptionTrendCard({ state }) {
  const [range, setRange] = useState(7);
  const providerIDs = state.providers.map((provider) => provider.providerID);
  const [order] = usePersistentOrder(providerIDs, LIMITS_ORDER_KEY);
  const providers = normalizeOrder(order, providerIDs).flatMap((id) => {
    const provider = state.providers.find((item) => item.providerID === id);
    return provider ? [provider] : [];
  });
  const rows = quotaTrendRows(state.quotaUsageHistory, providers, range);
  return (
    <section className="dashboard-panel quota-trend-panel">
      <PanelHeader
        title={tr("Quota Consumption Trend")}
        subtitle={tr("Primary quota window by app · local snapshots")}
        trailing={<TrendSegmentedControl label={tr("Quota history range")} options={TREND_RANGES} value={range} onChange={setRange} />}
      />
      {rows.length ? (
        <div className="quota-trend-table">
          <div className="quota-trend-header" aria-hidden="true">
            <span>{tr("App")}</span><span>{tr("Window")}</span><span>{tr("Used")}</span><span>{tr("Trend")}</span>
          </div>
          {rows.map((row) => {
            const meta = providerPresentation(row.providerID);
            return (
              <div
                className="quota-trend-row"
                key={row.providerID}
                aria-label={`${meta.name}, ${windowName(row.latest.windowMinutes)} window, ${formatPercent(row.latest.usedPercent)} used, ${row.samples.length > 1 ? `${row.samples.length} snapshots in trend` : "trend history is collecting"}`}
              >
                <span className="quota-trend-provider"><ProviderMark meta={meta} size={18} /><b>{meta.name}</b></span>
                <span>{windowName(row.latest.windowMinutes)}</span>
                <strong style={{ color: meta.color }}>{formatPercent(row.latest.usedPercent)}</strong>
                <QuotaSparkline row={row} color={meta.color} />
              </div>
            );
          })}
        </div>
      ) : (
        <EmptyState
          icon={TrendsIcon}
          title={tr("Quota trend is accumulating")}
          message={tr("TokenRemain starts recording after a successful quota refresh. Every connected provider will appear automatically; past data cannot be backfilled.")}
        />
      )}
    </section>
  );
}

function Trends({ state }) {
  const days = (state.dailyUsageHistory?.days || []).slice(-30);
  const today = buildTodayUsage(state.dailyUsageHistory);
  return (
    <section className="content-section trends-section">
      {days.length >= 2 ? <DailyUsageTrendCard history={state.dailyUsageHistory} /> : (
        <section className="dashboard-panel trend-history-panel">
          <EmptyState
            icon={TrendsIcon}
            title={tr("Trend data is accumulating day by day")}
            message={tr("The daily usage trend needs at least two days of local history. As you use supported coding apps, built-in ccusage accumulates tokens and cost per day; once there is enough, a real stacked bar trend appears here automatically.")}
          />
        </section>
      )}
      <QuotaConsumptionTrendCard state={state} />
      <div className="trends-summary-grid">
        <div className="settings-card">
          <PanelHeader title={tr("Today's Snapshot")} subtitle={`${tr("Where the trend starts")} · ${tr(state.localUsage?.source || "local ccusage")}`} />
          {today?.totalTokens ? (
            <>
              <InfoRow label={tr("Today's Tokens")} value={compactNumber(today.totalTokens)} />
              <InfoRow label={tr("Today's Est. Cost")} value={Number.isFinite(today.totalCost) ? formatMoney(today.totalCost) : tr("Price unavailable")} />
              <Divider />
              {today.entries.map((entry) => (
                <InfoRow key={entry.id} label={entry.displayName} value={`${compactNumber(entry.tokens)} · ${entry.cost > 0 ? formatMoney(entry.cost) : "—"}`} />
              ))}
            </>
          ) : (
            <p className="quiet-note">{tr("No supported coding-agent usage recorded today yet.")}</p>
          )}
        </div>
        <div className="settings-card">
          <PanelHeader title={tr("History coverage")} subtitle={tr("Local aggregate, with optional Mac contribution")} />
          <InfoRow label={tr("Recorded days")} value={String(days.length)} />
          <InfoRow label={tr("Oldest day")} value={days[0]?.day || tr("Waiting")} />
          <InfoRow label={tr("Latest day")} value={days.at(-1)?.day || tr("Waiting")} />
          <InfoRow label={tr("Quota history")} value={state.quotaUsageHistory?.samples?.length ? tr("%1$d local snapshots", [state.quotaUsageHistory.samples.length]) : tr("Accumulating")} />
        </div>
      </div>
    </section>
  );
}

// MARK: - Devices

function Devices({ state, action }) {
  const [macURL, setMacURL] = useState(state.sync.macURL || "http://mac.local:47831");
  const [pairingCode, setPairingCode] = useState("");
  const [busy, setBusy] = useState(false);
  const activeSources = [
    ...(state.localProviders || []).map((provider) => providerMeta(provider.providerID).name),
    ...(state.sync.paired ? ["Mac Direct Sync"] : []),
  ];
  async function pair(event) {
    event.preventDefault(); setBusy(true);
    await action(() => api.pair({ macURL, pairingCode }));
    setPairingCode(""); setBusy(false);
  }
  return (
    <section className="content-section devices-section">
      <div className="settings-card">
        <PanelHeader
          title={tr("This Windows PC")}
          subtitle={tr("The device currently monitored")}
          trailing={<StatusDotLabel tone="success" text={tr("Monitoring")} />}
        />
        <InfoRow label={tr("Device name")} value={state.deviceName} />
        <InfoRow label={tr("Active data sources")} value={activeSources.length ? activeSources.join(" · ") : tr("None")} />
        {state.lastUpdatedAt && <InfoRow label={tr("Last updated")} value={formatClock(state.lastUpdatedAt)} />}
        <InfoRow label={tr("Source ID")} value={state.sourceInstanceID.slice(0, 6).toUpperCase()} />
      </div>
      <div className="settings-card">
        <PanelHeader
          title={tr("Mac direct sync")}
          subtitle={tr("Quota snapshots and optional daily aggregates; provider credentials never leave either device.")}
          trailing={<StatusDotLabel tone={state.sync.paired ? "success" : "muted"} text={tr(state.sync.paired ? "Paired" : "Not paired")} />}
        />
        {state.sync.paired ? (
          <div className="paired-details">
            <InfoRow label="Mac" value={state.sync.deviceName || "Mac"} />
            <InfoRow label={tr("Address")} value={state.sync.macURL} />
            <InfoRow label={tr("Encryption")} value={state.sync.encryption} />
            <InfoRow label={tr("Last sync")} value={state.sync.lastSyncAt ? timeAgo(state.sync.lastSyncAt) : state.sync.error || tr("Waiting")} />
            <button className="secondary danger" onClick={() => action(api.disconnect)}>{tr("Disconnect")}</button>
          </div>
        ) : (
          <form className="pair-form" onSubmit={pair}>
            <label>{tr("Mac address")}<input value={macURL} onChange={(event) => setMacURL(event.target.value)} placeholder="http://mac.local:47831" /></label>
            <label>{tr("One-time pairing code")}<input type="password" autoComplete="off" value={pairingCode} onChange={(event) => setPairingCode(event.target.value)} placeholder={tr("Shown in TokenRemain on Mac")} /></label>
            <button className="primary" disabled={busy || !pairingCode.trim()}>{tr(busy ? "Pairing…" : "Pair Mac")}</button>
          </form>
        )}
      </div>
    </section>
  );
}

// MARK: - Data Sources

function DataSources({ state, action }) {
  const local = new Map((state.localProviders || []).map((provider) => [provider.providerID, provider]));
  const enabled = (state.providerCatalog || []).filter((provider) => provider.enabled);
  const remoteCount = state.sync.paired ? state.providers.filter((provider) => !local.has(provider.providerID)).length : 0;
  return (
    <section className="content-section data-sources-section">
      <div className="settings-card source-list">
        <PanelHeader
          title={tr("Windows-local providers")}
          subtitle={tr("Every enabled app is read on this PC first. Mac Direct Sync only fills a missing provider.")}
          trailing={<button className="secondary compact-button" onClick={() => action(api.rescanProviders)}><RefreshIcon />{tr("Scan apps")}</button>}
        />
        {enabled.length ? enabled.map((definition) => definition.access === "local-credential" ? (
          <CredentialSourceRow
            key={definition.id}
            definition={definition}
            provider={local.get(definition.id)}
            notice={state.notices[definition.id]}
            action={action}
          />
        ) : (
          <SourceHealthRow
            key={definition.id}
            iconID={definition.id}
            name={providerPresentation(definition.id).name}
            detail={state.notices[definition.id] || tr(local.has(definition.id) ? "Read from this app's existing Windows sign-in" : definition.detail)}
            healthy={local.has(definition.id) && !state.notices[definition.id]}
            capturedAt={local.get(definition.id)?.capturedAt}
            status={local.has(definition.id) ? "Local" : definition.installed ? "Detected" : "Not found"}
          />
        )) : <p className="quiet-note">{tr("No provider is enabled. Add one from Limits or scan this PC again.")}</p>}
      </div>
      <div className="settings-card source-list">
        <PanelHeader title={tr("Supporting sources")} subtitle={tr("Usage history, pricing, feed, and optional cross-device fallback.")} />
        <SourceHealthRow
          name={tr("Local ccusage")}
          detail={state.localUsage?.error || tr("Reads supported coding-agent logs on this PC; no separate ccusage install required")}
          healthy={Boolean(state.localUsage?.hasLocal) && !state.localUsage?.error}
          capturedAt={state.localUsage?.hasLocal ? state.localUsage.capturedAt : undefined}
        />
        <SourceHealthRow
          name={tr("Public model pricing")}
          detail={state.localUsage?.pricing?.error
            || (state.localUsage?.pricing?.modelCount
              ? tr("%1$d validated model prices · refreshes every %2$d hours", [state.localUsage.pricing.modelCount, state.localUsage.pricing.refreshIntervalHours])
              : tr("Using ccusage's embedded price table until the first public refresh"))}
          healthy={!state.localUsage?.pricing?.error || Boolean(state.localUsage?.pricing?.modelCount)}
          capturedAt={state.localUsage?.pricing?.capturedAt}
        />
        <SourceHealthRow
          name="Mac Direct Sync"
          detail={state.sync.error || (state.sync.paired ? tr("%1$d provider fallbacks; Windows-local snapshots always win", [remoteCount]) : tr("Optional fallback for providers missing on this PC, plus your Mac daily aggregate"))}
          healthy={state.sync.paired && !state.sync.error}
          capturedAt={state.sync.lastSyncAt}
          status={state.sync.paired ? "Fallback" : "Optional"}
        />
        <SourceHealthRow
          name={tr("Curated AI Feed")}
          detail={state.feedError || tr("Automatically curates quota, product-launch, and service-status updates in the background")}
          healthy={!state.feedError && Boolean(state.feedUpdatedAt || state.trending?.length)}
          capturedAt={state.feedUpdatedAt}
        />
      </div>
      <div className="settings-card">
        <PanelHeader title={tr("Privacy")} />
        <ul className="privacy-list">
          <li>{tr("App sign-ins are read-only. Manually supplied keys and Cookies are encrypted with Windows credential protection; none are synced.")}</li>
          <li>{tr("Built-in ccusage reads local agent logs offline; raw sessions, prompts, paths, and repository names never leave this PC.")}</li>
          <li>{tr("Only the complete public LiteLLM price table is downloaded. No observed model name, token count, or usage-derived query is sent.")}</li>
          <li>{tr("Direct Sync optionally exchanges AES-256-GCM encrypted quota snapshots and daily aggregates with your Mac, but remote quota is fallback-only.")}</li>
          <li>{tr("The curated AI feed syncs automatically via built-in policies; there are no accounts to pick or sources to manage.")}</li>
          <li>{tr("No CloudKit and no phone sync in this Windows build.")}</li>
        </ul>
      </div>
    </section>
  );
}

function CredentialSourceRow({ definition, provider, notice, action }) {
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const meta = providerPresentation(definition.id);
  async function save(event) {
    event.preventDefault();
    setBusy(true);
    await action(() => api.setProviderCredential(definition.id, value));
    setValue("");
    setBusy(false);
  }
  async function clear() {
    setBusy(true);
    await action(() => api.clearProviderCredential(definition.id));
    setValue("");
    setBusy(false);
  }
  return (
    <div className="source-row credential-source-row">
      <ProviderMark meta={meta} size={20} />
      <div>
        <strong>{meta.name}<span className="source-mode-pill">{definition.localSessionFirst ? tr("App session + %1$@", [definition.credentialKind]) : tr("Local %1$@", [definition.credentialKind])}</span></strong>
        <small>{notice || (provider ? (definition.localSessionFirst ? tr("Quota is being read from %1$@ or its local fallback", [definition.product]) : tr("Quota is being read with the credential protected on this PC")) : tr(definition.detail))}</small>
        <form className="credential-form" onSubmit={save}>
          <input type="password" autoComplete="off" value={value} onChange={(event) => setValue(event.target.value)} placeholder={definition.configured ? tr("Replace saved %1$@", [definition.credentialKind]) : tr("Paste %1$@", [definition.credentialKind])} />
          <button className="secondary" disabled={busy || !value.trim()}>{tr(busy ? "Saving…" : "Save locally")}</button>
          {definition.configured && <button type="button" className="secondary danger" disabled={busy} onClick={clear}>{tr("Clear")}</button>}
        </form>
      </div>
      <div className="source-status">
        <span className={provider && !notice ? "tone-success" : definition.configured ? "tone-warning" : "tone-muted"}>{tr(provider && !notice ? "Local" : definition.configured ? "Configured" : "Setup")}</span>
        {provider?.capturedAt && <time>{formatClock(provider.capturedAt)}</time>}
      </div>
    </div>
  );
}

function SourceHealthRow({ name, detail, healthy, capturedAt, iconID, status }) {
  return (
    <div className="source-row">
      {iconID ? <ProviderMark meta={providerPresentation(iconID)} size={20} /> : <span className={`source-dot ${healthy ? "tone-success" : "tone-warning"}`} aria-hidden="true" />}
      <div>
        <strong>{name}</strong>
        <small>{detail}</small>
      </div>
      <div className="source-status">
        <span className={healthy ? "tone-success" : "tone-warning"}>{tr(status || (healthy ? "Healthy" : "Needs attention"))}</span>
        {capturedAt && <time>{formatClock(capturedAt)}</time>}
      </div>
    </div>
  );
}

// MARK: - Settings

const SETTINGS_CATEGORIES = [
  { id: "general", title: "General", detail: "Startup, quick view, and floating shortcut", icon: SwitchIcon },
  { id: "refreshSync", title: "Refresh & Sync", detail: "Update cadence and private sync", icon: RefreshIcon },
  { id: "about", title: "About", detail: "Version, data, and app controls", icon: InfoIcon },
];

function Settings({ state, action, onSelect }) {
  const [category, setCategory] = useState("general");
  const selected = SETTINGS_CATEGORIES.find((item) => item.id === category);
  return (
    <section className="content-section settings-section">
      <div className="settings-tabs" role="tablist" aria-label={tr("Settings categories")}>
        {SETTINGS_CATEGORIES.map((item) => {
          const Icon = item.icon;
          return (
            <button
              key={item.id}
              role="tab"
              aria-selected={category === item.id}
              className={category === item.id ? "selected" : ""}
              onClick={() => setCategory(item.id)}
            >
              <Icon />{tr(item.title)}
            </button>
          );
        })}
      </div>
      <p className="settings-detail">{tr(selected.detail)}</p>
      {category === "general" && <GeneralSettings state={state} action={action} />}
      {category === "refreshSync" && <RefreshSyncSettings state={state} action={action} onSelect={onSelect} />}
      {category === "about" && <AboutSettings state={state} action={action} />}
    </section>
  );
}

function GeneralSettings({ state, action }) {
  const languages = languageOptions(state.systemLocale);
  return (
    <div className="settings-card">
      <PanelHeader title={tr("General")} />
      <div className="preference-row language-setting">
        <label className="preference-label" htmlFor="app-language">
          <strong>{tr("Language")}</strong>
          <span>{tr("Follow the Windows display language automatically, or choose a language for TokenRemain.")}</span>
        </label>
        <select
          id="app-language"
          className="language-select"
          value={state.languagePreference || SYSTEM_LANGUAGE}
          onChange={(event) => action(() => api.setLanguage(event.target.value))}
        >
          {languages.map((language) => <option key={language.value} value={language.value}>{language.label}</option>)}
        </select>
      </div>
      <Divider />
      <ToggleRow
        title={tr("Launch at login")}
        detail={tr("Start TokenRemain automatically when you sign in to Windows; it keeps monitoring from the tray.")}
        isOn={Boolean(state.launchAtLogin)}
        onChange={(value) => action(() => api.setLaunchAtLogin(value))}
      />
      <Divider />
      <ToggleRow
        title={tr("Floating shortcut")}
        detail={tr("Keep a small quota shortcut above other windows. Drag its grip to move it; click the quota to open Quick View.")}
        isOn={Boolean(state.floatingWidgetEnabled)}
        onChange={(value) => action(() => api.setFloatingWidgetEnabled(value))}
      />
      <Divider />
      <div className="preference-row quick-view-setting">
        <div className="preference-label">
          <strong>{tr("Quick View popup")}</strong>
          <span>{tr("Open the same compact popup as a tray-icon click. This is separate from the full Dashboard.")}</span>
        </div>
        <button className="secondary" onClick={() => action(api.openPopup)}><RadioIcon />{tr("Open now")}</button>
      </div>
      <Divider />
      <div className="preference-row">
        <div className="preference-label">
          <strong>{tr("Close button")}</strong>
          <span>{tr("Closing the window keeps TokenRemain running in the tray; quit from the tray menu or Settings › About.")}</span>
        </div>
      </div>
    </div>
  );
}

function RefreshSyncSettings({ state, action, onSelect }) {
  return (
    <>
      <div className="settings-card">
        <PanelHeader title={tr("Quota refresh interval")} />
        <div className="preference-row">
          <div className="preference-label">
            <span>{tr("Local CLI quotas, the Mac link, and the curated feed refresh together on a fixed cadence.")}</span>
          </div>
          <strong className="preference-value">{tr("Every minute")}</strong>
        </div>
        <Divider />
        <div className="refresh-now-row">
          <button className="secondary" onClick={() => action(api.refresh)} disabled={state.isRefreshing}>
            <RefreshIcon spinning={state.isRefreshing} />{tr(state.isRefreshing ? "Refreshing…" : "Refresh now")}
          </button>
        </div>
      </div>
      <div className="settings-card direct-sync-panel">
        <PanelHeader title={tr("Direct Sync")} subtitle={tr("Encrypted direct sync between your devices")} />
        <SyncStrip sync={state.sync} deviceName={state.deviceName} />
        <button className="manage-devices" onClick={() => onSelect("devices")}><DevicesIcon /><span>{tr("Manage devices")}</span><ChevronRightIcon /></button>
      </div>
    </>
  );
}

function AboutSettings({ state, action }) {
  return (
    <>
      <div className="settings-card">
        <PanelHeader title={tr("About")} />
        <InfoRow label={tr("Version")} value={`TokenRemain ${state.appVersion || ""}`.trim()} />
        <InfoRow label={tr("Data")} value={tr("Local-first · encrypted LAN sync with your Mac")} />
        <InfoRow label={tr("Credential access")} value={tr("Read-only local CLI files")} />
      </div>
      <div className="settings-card">
        <PanelHeader title={tr("Actions")} />
        <div className="actions-row">
          <button className="secondary" onClick={() => action(api.relaunch)}><RestartIcon />{tr("Restart TokenRemain")}</button>
          <button className="secondary danger" onClick={() => action(api.quit)}><PowerIcon />{tr("Quit")}</button>
        </div>
      </div>
    </>
  );
}

function ToggleRow({ title, detail, isOn, onChange }) {
  return (
    <div className="preference-row">
      <div className="preference-label">
        <strong>{title}</strong>
        <span>{detail}</span>
      </div>
      <button
        className={`switch ${isOn ? "on" : ""}`}
        role="switch"
        aria-checked={isOn}
        aria-label={title}
        onClick={() => onChange(!isOn)}
      >
        <span className="knob" />
      </button>
    </div>
  );
}

function SyncStrip({ sync, deviceName }) {
  return (
    <div className="sync-strip">
      <div><DevicesIcon /><span><strong>{deviceName}</strong><small>{tr("This PC")}</small></span></div>
      <div className={sync.paired ? "sync-link connected" : "sync-link"}><span /><LockIcon /><span /><small>{tr(sync.paired ? "Encrypted direct sync" : "Not paired")}</small></div>
      <div className="mac-end"><span><strong>{sync.deviceName || "Mac"}</strong><small>{sync.lastSyncAt ? tr("Last sync %1$@", [timeAgo(sync.lastSyncAt)]) : sync.error || tr("Open Devices to pair")}</small></span><DevicesIcon /></div>
    </div>
  );
}

// MARK: - Dev preview data

function createPreviewAPI() {
  const previewNow = Date.now();
  const previewParameters = new URLSearchParams(globalThis.location?.search || "");
  const previewDay = new Date(previewNow).toISOString().slice(0, 10);
  const previewHistoryDays = Array.from({ length: 30 }, (_, index) => {
    const day = new Date(previewNow - (29 - index) * 24 * 60 * 60_000).toISOString().slice(0, 10);
    const pulse = [0.72, 0.7, 1.06, 1.03, 1.62, 1.28, 1.21, 0.18, 0.87, 0.46, 0.84, 1.02, 0.72, 0.55, 0.88][index % 15];
    const claudeTokens = Math.round((13_000_000 + (index % 5) * 6_500_000) * pulse);
    const claudeCost = Number(((8.9 + (index % 5) * 4.2) * pulse).toFixed(2));
    const codexTokens = Math.round((92_000_000 + (index % 7) * 18_000_000) * pulse);
    const codexCost = Number(((64.5 + (index % 7) * 12.6) * pulse).toFixed(2));
    const geminiTokens = Math.round((4_800_000 + (index % 3) * 1_100_000) * pulse);
    const geminiCost = Number(((1.2 + (index % 3) * 0.25) * pulse).toFixed(2));
    return {
      day,
      agents: [
        { id: "codex", tokens: codexTokens, cost: codexCost, unpricedModels: [] },
        { id: "claude", tokens: claudeTokens, cost: claudeCost, unpricedModels: [] },
        { id: "gemini", tokens: geminiTokens, cost: geminiCost, unpricedModels: [] },
      ],
      claudeTokens,
      claudeCost,
      codexTokens,
      codexCost,
    };
  });
  const previewLocalProviders = [
    { providerID: "claude", capturedAt: previewNow, planName: "Max 20x", windows: [{ usedPercent: 43, windowMinutes: 300, resetsAt: previewNow + 10_320_000 }, { usedPercent: 18, windowMinutes: 10_080, resetsAt: previewNow + 421_200_000 }] },
    { providerID: "codex", capturedAt: previewNow - 12 * 60_000, planName: "Pro 5x", windows: [{ usedPercent: 63, windowMinutes: 300, resetsAt: previewNow + 9_000_000 }, { usedPercent: 31, windowMinutes: 10_080, resetsAt: previewNow + 331_200_000 }] },
  ];
  const previewCursor = { providerID: "cursor", capturedAt: previewNow - 30_000, planName: "Pro", windows: [{ usedPercent: 6, windowMinutes: 44_640, resetsAt: previewNow + 284_400_000 }] };
  const previewOpenRouter = { providerID: "openrouter", capturedAt: previewNow - 30_000, planName: "Credits", windows: [{ usedPercent: 12, windowMinutes: 0, remainingBalance: { amount: 42.75, currencyCode: "USD" } }] };
  const previewCatalog = [
    { id: "claude", access: "local-session", product: "Claude Desktop / Claude Code", installed: true, configured: true, detail: "Detected Claude Desktop / Claude Code on this PC" },
    { id: "codex", access: "local-session", product: "ChatGPT / Codex", installed: true, configured: true, detail: "Detected ChatGPT / Codex on this PC" },
    { id: "cursor", access: "local-session", product: "Cursor", installed: true, configured: true, detail: "Detected Cursor on this PC" },
    { id: "copilot", access: "local-session", product: "GitHub Copilot", installed: false, configured: false, detail: "Install and sign in to GitHub Copilot" },
    { id: "devin", access: "local-session", product: "Devin", installed: false, configured: false, detail: "Install and sign in to Devin" },
    { id: "windsurf", access: "local-session", product: "Windsurf", installed: false, configured: false, detail: "Install and sign in to Windsurf" },
    { id: "grok", access: "local-session", product: "Grok CLI", installed: false, configured: false, detail: "Install and sign in to Grok CLI" },
    { id: "openrouter", access: "local-credential", credentialKind: "API key", installed: true, configured: true, detail: "API key is configured locally on this PC" },
    { id: "antigravity", access: "local-session", product: "Antigravity", installed: false, configured: false, detail: "Install and sign in to Antigravity" },
    { id: "opencode", access: "local-session", product: "OpenCode", installed: false, configured: false, detail: "Install and sign in to OpenCode" },
    { id: "zai", access: "local-credential", product: "ZCode", localSessionFirst: true, credentialKind: "API key", installed: false, configured: false, detail: "Install ZCode or add an API key locally in Data Sources" },
    { id: "deepseek", access: "local-credential", credentialKind: "API key", installed: false, configured: false, detail: "Add an API key locally in Data Sources" },
    { id: "kimi", access: "local-credential", product: "Kimi Code", localSessionFirst: true, credentialKind: "API key or kimi-auth token", installed: false, configured: false, detail: "Install Kimi Code or add a credential locally in Data Sources" },
    { id: "minimax", access: "local-credential", credentialKind: "API key", installed: false, configured: false, detail: "Add an API key locally in Data Sources" },
    { id: "mimo", access: "local-credential", credentialKind: "Cookie", installed: false, configured: false, detail: "Add a Cookie locally in Data Sources" },
    { id: "qoder", access: "local-credential", product: "Qoder / QoderCN", localSessionFirst: true, credentialKind: "Cookie fallback", installed: false, configured: false, detail: "Open Qoder or add a Cookie fallback locally in Data Sources" },
    { id: "kiro", access: "local-session", product: "Kiro / kiro-cli", installed: false, configured: false, detail: "Install and sign in to Kiro / kiro-cli" },
    { id: "volcengine", access: "local-credential", credentialKind: "AccessKeyId:SecretAccessKey", installed: false, configured: false, detail: "Add credentials locally in Data Sources" },
    { id: "ollama", access: "local-credential", credentialKind: "Ollama Cloud Cookie", installed: false, configured: false, detail: "Add an Ollama Cloud Cookie locally in Data Sources" },
  ];
  const quotaSamples = [];
  for (let index = 0; index < 60; index += 1) {
    const capturedAt = previewNow - (59 - index) * 12 * 60 * 60_000;
    quotaSamples.push(
      { providerID: "claude", capturedAt, windowMinutes: 300, usedPercent: (index * 17 + (index % 4) * 3) % 96 },
      { providerID: "cursor", capturedAt, windowMinutes: 44_640, usedPercent: Math.min(8, index * 0.11) },
      { providerID: "codex", capturedAt, windowMinutes: 10_080, usedPercent: index < 46 ? 5 + index * 1.35 : Math.max(3, 13 - (index - 46) * 0.7) },
    );
  }
  const post = (id, overrides) => ({
    id,
    username: "OpenAI",
    displayName: "OpenAI",
    publishedAt: previewNow - 5 * 60 * 60_000,
    url: `https://x.com/OpenAI/status/${id}`,
    priority: "normal",
    tier: "primary",
    metrics: { replies: 377, reposts: 587, likes: 8_900 },
    ...overrides,
  });
  let preview = {
    sourceInstanceID: "8ad9c4b2-5ac9-44d7-b313-ae4f3fc59fb0",
    deviceName: "Windows PC",
    appVersion: "1.2.6-windows.2",
    launchAtLogin: false,
    floatingWidgetEnabled: false,
    languagePreference: previewParameters.get("lang") || SYSTEM_LANGUAGE,
    systemLocale: previewParameters.get("systemLocale") || globalThis.navigator?.language || "en",
    lastUpdatedAt: previewNow,
    isRefreshing: false,
    notices: {},
    onboarding: { completed: previewParameters.get("onboarding") !== "1", detections: previewCatalog.map((provider) => ({ providerID: provider.id, installed: provider.installed, configured: provider.configured, access: provider.access, credentialKind: provider.credentialKind, detail: provider.detail })) },
    providerCatalog: previewCatalog.map((provider) => ({ ...provider, enabled: ["claude", "codex", "cursor", "openrouter"].includes(provider.id) })),
    enabledProviders: ["claude", "codex", "cursor", "openrouter"],
    localProviders: [...previewLocalProviders, previewCursor, previewOpenRouter],
    providers: [
      ...previewLocalProviders,
      previewCursor,
      previewOpenRouter,
    ],
    dailyUsageHistory: { sourceDay: previewDay, capturedAt: previewNow, days: previewHistoryDays },
    localUsage: {
      hasLocal: true,
      hasRemote: true,
      capturedAt: previewNow,
      source: "This PC + paired Mac",
      pricing: { capturedAt: previewNow - 60_000, modelCount: 2_742, refreshIntervalHours: 6, fallback: "cached-public-table" },
    },
    quotaUsageHistory: { samples: quotaSamples },
    trending: [
      post("1234500000000000001", { priority: "token_reset", text: "Codex usage limits reset schedule is changing this week: weekly quota windows now reset at fixed UTC times for all plans.", publishedAt: previewNow - 2 * 60 * 60_000, metrics: { replies: 919, reposts: 717, likes: 12_300 } }),
      post("1234500000000000002", { username: "AnthropicAI", displayName: "Anthropic", priority: "major_update", text: "Claude Code 2.2 is rolling out with faster agentic search and lower token overhead per session.", publishedAt: previewNow - 8 * 60 * 60_000, metrics: { replies: 512, reposts: 940, likes: 9_100 } }),
      post("1234500000000000003", { username: "sama", displayName: "Sam Altman", text: "major price cuts today: API pricing for our flagship model drops across every tier.", publishedAt: previewNow - 18 * 60 * 60_000, metrics: { replies: 1_300, reposts: 229, likes: 6_700 } }),
      post("1234500000000000004", { username: "thsottiaux", displayName: "Tibo", text: "A week of efficiency improvements is rolling out, with refreshed usage limits for coding workflows.", publishedAt: previewNow - 26 * 60 * 60_000, metrics: { replies: 2_900, reposts: 1_100, likes: 23_900 } }),
      post("1234500000000000005", { text: "An internal version of our next model produced new results on long-standing open problems in mathematics.", publishedAt: previewNow - 11 * 60 * 60_000, metrics: { replies: 640, reposts: 410, likes: 7_800 } }),
      post("1234500000000000006", { username: "cursor_ai", displayName: "Cursor", text: "Agent quota update: Pro plans get higher monthly model credits starting today.", publishedAt: previewNow - 30 * 60 * 60_000, metrics: { replies: 210, reposts: 180, likes: 3_400 } }),
    ],
    feedLoading: false,
    feedUpdatedAt: previewNow,
    sync: { paired: true, macURL: "http://mac-studio.local:47831/", deviceName: "Mac Studio", lastSyncAt: previewNow - 60_000, encryption: "AES-256-GCM" },
  };
  return {
    getState: async () => preview,
    refresh: async () => (preview = { ...preview, lastUpdatedAt: Date.now() }),
    completeOnboarding: async (providerIDs) => (preview = { ...preview, onboarding: { ...preview.onboarding, completed: true }, enabledProviders: providerIDs, providerCatalog: preview.providerCatalog.map((provider) => ({ ...provider, enabled: providerIDs.includes(provider.id) })) }),
    rescanProviders: async () => preview,
    setProviderEnabled: async (providerID, enabled) => {
      const next = new Set(preview.enabledProviders);
      if (enabled) next.add(providerID); else next.delete(providerID);
      const enabledProviders = [...next];
      return (preview = { ...preview, enabledProviders, providerCatalog: preview.providerCatalog.map((provider) => ({ ...provider, enabled: enabledProviders.includes(provider.id) })) });
    },
    setProviderCredential: async (providerID) => {
      const enabledProviders = [...new Set([...preview.enabledProviders, providerID])];
      return (preview = { ...preview, enabledProviders, providerCatalog: preview.providerCatalog.map((provider) => provider.id === providerID ? { ...provider, installed: true, configured: true, enabled: true } : provider) });
    },
    clearProviderCredential: async (providerID) => (preview = { ...preview, providerCatalog: preview.providerCatalog.map((provider) => provider.id === providerID ? { ...provider, configured: false } : provider) }),
    pair: async () => preview,
    disconnect: async () => (preview = { ...preview, sync: { paired: false } }),
    openExternal: async () => true,
    setLaunchAtLogin: async (value) => (preview = { ...preview, launchAtLogin: Boolean(value) }),
    setFloatingWidgetEnabled: async (value) => (preview = { ...preview, floatingWidgetEnabled: Boolean(value) }),
    setLanguage: async (value) => (preview = { ...preview, languagePreference: value }),
    openPopup: async () => preview,
    relaunch: async () => preview,
    quit: async () => preview,
    onStateChanged: () => () => {},
  };
}

createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
