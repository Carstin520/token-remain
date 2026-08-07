import React, { useEffect, useState } from "react";
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
import { LIMITS_ORDER_KEY, normalizeOrder } from "./layout.js";
import { buildOverviewSummary, buildTodayUsage, rankOfficialQuotaProviders, summaryWindow, usagePace } from "./overview-model.js";
import { PROVIDER_ORDER, providerMeta } from "./provider-meta.js";
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
  settings: { title: "Settings", subtitle: "Startup, refresh, and app controls" },
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
  return { ...meta, icon: PROVIDER_ICONS[meta.icon] };
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
    <div className="app-shell">
      <Sidebar state={state} section={section} onSelect={setSection} onRefresh={() => action(api.refresh)} />
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
  );
}

// MARK: - Sidebar

function Sidebar({ state, section, onSelect, onRefresh }) {
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
      <SyncFooter state={state} onRefresh={onRefresh} />
    </aside>
  );
}

/// The Mac sidebar footer: a "Sync status" glass card owning the refresh
/// action and a green/amber/muted health readout.
function SyncFooter({ state, onRefresh }) {
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
    ? <img className="provider-mark" style={{ width: size, height: size }} src={meta.icon} alt="" />
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
            {risk.projectedRunOutAt && <InfoRow label="Projected depletion" value={`in ${durationUntil(risk.projectedRunOutAt)}`} tone="medium" />}
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
  const knownProviderIDs = PROVIDER_ORDER.filter((id) => (
    id === "claude" || id === "codex" || state.providers.some((provider) => provider.providerID === id)
  ));
  const providerIDs = [
    ...knownProviderIDs,
    ...state.providers.map((provider) => provider.providerID).filter((id) => !PROVIDER_ORDER.includes(id)),
  ];
  const [order, setOrder] = usePersistentOrder(providerIDs, LIMITS_ORDER_KEY);
  return (
    <section className="content-section limits-section">
      <DirectReorderGrid
        className="quota-grid"
        order={normalizeOrder(order, providerIDs)}
        onOrderChange={setOrder}
        renderItem={(id) => (
          <QuotaCard
            provider={state.providers.find((item) => item.providerID === id)}
            notice={state.notices[id]}
            id={id}
          />
        )}
      />
      <div className="settings-card about-windows">
        <PanelHeader title="About quota windows" />
        <p>Percentages show the remaining quota within a window; usage-based services show the remaining monetary balance directly. Windows come from each provider's servers: Claude, Codex, and Z.ai usually include a 5-hour session window and a 7-day window; Cursor uses a monthly billing window; Grok uses a weekly pool.</p>
        <p>Cards appear automatically from this PC's CLI sign-ins and every provider synced from your paired Mac. Drag a full card to reorder it — Alt plus arrow keys also works — and the order is remembered on this PC.</p>
        <p>Reset times come from official snapshots; when a window has no reset time yet, it shows “Waiting for the official reset time”.</p>
      </div>
    </section>
  );
}

/// Full provider quota card matching the Mac's QuotaCard: brand row + plan
/// pill, then one row per official window with meter, reset, and pace.
function QuotaCard({ provider, notice, id }) {
  const meta = providerPresentation(id);
  const windows = provider?.windows || [];
  return (
    <article className="provider-card" title="Drag the card to reorder">
      <div className="provider-card-head">
        <ProviderMark meta={meta} />
        <h3>{meta.name}</h3>
        {windows.length > 0 && notice && (
          <span className="notice-pill" title={notice}><AlertIcon />Login not detected</span>
        )}
        {provider?.planName && <Badge text={provider.planName} tone="plan" />}
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
            ? "Reading official quota…"
            : `${meta.name} has no synced snapshot yet.`)}</span>
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

