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
import {
  LIMITS_VISIBILITY_KEY,
  normalizeLimitsVisibility,
  readLimitsVisibility,
  setProviderVisible,
  writeLimitsVisibility,
} from "./limits-layout.js";
import { buildOverviewSummary, buildTodayUsage, rankOfficialQuotaProviders, summaryWindow, usagePace } from "./overview-model.js";
import { PROVIDER_ORDER, providerMeta } from "./provider-meta.js";
import { compactAxisValue, linePoints, quotaTrendRows, TREND_RANGES, usageTrendModel } from "./trends-model.js";
import "./styles.css";

const PROVIDER_ICON_MODULES = import.meta.glob("../../site/assets/providers/*.{svg,png}", { eager: true, import: "default" });
const PROVIDER_ICONS = Object.fromEntries(Object.entries(PROVIDER_ICON_MODULES).map(([path, url]) => [path.split("/").pop(), url]));

// Section metadata mirrors the Mac's DashboardSection titles/subtitles, with
// honest wording where the Windows data source differs (synced vs local).
const SECTIONS = {
  overview: { title: "Overview", subtitle: "Quota risk, today's usage, and estimated cost" },
  limits: { title: "Limits", subtitle: "Official quota windows across your AI coding tools" },
  trends: { title: "Trends", subtitle: "Usage over time · synced from your Mac" },
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
  if (!value) return fallback;
  const age = relativeAge(value);
  return age === "now" ? "just now" : `${age.split(", ")[0]} ago`;
}

function initialSection() {
  const requested = new URLSearchParams(globalThis.location?.search || "").get("section");
  return SECTIONS[requested] ? requested : "overview";
}