function Trends({ state }) {
  const days = (state.dailyUsageHistory?.days || []).slice(-14);
  const totals = days.map((day) => (day.claudeTokens || 0) + (day.codexTokens || 0));
  const maximum = Math.max(1, ...totals);
  const today = buildTodayUsage(state.dailyUsageHistory);
  const fresh = state.dailyUsageHistory?.capturedAt && Date.now() - state.dailyUsageHistory.capturedAt < 30 * 60_000;
  return (
    <section className="content-section trends-section">
      <section className="dashboard-panel trend-history-panel">
        <PanelHeader
          title="Daily Usage Trend"
          subtitle="Claude and Codex stacked · synced daily aggregate"
          trailing={fresh ? <Badge text="LIVE" tone="codex" /> : undefined}
        />
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
                    <span>{formatDayLabel(day.day)}</span>
                  </div>
                );
              })}
            </div>
            <div className="trend-legend">
              <span><i className="provider-dot" style={{ background: providerMeta("codex").color }} />Codex</span>
              <span><i className="provider-dot" style={{ background: providerMeta("claude").color }} />Claude</span>
            </div>
            <p className="panel-source">Captured {formatClock(state.dailyUsageHistory.capturedAt)} on your Mac · synced daily aggregate</p>
          </>
        ) : (
          <EmptyState
            icon={TrendsIcon}
            title="Trend data is accumulating day by day"
            message="The daily usage trend needs at least two synced days. Keep Direct Sync enabled and TokenRemain adds each Mac day automatically."
          />
        )}
      </section>
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
          <InfoRow label="Quota history" value="Current snapshots only" />
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
  { id: "general", title: "General", detail: "Startup and background behavior", icon: SwitchIcon },
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

// MARK: - Icons