function App() {
  const [state, setState] = useState();
  const [section, setSection] = useState(initialSection);
  const [error, setError] = useState();

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

  if (!state) return <div className="loading">Loading TokenRemain…</div>;
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
              title={SECTIONS[section].title}
              subtitle={SECTIONS[section].subtitle}
              trailing={state.lastUpdatedAt ? `Updated ${formatClockSeconds(state.lastUpdatedAt)}` : undefined}
            />
            {error && <div className="error-banner" role="alert">{error}</div>}
            {section === "overview" && <Overview state={state} onSelect={setSection} onOpen={openExternal} />}
            {section === "limits" && <Limits state={state} />}
            {section === "trends" && <Trends state={state} />}
            {section === "devices" && <Devices state={state} action={action} />}
            {section === "dataSources" && <DataSources state={state} />}
            {section === "settings" && <Settings state={state} action={action} onSelect={setSection} />}
          </div>
        </main>
      </div>
    </div>
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
            <div className="nav-label">{group.label}</div>
            <nav>
              {group.items.map((id) => {
                const Icon = NAV_ICONS[id];
                return (
                  <button key={id} className={section === id ? "selected" : ""} aria-current={section === id ? "page" : undefined} onClick={() => onSelect(id)}>
                    <Icon />{SECTIONS[id].title}
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
    ? { tone: "muted", text: "Loading data…" }
    : needsAttention
      ? { tone: "warning", text: "Some sources need attention" }
      : { tone: "success", text: "All sources healthy" };
  return (
    <div className="sync-footer">
      <div className="sync-footer-head">
        <span>Sync status</span>
        <button
          className="round-refresh"
          onClick={onRefresh}
          disabled={state.isRefreshing}
          aria-label="Refresh"
          title="Refresh every data source now"
        >
          <RefreshIcon spinning={state.isRefreshing} />
        </button>
      </div>
      <div className={`status-line tone-${health.tone}`}><span className="status-dot" />{health.text}</div>
      <button className="quick-view-link" onClick={onOpenPopup}><RadioIcon />Open Quick View</button>
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
  return <Badge text={(level || "unknown").toUpperCase()} tone={level || "unknown"} filled={level === "high"} />;
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
    <div className="segment-bar" style={{ height }} role="meter" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(clamped)} aria-valuetext={`${formatPercent(clamped)} remaining`} aria-label="Quota remaining">
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
          label="Lowest remaining quota"
          value={summary.tightest ? formatPercent(summary.tightest.remaining) : "—"}
          valueTone={summary.risk}
          caption={`${(summary.risk || "unknown").toUpperCase()} RISK`}
          captionTone={summary.risk || "muted"}
        />
        <MetricCard
          label="Today's Tokens"
          value={today?.totalTokens ? compactNumber(today.totalTokens) : "—"}
          caption={state.dailyUsageHistory ? "Synced from your Mac" : "Daily history not shared"}
        />
        <MetricCard
          label="Today's Est. Cost"
          value={Number.isFinite(today?.totalCost) ? formatMoney(today.totalCost) : "—"}
          caption={today?.totalTokens && !Number.isFinite(today?.totalCost) ? "Price unavailable" : "API list-price estimate"}
          captionTone={today?.totalTokens && !Number.isFinite(today?.totalCost) ? "warning" : undefined}
        />
        <MetricCard
          label={risk.projectedRunOutAt ? "Projected runway" : "Quota sustainability"}
          value={risk.projectedRunOutAt ? durationUntil(risk.projectedRunOutAt) : summary.risk ? "Lasts to reset" : "—"}
          valueTone={risk.projectedRunOutAt ? "medium" : undefined}
          caption={risk.projectedRunOutAt
            ? `${risk.window.providerName} ${windowName(risk.window.windowMinutes)} · before reset`
            : "At the current window's average pace"}
          captionTone={risk.projectedRunOutAt ? "medium" : summary.risk ? "low" : "muted"}
        />
      </div>
      <div className="overview-grid">
        <UsageCostCard state={state} today={today} onManage={() => onSelect("devices")} />
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
  const stops = Number.isFinite(today?.totalCost) && today.totalCost > 0
    ? today.entries.flatMap((entry) => {
      const start = rotation;
      rotation += entry.costShare;
      const color = providerPresentation(entry.id).color;
      return [`${color} ${start}%`, `${color} ${rotation}%`];
    }).join(", ")
    : "var(--track) 0 100%";
  return (
    <section className="dashboard-panel usage-cost-card">
      <PanelHeader title="Today's Usage & Cost" subtitle="By provider · synced from your Mac" />
      {hasEntries ? (
        <>
          <div className="usage-composition">
            <div className="donut" style={{ background: `conic-gradient(${stops})` }}>
              <div>
                <strong>{Number.isFinite(today.totalCost) ? formatMoney(today.totalCost) : "—"}</strong>
                <span>{Number.isFinite(today.totalCost) ? "Est. today" : "Price unavailable"}</span>
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
          <p className="panel-source">Snapshot for today; see Trends for multi-day history. Captured {formatClock(today.capturedAt)} on {state.sync?.deviceName || "your Mac"}.</p>
        </>
      ) : (
        <EmptyState
          icon={PieIcon}
          title={!state.sync.paired ? "Pair your Mac to see today's usage" : state.dailyUsageHistory ? "No synced usage today" : "No usage history from your Mac yet"}
          message={!state.sync.paired
            ? "Direct sync brings the same daily usage aggregate to this PC."
            : state.dailyUsageHistory
              ? "This card fills in after Claude or Codex records usage for the source Mac's current day."
              : "Turn on “Share daily usage with paired devices” in TokenRemain › Devices on your Mac."}
          action={!state.sync.paired ? <button className="inline-action" onClick={onManage}>Manage devices</button> : undefined}
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
        title="Official Quota"
        subtitle="Tightest windows of your most-used providers"
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
            <span>Risk level</span>
            <RiskBadge level={risk} />
          </div>
        </>
      ) : (
        <EmptyState
          icon={GaugeIcon}
          title="Reading official quota"
          message="Server-side quota snapshots for Claude and Codex will appear here automatically."
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
      <PanelHeader title="Trending" subtitle="What matters most right now" trailing={<Badge text="HOT" tone="cyan" />} />
      {posts.length ? (
        <>
          <div className="trending-list">
            {posts.map((post, index) => <TrendingRow key={post.id} post={post} rank={index + 1} onOpen={onOpen} />)}
          </div>
          <p className="panel-source">Public TokenRemain feed{state.feedError ? ` · cached (${state.feedError})` : ""}</p>
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
  return (
    <section className="dashboard-panel risk-notes">
      <PanelHeader title="Risk Notes" subtitle="Based on the tightest quota window" />
      {risk.window ? (
        <>
          <div className="risk-headline">
            <RiskBadge level={risk.level} />
            <strong>{risk.headline}</strong>
          </div>
          <p className="risk-summary">{risk.summary}</p>
          <div className="risk-details">
            <Divider />
            <InfoRow label="Tightest window" value={`${risk.window.providerName} · ${windowName(risk.window.windowMinutes)}`} />
            <InfoRow label="Remaining quota" value={formatPercent(risk.window.remaining)} tone={risk.level} />
            {risk.projectedRunOutAt && <InfoRow label="Projected depletion" value={risk.projectedDepletion} tone="medium" />}
            {risk.window.resetsAt && <InfoRow label="Projected reset" value={resetDescription(risk.window.resetsAt)} />}
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
        title="AI Feed"
        subtitle="Curated updates directly relevant to your quota and workflow"
        trailing={state.feedUpdatedAt ? `Updated ${formatClockSeconds(state.feedUpdatedAt)}` : undefined}
      />
      {state.feedError && (
        <div className="settings-card feed-unavailable">
          <AlertIcon />The curated feed can't update right now; the app will retry in the background.
        </div>
      )}
      {important.length > 0 && (
        <FeedGroup title="Important" subtitle="Quota, pricing, product launches, and service status first" posts={important} onOpen={onOpen} />
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
        <FeedGroup title="More worth watching" subtitle="Ranked by relevance, recency, and engagement quality" posts={regular} onOpen={onOpen} />
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
            {post.priority === "token_reset" ? <GaugeIcon /> : <BoltIcon />}{priorityTitle(post.priority)}
          </span>
        )}
        <span className="open-arrow"><ArrowUpRightIcon /></span>
      </div>
      <p>{post.text}</p>
      <div className="feed-metrics">
        <span><ReplyIcon />{compactNumber(post.metrics.replies)}</span>
        <span><RepostIcon />{compactNumber(post.metrics.reposts)}</span>
        <span><HeartIcon />{compactNumber(post.metrics.likes)}</span>
        <span className="view-link">View on X</span>
      </div>
    </button>
  );
}

// MARK: - Limits

function Limits({ state }) {
  const discoveredIDs = [
    "claude",
    "codex",
    ...state.providers.map((provider) => provider.providerID),
  ].filter((id, index, values) => values.indexOf(id) === index);
  const availableIDs = [
    ...PROVIDER_ORDER,
    ...state.providers.map((provider) => provider.providerID).filter((id) => !PROVIDER_ORDER.includes(id)),
  ];
  const availableSignature = availableIDs.join("|");
  const discoveredSignature = discoveredIDs.join("|");
  const [visibility, setVisibility] = useState(() => readLimitsVisibility(
    globalThis.localStorage,
    LIMITS_VISIBILITY_KEY,
    availableIDs,
    discoveredIDs,
  ));
  useEffect(() => {
    setVisibility((current) => normalizeLimitsVisibility(current, availableIDs, discoveredIDs));
  }, [availableSignature, discoveredSignature]);
  useEffect(() => {
    writeLimitsVisibility(globalThis.localStorage, LIMITS_VISIBILITY_KEY, visibility);
  }, [visibility]);

  const providerIDs = visibility.visible;
  const hiddenIDs = availableIDs.filter((id) => !providerIDs.includes(id));
  const [order, setOrder] = usePersistentOrder(providerIDs, LIMITS_ORDER_KEY);
  const showProvider = (id) => setVisibility((current) => setProviderVisible(current, id, true, availableIDs, discoveredIDs));
  const hideProvider = (id) => setVisibility((current) => setProviderVisible(current, id, false, availableIDs, discoveredIDs));
  return (
    <section className="content-section limits-section">
      <div className="limits-toolbar">
        <span>{providerIDs.length} apps shown · drag cards to reorder</span>
        <ProviderAddMenu
          providerIDs={hiddenIDs}
          providers={state.providers}
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
            canRemove={providerIDs.length > 1}
            onRemove={() => hideProvider(id)}
          />
        )}
      />
      <div className="settings-card about-windows">
        <PanelHeader title="About quota windows" />
        <p>Percentages show the remaining quota within a window; usage-based services show the remaining monetary balance directly. Windows come from each provider's servers: Claude, Codex, and Z.ai usually include a 5-hour session window and a 7-day window; Cursor uses a monthly billing window; Grok uses a weekly pool.</p>
        <p>Use Add app and the minus control to choose what appears here. New providers reported by this PC or your paired Mac appear automatically; providers you remove stay hidden until you add them again.</p>
        <p>Drag a full card to reorder it — Alt plus arrow keys also works — and both order and visibility are remembered on this PC.</p>
        <p>Reset times come from official snapshots; when a window has no reset time yet, it shows “Waiting for the official reset time”.</p>
      </div>
    </section>
  );
}

/// Full provider quota card matching the Mac's QuotaCard: brand row + plan
/// pill, then one row per official window with meter, reset, and pace.
function ProviderAddMenu({ providerIDs, providers, onAdd }) {
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
        <PlusIcon />Add app
      </button>
      {open && (
        <div className="provider-add-popover" role="menu" aria-label="Add an app to Limits">
          {providerIDs.map((id) => {
            const meta = providerPresentation(id);
            const available = providers.some((provider) => provider.providerID === id);
            const local = id === "claude" || id === "codex";
            return (
              <button key={id} role="menuitem" onClick={() => { onAdd(id); setOpen(false); }}>
                <ProviderMark meta={meta} size={18} />
                <span><strong>{meta.name}</strong><small>{available ? "Quota source available" : local ? "Supported local sign-in" : "Available through Mac sync"}</small></span>
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
    <article className="provider-card" title="Drag the card to reorder">
      <div className="provider-card-head">
        <ProviderMark meta={meta} />
        <h3>{meta.name}</h3>
        {windows.length > 0 && notice && (
          <span className="notice-pill" title={notice}><AlertIcon />Refresh issue</span>
        )}
        {provider?.planName && <Badge text={provider.planName} tone="plan" />}
        <button
          className="quota-remove"
          onClick={onRemove}
          disabled={!canRemove}
          aria-label={`Remove ${meta.name} from Limits`}
          title={canRemove ? `Remove ${meta.name} from Limits` : "At least one app must remain"}
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
          <span>{notice || (id === "claude" || id === "codex"
            ? "Waiting for a local sign-in or the next quota refresh."
            : `${meta.name} has no snapshot yet. Pair your Mac to sync supported providers.`)}</span>
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
    ? `${formatBalance(window.remainingBalance)} remaining`
    : `${formatPercent(remaining)} remaining`;
  return (
    <div className="quota-window">
      <div className="quota-window-head">
        <span className="quota-window-title">{title}</span>
        {pace?.status === "deficit" && <AlertIcon className="pace-alert" title="Current usage is ahead of pace" />}
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
  const label = pace.status === "onTrack" ? "On track"
    : pace.status === "reserve" ? `${formatPercent(Math.abs(pace.deltaPercent))} reserve`
      : `${formatPercent(Math.abs(pace.deltaPercent))} ahead`;
  const outcome = pace.willLastUntilReset
    ? "Lasts until reset"
    : pace.estimatedRunOutAt
      ? `Projected to run out in ${durationUntil(pace.estimatedRunOutAt)}`
      : "Projected to run out early";
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

const USAGE_TREND_PROVIDERS = ["claude", "codex"];

function TrendSegmentedControl({ label, options, value, onChange }) {
  return (
    <div className="trend-segmented" role="group" aria-label={label}>
      {options.map((option) => {
        const normalized = typeof option === "object" ? option : { value: option, label: `${option} d` };
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
  const model = usageTrendModel(history, { range, metric, providerIDs: USAGE_TREND_PROVIDERS });
  const fresh = history?.capturedAt && Date.now() - history.capturedAt < 30 * 60_000;
  const stride = model.days.length <= 7 ? 1 : model.days.length <= 14 ? 2 : 5;
  const ticks = [1, 0.75, 0.5, 0.25];
  const activeDay = Number.isInteger(activeIndex) ? model.days[activeIndex] : undefined;

  return (
    <section className="dashboard-panel trend-history-panel">
      <PanelHeader
        title="Daily Usage Trend"
        subtitle="Selected apps stacked · synced daily aggregate"
        trailing={fresh ? <Badge text="LIVE" tone="codex" /> : undefined}
      />
      <div className="trend-card-controls">
        <div className="trend-series-legend" aria-label="Visible providers">
          {USAGE_TREND_PROVIDERS.map((id) => {
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
          <TrendSegmentedControl label="History range" options={TREND_RANGES} value={range} onChange={setRange} />
          <TrendSegmentedControl
            label="Metric"
            options={[{ value: "tokens", label: "Tokens" }, { value: "cost", label: "Cost" }]}
            value={metric}
            onChange={setMetric}
          />
        </div>
      </div>

      <div className="trend-total-row">
        <span>Total trend</span>
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
              const aria = `${formatDayLabel(day.day)} · ${USAGE_TREND_PROVIDERS.map((id) => `${providerMeta(id).name} ${trendValue(day.values[id], metric)}`).join(" · ")} · Total ${trendValue(day.total, metric)}`;
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
                    {USAGE_TREND_PROVIDERS.map((id) => day.values[id] > 0 && (
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
              {USAGE_TREND_PROVIDERS.map((id) => (
                <span key={id}><i style={{ background: providerMeta(id).color }} />{providerMeta(id).name}<b>{trendValue(activeDay.values[id], metric)}</b></span>
              ))}
              <span className="trend-tooltip-total">Total<b>{trendValue(activeDay.total, metric)}</b></span>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}

function QuotaSparkline({ row, color }) {
  const latestPoint = row.points.split(" ").at(-1)?.split(",").map(Number);
  return (
    <svg className="quota-sparkline" viewBox="0 0 100 38" preserveAspectRatio="none" aria-hidden="true">
      <line x1="0" x2="100" y1="0.5" y2="0.5" />
      <line x1="0" x2="100" y1="19" y2="19" />
      <line x1="0" x2="100" y1="37.5" y2="37.5" />
      {row.samples.length > 1 && <polyline className="quota-sparkline-line" points={row.points} style={{ stroke: color }} />}
      {latestPoint && <circle cx={latestPoint[0]} cy={latestPoint[1]} r="1.8" style={{ fill: color }} />}
    </svg>
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
        title="Quota Consumption Trend"
        subtitle="Primary quota window by app · local snapshots"
        trailing={<TrendSegmentedControl label="Quota history range" options={TREND_RANGES} value={range} onChange={setRange} />}
      />
      {rows.length ? (
        <div className="quota-trend-table">
          <div className="quota-trend-header" aria-hidden="true">
            <span>APP</span><span>WINDOW</span><span>USED</span><span>TREND</span>
          </div>
          {rows.map((row) => {
            const meta = providerPresentation(row.providerID);
            return (
              <div
                className="quota-trend-row"
                key={row.providerID}
                aria-label={`${meta.name}, ${windowName(row.latest.windowMinutes)} window, ${formatPercent(row.latest.usedPercent)} used`}
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
          title="Quota trend is accumulating"
          message="TokenRemain starts recording after a successful quota refresh. Connected apps appear automatically; earlier history cannot be backfilled."
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
            title="Trend data is accumulating day by day"
            message="The daily usage trend needs at least two synced days. Keep Direct Sync enabled and TokenRemain adds each Mac day automatically."
          />
        </section>
      )}
      <QuotaConsumptionTrendCard state={state} />
      <div className="trends-summary-grid">
        <div className="settings-card">
          <PanelHeader title="Today's Snapshot" subtitle="Where the trend starts · synced from your Mac" />
          {today?.totalTokens ? (
            <>
              <InfoRow label="Today's Tokens" value={compactNumber(today.totalTokens)} />
              <InfoRow label="Today's Est. Cost" value={Number.isFinite(today.totalCost) ? formatMoney(today.totalCost) : "Price unavailable"} />
              <Divider />
              {today.entries.map((entry) => (
                <InfoRow key={entry.id} label={entry.displayName} value={`${compactNumber(entry.tokens)} · ${entry.cost > 0 ? formatMoney(entry.cost) : "—"}`} />
              ))}
            </>
          ) : (
            <p className="quiet-note">No synced usage recorded for the Mac's current day yet.</p>
          )}
        </div>
        <div className="settings-card">
          <PanelHeader title="History coverage" subtitle="Privacy-minimized data received from your Mac" />
          <InfoRow label="Synced days" value={String(days.length)} />
          <InfoRow label="Oldest day" value={days[0]?.day || "Waiting"} />
          <InfoRow label="Latest day" value={days.at(-1)?.day || "Waiting"} />
          <InfoRow label="Quota history" value={state.quotaUsageHistory?.samples?.length ? `${state.quotaUsageHistory.samples.length} local snapshots` : "Accumulating"} />
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
          title="This Windows PC"
          subtitle="The device currently monitored"
          trailing={<StatusDotLabel tone="success" text="Monitoring" />}
        />
        <InfoRow label="Device name" value={state.deviceName} />
        <InfoRow label="Active data sources" value={activeSources.length ? activeSources.join(" · ") : "None"} />
        {state.lastUpdatedAt && <InfoRow label="Last updated" value={formatClock(state.lastUpdatedAt)} />}
        <InfoRow label="Source ID" value={state.sourceInstanceID.slice(0, 6).toUpperCase()} />
      </div>
      <div className="settings-card">
        <PanelHeader
          title="Mac direct sync"
          subtitle="Quota snapshots and optional daily aggregates; provider credentials never leave either device."
          trailing={<StatusDotLabel tone={state.sync.paired ? "success" : "muted"} text={state.sync.paired ? "Paired" : "Not paired"} />}
        />
        {state.sync.paired ? (
          <div className="paired-details">
            <InfoRow label="Mac" value={state.sync.deviceName || "Mac"} />
            <InfoRow label="Address" value={state.sync.macURL} />
            <InfoRow label="Encryption" value={state.sync.encryption} />
            <InfoRow label="Last sync" value={state.sync.lastSyncAt ? timeAgo(state.sync.lastSyncAt) : state.sync.error || "Waiting"} />
            <button className="secondary danger" onClick={() => action(api.disconnect)}>Disconnect</button>
          </div>
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

// MARK: - Data Sources

function DataSources({ state }) {
  const local = new Map((state.localProviders || []).map((provider) => [provider.providerID, provider]));
  const remoteCount = state.sync.paired ? state.providers.filter((provider) => {
    const localProvider = local.get(provider.providerID);
    return !localProvider || provider.capturedAt > localProvider.capturedAt;
  }).length : 0;
  return (
    <section className="content-section data-sources-section">
      <div className="settings-card source-list">
        <PanelHeader title="Data Source Status" subtitle="Only normalized quota and usage values enter the dashboard." />
        {["claude", "codex"].map((id) => (
          <SourceHealthRow
            key={id}
            name={`${providerPresentation(id).name} CLI`}
            detail={state.notices[id] || "Read-only local credential and quota check"}
            healthy={local.has(id) && !state.notices[id]}
            capturedAt={local.get(id)?.capturedAt}
          />
        ))}
        <SourceHealthRow
          name="Mac Direct Sync"
          detail={state.sync.error || (state.sync.paired ? `${remoteCount} fresher provider snapshot${remoteCount === 1 ? "" : "s"}` : "Open Devices to pair a Mac")}
          healthy={state.sync.paired && !state.sync.error}
          capturedAt={state.sync.lastSyncAt}
        />
        <SourceHealthRow
          name="Synced daily usage"
          detail="Claude and Codex daily aggregate; no prompts, paths, or credentials"
          healthy={Boolean(state.dailyUsageHistory)}
          capturedAt={state.dailyUsageHistory?.capturedAt}
        />
        <SourceHealthRow
          name="Curated AI Feed"
          detail={state.feedError || "Automatically curates quota, product-launch, and service-status updates in the background"}
          healthy={!state.feedError && Boolean(state.feedUpdatedAt || state.trending?.length)}
          capturedAt={state.feedUpdatedAt}
        />
      </div>
      <div className="settings-card">
        <PanelHeader title="Privacy" />
        <ul className="privacy-list">
          <li>Provider credentials are read-only local CLI files; tokens are never refreshed, written back, or synced.</li>
          <li>Direct Sync exchanges AES-256-GCM encrypted quota snapshots with your Mac on the local network.</li>
          <li>Shared usage is an optional daily aggregate — no prompts, file paths, or repository names.</li>
          <li>The curated AI feed syncs automatically via built-in policies; there are no accounts to pick or sources to manage.</li>
          <li>No CloudKit and no phone sync in this Windows build.</li>
        </ul>
      </div>
    </section>
  );
}

function SourceHealthRow({ name, detail, healthy, capturedAt }) {
  return (
    <div className="source-row">
      <span className={`source-dot ${healthy ? "tone-success" : "tone-warning"}`} aria-hidden="true" />
      <div>
        <strong>{name}</strong>
        <small>{detail}</small>
      </div>
      <div className="source-status">
        <span className={healthy ? "tone-success" : "tone-warning"}>{healthy ? "Healthy" : "Link broken"}</span>
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
      <div className="settings-tabs" role="tablist" aria-label="Settings categories">
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
              <Icon />{item.title}
            </button>
          );
        })}
      </div>
      <p className="settings-detail">{selected.detail}</p>
      {category === "general" && <GeneralSettings state={state} action={action} />}
      {category === "refreshSync" && <RefreshSyncSettings state={state} action={action} onSelect={onSelect} />}
      {category === "about" && <AboutSettings state={state} action={action} />}
    </section>
  );
}

function GeneralSettings({ state, action }) {
  return (
    <div className="settings-card">
      <PanelHeader title="General" />
      <ToggleRow
        title="Launch at login"
        detail="Start TokenRemain automatically when you sign in to Windows; it keeps monitoring from the tray."
        isOn={Boolean(state.launchAtLogin)}
        onChange={(value) => action(() => api.setLaunchAtLogin(value))}
      />
      <Divider />
      <ToggleRow
        title="Floating shortcut"
        detail="Keep a small quota shortcut above other windows. Drag its grip to move it; click the quota to open Quick View."
        isOn={Boolean(state.floatingWidgetEnabled)}
        onChange={(value) => action(() => api.setFloatingWidgetEnabled(value))}
      />
      <Divider />
      <div className="preference-row quick-view-setting">
        <div className="preference-label">
          <strong>Quick View popup</strong>
          <span>Open the same compact popup as a tray-icon click. This is separate from the full Dashboard.</span>
        </div>
        <button className="secondary" onClick={() => action(api.openPopup)}><RadioIcon />Open now</button>
      </div>
      <Divider />
      <div className="preference-row">
        <div className="preference-label">
          <strong>Close button</strong>
          <span>Closing the window keeps TokenRemain running in the tray; quit from the tray menu or Settings › About.</span>
        </div>
      </div>
    </div>
  );
}

function RefreshSyncSettings({ state, action, onSelect }) {
  return (
    <>
      <div className="settings-card">
        <PanelHeader title="Quota refresh interval" />
        <div className="preference-row">
          <div className="preference-label">
            <span>Local CLI quotas, the Mac link, and the curated feed refresh together on a fixed cadence.</span>
          </div>
          <strong className="preference-value">Every minute</strong>
        </div>
        <Divider />
        <div className="refresh-now-row">
          <button className="secondary" onClick={() => action(api.refresh)} disabled={state.isRefreshing}>
            <RefreshIcon spinning={state.isRefreshing} />{state.isRefreshing ? "Refreshing…" : "Refresh now"}
          </button>
        </div>
      </div>
      <div className="settings-card direct-sync-panel">
        <PanelHeader title="Direct Sync" subtitle="Encrypted direct sync between your devices" />
        <SyncStrip sync={state.sync} deviceName={state.deviceName} />
        <button className="manage-devices" onClick={() => onSelect("devices")}><DevicesIcon /><span>Manage devices</span><ChevronRightIcon /></button>
      </div>
    </>
  );
}

function AboutSettings({ state, action }) {
  return (
    <>
      <div className="settings-card">
        <PanelHeader title="About" />
        <InfoRow label="Version" value={`TokenRemain ${state.appVersion || ""}`.trim()} />
        <InfoRow label="Data" value="Local-first · encrypted LAN sync with your Mac" />
        <InfoRow label="Credential access" value="Read-only local CLI files" />
      </div>
      <div className="settings-card">
        <PanelHeader title="Actions" />
        <div className="actions-row">
          <button className="secondary" onClick={() => action(api.relaunch)}><RestartIcon />Restart TokenRemain</button>
          <button className="secondary danger" onClick={() => action(api.quit)}><PowerIcon />Quit</button>
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
      <div><DevicesIcon /><span><strong>{deviceName}</strong><small>This PC</small></span></div>
      <div className={sync.paired ? "sync-link connected" : "sync-link"}><span /><LockIcon /><span /><small>{sync.paired ? "Encrypted direct sync" : "Not paired"}</small></div>
      <div className="mac-end"><span><strong>{sync.deviceName || "Mac"}</strong><small>{sync.lastSyncAt ? `Last sync ${timeAgo(sync.lastSyncAt)}` : sync.error || "Open Devices to pair"}</small></span><DevicesIcon /></div>
    </div>
  );
}

// MARK: - Dev preview data

function createPreviewAPI() {
  const previewNow = Date.now();
  const previewDay = new Date(previewNow).toISOString().slice(0, 10);
  const previewHistoryDays = Array.from({ length: 30 }, (_, index) => {
    const day = new Date(previewNow - (29 - index) * 24 * 60 * 60_000).toISOString().slice(0, 10);
    const pulse = [0.72, 0.7, 1.06, 1.03, 1.62, 1.28, 1.21, 0.18, 0.87, 0.46, 0.84, 1.02, 0.72, 0.55, 0.88][index % 15];
    return {
      day,
      claudeTokens: Math.round((13_000_000 + (index % 5) * 6_500_000) * pulse),
      claudeCost: Number(((8.9 + (index % 5) * 4.2) * pulse).toFixed(2)),
      codexTokens: Math.round((92_000_000 + (index % 7) * 18_000_000) * pulse),
      codexCost: Number(((64.5 + (index % 7) * 12.6) * pulse).toFixed(2)),
    };
  });
  const previewLocalProviders = [
    { providerID: "claude", capturedAt: previewNow, planName: "Max 20x", windows: [{ usedPercent: 43, windowMinutes: 300, resetsAt: previewNow + 10_320_000 }, { usedPercent: 18, windowMinutes: 10_080, resetsAt: previewNow + 421_200_000 }] },
    { providerID: "codex", capturedAt: previewNow - 12 * 60_000, planName: "Pro 5x", windows: [{ usedPercent: 63, windowMinutes: 300, resetsAt: previewNow + 9_000_000 }, { usedPercent: 31, windowMinutes: 10_080, resetsAt: previewNow + 331_200_000 }] },
  ];
  const previewCursor = { providerID: "cursor", capturedAt: previewNow - 30_000, planName: "Pro", windows: [{ usedPercent: 6, windowMinutes: 44_640, resetsAt: previewNow + 284_400_000 }] };
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
    appVersion: "1.2.6-windows.1",
    launchAtLogin: false,
    floatingWidgetEnabled: false,
    lastUpdatedAt: previewNow,
    isRefreshing: false,
    notices: {},
    localProviders: previewLocalProviders,
    providers: [
      ...previewLocalProviders,
      previewCursor,
      { providerID: "openrouter", capturedAt: previewNow - 30_000, planName: "Credits", windows: [{ usedPercent: 12, windowMinutes: 0, remainingBalance: { amount: 42.75, currencyCode: "USD" } }] },
    ],
    dailyUsageHistory: { sourceDay: previewDay, capturedAt: previewNow, days: previewHistoryDays },
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
    pair: async () => preview,
    disconnect: async () => (preview = { ...preview, sync: { paired: false } }),
    openExternal: async () => true,
    setLaunchAtLogin: async (value) => (preview = { ...preview, launchAtLogin: Boolean(value) }),
    setFloatingWidgetEnabled: async (value) => (preview = { ...preview, floatingWidgetEnabled: Boolean(value) }),
    openPopup: async () => preview,
    relaunch: async () => preview,
    quit: async () => preview,
    onStateChanged: () => () => {},
  };
}

createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