function Icon({ children, className, title, spinning }) {
  return (
    <svg
      aria-hidden={title ? undefined : "true"}
      role={title ? "img" : undefined}
      className={`${className || ""} ${spinning ? "spinning" : ""}`.trim() || undefined}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {title && <title>{title}</title>}
      {children}
    </svg>
  );
}
function GridIcon() { return <Icon><rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><rect x="14" y="14" width="6" height="6" rx="1"/></Icon>; }
function GaugeIcon() { return <Icon><path d="M5 17a8 8 0 1 1 14 0"/><path d="m12 13 4-4"/><path d="M8 19h8"/></Icon>; }
function TrendsIcon() { return <Icon><path d="M4 18V6"/><path d="M4 18h16"/><path d="m7 14 4-4 3 2 5-6"/></Icon>; }
function DevicesIcon() { return <Icon><rect x="3" y="5" width="13" height="10" rx="1.5"/><path d="M7 19h5M9.5 15v4"/><rect x="17" y="9" width="4" height="8" rx="1"/></Icon>; }
function DataSourcesIcon() { return <Icon><ellipse cx="12" cy="5" rx="7" ry="3"/><path d="M5 5v6c0 1.7 3.1 3 7 3s7-1.3 7-3V5"/><path d="M5 11v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"/></Icon>; }
function SettingsIcon() { return <Icon><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3A1.7 1.7 0 0 0 10 3V2.8h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z"/></Icon>; }
function RefreshIcon({ spinning }) { return <Icon spinning={spinning}><path d="M20 7v5h-5"/><path d="M4 17v-5h5"/><path d="M6.1 8a7 7 0 0 1 11.5-2.6L20 7M4 17l2.4 1.6A7 7 0 0 0 17.9 16"/></Icon>; }
function LockIcon() { return <Icon><rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></Icon>; }
function ChevronRightIcon() { return <Icon><path d="m9 6 6 6-6 6"/></Icon>; }
function FlameIcon() { return <Icon><path d="M12 21c3.9 0 6.5-2.4 6.5-6 0-3.2-2.2-5.4-3.7-7.5-.6.9-1 1.6-1.3 2.8C12.4 8 11.4 5.5 9.2 3c-.4 3-1.2 4.4-2.4 6.2-1 1.6-1.3 3-1.3 4.8 0 4.6 3 7 6.5 7Z"/></Icon>; }
function BoltIcon() { return <Icon><path d="M13 3 5 13h5l-1 8 8-11h-5l1-7Z"/></Icon>; }
function ReplyIcon() { return <Icon><path d="M20 12a8 8 0 0 1-8 8H4l2.5-2.6A8 8 0 1 1 20 12Z"/></Icon>; }
function RepostIcon() { return <Icon><path d="M17 3 21 7l-4 4"/><path d="M21 7H8a4 4 0 0 0-4 4"/><path d="m7 21-4-4 4-4"/><path d="M3 17h13a4 4 0 0 0 4-4"/></Icon>; }
function HeartIcon() { return <Icon><path d="M12 20.5S4 15.5 4 9.9A4.4 4.4 0 0 1 8.4 5.5c1.6 0 2.9.9 3.6 2.1.7-1.2 2-2.1 3.6-2.1a4.4 4.4 0 0 1 4.4 4.4c0 5.6-8 10.6-8 10.6Z"/></Icon>; }
function ArrowUpRightIcon() { return <Icon><path d="M7 17 17 7"/><path d="M9 7h8v8"/></Icon>; }
function CheckCircleIcon() { return <Icon><circle cx="12" cy="12" r="8.5"/><path d="m8.5 12.2 2.4 2.4 4.6-4.9"/></Icon>; }
function AlertIcon({ className, title }) { return <Icon className={className} title={title}><path d="M12 4 2.8 20h18.4L12 4Z"/><path d="M12 10v4.4"/><path d="M12 17.2v.1"/></Icon>; }
function MoonIcon() { return <Icon><path d="M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5Z"/></Icon>; }
function PieIcon() { return <Icon><path d="M12 3a9 9 0 1 0 9 9h-9V3Z"/><path d="M15 3.6A9 9 0 0 1 20.4 9H15V3.6Z"/></Icon>; }
function RadioIcon() { return <Icon><circle cx="12" cy="12" r="1.6"/><path d="M8.5 15.5a5 5 0 0 1 0-7"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M5.6 18.4a9 9 0 0 1 0-12.8"/><path d="M18.4 5.6a9 9 0 0 1 0 12.8"/></Icon>; }
function ResetIcon() { return <Icon><path d="M4 8a8 8 0 1 1-1 6"/><path d="M4 3v5h5"/></Icon>; }
function SwitchIcon() { return <Icon><rect x="3" y="6" width="18" height="5" rx="2.5"/><circle cx="7" cy="8.5" r="1.4"/><rect x="3" y="13" width="18" height="5" rx="2.5"/><circle cx="17" cy="15.5" r="1.4"/></Icon>; }
function InfoIcon() { return <Icon><circle cx="12" cy="12" r="8.5"/><path d="M12 11v5"/><path d="M12 8v.1"/></Icon>; }
function RestartIcon() { return <Icon><path d="M20 12a8 8 0 1 1-2.3-5.6"/><path d="M20 3v4h-4"/></Icon>; }
function PowerIcon() { return <Icon><path d="M12 3v8"/><path d="M6.3 6.5a8 8 0 1 0 11.4 0"/></Icon>; }

// MARK: - Dev preview data

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
    { providerID: "codex", capturedAt: previewNow - 12 * 60_000, planName: "Pro 5x", windows: [{ usedPercent: 63, windowMinutes: 300, resetsAt: previewNow + 9_000_000 }, { usedPercent: 31, windowMinutes: 10_080, resetsAt: previewNow + 331_200_000 }] },
  ];
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
    lastUpdatedAt: previewNow,
    isRefreshing: false,
    notices: {},
    localProviders: previewLocalProviders,
    providers: [
      ...previewLocalProviders,
      { providerID: "cursor", capturedAt: previewNow - 30_000, planName: "Pro", windows: [{ usedPercent: 26, windowMinutes: 44_640, resetsAt: previewNow + 284_400_000 }] },
      { providerID: "openrouter", capturedAt: previewNow - 30_000, planName: "Credits", windows: [{ usedPercent: 12, windowMinutes: 0, remainingBalance: { amount: 42.75, currencyCode: "USD" } }] },
    ],
    dailyUsageHistory: { sourceDay: previewDay, capturedAt: previewNow, days: previewHistoryDays },
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
    relaunch: async () => preview,
    quit: async () => preview,
    onStateChanged: () => () => {},
  };
}

createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
