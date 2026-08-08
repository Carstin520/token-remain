import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { compactNumber, formatMoney, formatPercent } from "./format.js";
import { AlertIcon, ArrowUpRightIcon, CheckCircleIcon, PlusIcon, RefreshIcon, ResetIcon } from "./icons.jsx";
import { LIMITS_ORDER_KEY, peekStoredOrder } from "./layout.js";
import { buildPopoverModel } from "./popover-model.js";
import "./popover.css";

const PROVIDER_ICON_MODULES = import.meta.glob("../../site/assets/providers/*.{svg,png}", { eager: true, import: "default" });
const PROVIDER_ICONS = Object.fromEntries(Object.entries(PROVIDER_ICON_MODULES).map(([path, url]) => [path.split("/").pop(), url]));
const FEED_ACCENT = { token_reset: "var(--cyan)", major_update: "var(--violet-dim)" };
const CLOCK_INTERVAL_MS = 60_000;
const SEGMENTS = 14;

const api = globalThis.tokenRemain;

// Main only asks for acrylic on Windows 11 22H2+; everywhere else the surface
// stays opaque, so the popover reads the same on every supported build.
if (new URLSearchParams(globalThis.location?.search || "").get("material") === "acrylic") {
  document.documentElement.dataset.material = "acrylic";
}

function App() {
  const [state, setState] = useState();
  const [visible, setVisible] = useState(false);
  const [tick, setTick] = useState(() => Date.now());
  const [error, setError] = useState();
  const rootRef = useRef(null);
  const headerRef = useRef(null);
  const scrollRef = useRef(null);
  const footerRef = useRef(null);
  const contentRef = useRef(null);
  const frameRef = useRef(0);

  useEffect(() => {
    api.getState().then(setState).catch((reason) => setError(reason.message));
    return api.onStateChanged(setState);
  }, []);

  // Hidden popovers keep receiving state so the next open paints cached data
  // immediately, but they stop re-rendering relative timestamps every minute.
  useEffect(() => api.onPopoverVisibility?.(setVisible), []);
  useEffect(() => {
    if (!visible) return undefined;
    setTick(Date.now());
    const timer = setInterval(() => setTick(Date.now()), CLOCK_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [visible]);

  useEffect(() => api.onPopoverShown?.(() => {
    setVisible(true);
    setError(undefined);
    scrollRef.current?.scrollTo({ top: 0 });
    rootRef.current?.focus({ preventScroll: true });
  }), []);

  useEffect(() => {
    const onKeyDown = (event) => {
      if (event.key === "Escape") { event.preventDefault(); api.hidePopover?.(); }
    };
    globalThis.addEventListener("keydown", onKeyDown);
    return () => globalThis.removeEventListener("keydown", onKeyDown);
  }, []);

  // The window follows the content's natural height, which the scroll region's
  // own height cannot report once it has been stretched to fill the window.
  const measure = useCallback(() => {
    cancelAnimationFrame(frameRef.current);
    frameRef.current = requestAnimationFrame(() => {
      const scroller = scrollRef.current;
      const content = contentRef.current;
      if (!scroller || !content) return;
      const style = getComputedStyle(scroller);
      const inset = Number.parseFloat(style.paddingTop) + Number.parseFloat(style.paddingBottom);
      const chrome = (headerRef.current?.offsetHeight || 0) + (footerRef.current?.offsetHeight || 0);
      api.resizePopover?.(Math.ceil(chrome + content.offsetHeight + inset + 2));
    });
  }, []);

  useEffect(() => {
    const element = contentRef.current;
    if (!element || typeof ResizeObserver === "undefined") return undefined;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => { observer.disconnect(); cancelAnimationFrame(frameRef.current); };
  }, [measure, Boolean(state)]);

  const model = useMemo(() => (state ? buildPopoverModel(state, {
    now: tick,
    storedOrder: peekStoredOrder(globalThis.localStorage, LIMITS_ORDER_KEY),
  }) : undefined), [state, tick]);

  async function run(operation) {
    setError(undefined);
    try { await operation(); }
    catch (reason) { setError(reason.message); }
  }

  const openDashboard = (section) => run(() => api.openDashboard(section));

  if (!model) return <div className="popover-loading">Loading TokenRemain…</div>;
  return (
    <div className="popover-root" ref={rootRef} tabIndex={-1} role="dialog" aria-label="TokenRemain quick view">
      <header className="popover-header" ref={headerRef}>
        <span className="popover-brand">Token<b>Remain</b></span>
        <span className="popover-updated" title={model.updatedLabel}>{model.updatedLabel}</span>
        <button
          className="icon-button"
          onClick={() => openDashboard("limits")}
          aria-label="Add or manage providers"
          title="Add or manage providers in Limits"
        >
          <PlusIcon />
        </button>
        <button
          className="icon-button"
          onClick={() => run(api.refresh)}
          disabled={model.isRefreshing}
          aria-label={model.isRefreshing ? "Refreshing usage" : "Refresh usage"}
          title="Refresh quotas, synced usage, and the AI Feed"
        >
          <RefreshIcon spinning={model.isRefreshing} />
        </button>
      </header>

      <div className="popover-scroll" ref={scrollRef}>
        <div className="popover-sections" ref={contentRef}>
          {error && <div className="popover-error" role="alert">{error}</div>}
          <RiskStrip risk={model.risk} />
          <QuotaSection quota={model.quota} notice={model.quotaNotice} onOpen={() => openDashboard("limits")} />
          <UsageSection usage={model.usage} empty={model.usageEmpty} onOpen={() => openDashboard("trends")} />
          <FeedSection feed={model.feed} onOpen={openDashboard} onOpenPost={(url) => run(() => api.openExternal(url))} />
        </div>
      </div>

      <footer className="popover-footer" ref={footerRef}>
        <button className="footer-dashboard" onClick={() => openDashboard("overview")} title="Open the full TokenRemain dashboard">
          Open Dashboard
        </button>
        <button className="footer-secondary" onClick={() => openDashboard("settings")} title="Open dashboard settings">
          Settings
        </button>
        <span className="footer-spacer" />
        <button className="footer-quit" onClick={() => run(api.quit)} title="Quit TokenRemain">Quit</button>
      </footer>
    </div>
  );
}

// MARK: - Risk

function RiskStrip({ risk }) {
  const tone = risk.level || "unknown";
  return (
    <section className="popover-card popover-risk" aria-label="Quota risk">
      <div className="popover-risk-head">
        <span className={`badge tone-${tone} ${tone === "high" ? "filled" : ""}`}>{risk.badge}</span>
        <strong title={risk.headline}>{risk.headline}</strong>
      </div>
      {risk.detail && (
        <p className={`popover-risk-detail tone-${tone}`}>
          {tone === "low" ? <CheckCircleIcon /> : <AlertIcon />}
          <span title={risk.windowLabel}>{risk.detail}</span>
        </p>
      )}
      {risk.projection && (
        <p className="popover-risk-detail tone-medium">
          <ResetIcon />
          <span title={risk.projection}>{risk.projection}</span>
        </p>
      )}
    </section>
  );
}

// MARK: - Provider quota

function QuotaSection({ quota, notice, onOpen }) {
  if (!quota.length) {
    return (
      <section className="popover-card" aria-label="Official quota">
        <div className="popover-card-head"><h2>Official Quota</h2></div>
        <p className="popover-empty">
          <strong>{notice || "Reading official quota…"}</strong>
          Claude and Codex snapshots appear here as soon as this PC or your paired Mac reports one.
        </p>
      </section>
    );
  }
  return (
    <div className="popover-quota">
      {quota.map((card) => <QuotaCard key={card.id} card={card} onOpen={onOpen} />)}
    </div>
  );
}

function QuotaCard({ card, onOpen }) {
  const accent = card.remaining < 10 ? "var(--danger)" : card.color;
  const icon = PROVIDER_ICONS[card.iconFile];
  const healthy = card.level === "low" && !card.aheadOfPace;
  const riskTone = card.level === "high" ? "high" : card.level === "medium" || card.aheadOfPace ? "medium" : "low";
  const riskTitle = card.aheadOfPace
    ? "Current usage is ahead of pace"
    : card.level === "high" ? "Quota is nearly depleted"
      : card.level === "medium" ? "Watch your usage pace" : "Usage pace is healthy";
  return (
    <button
      className="popover-quota-card"
      onClick={onOpen}
      title={`${card.name} · ${card.windowTitle} · ${card.remainingText}. Open Limits for every window.`}
    >
      <span className="popover-quota-head">
        {icon
          ? <img src={icon} alt="" />
          : <span className="provider-mark-fallback" aria-hidden="true">{card.name.slice(0, 2).toUpperCase()}</span>}
        <span className="quota-name">{card.name}</span>
        {healthy
          ? <CheckCircleIcon className={`risk-mark tone-${riskTone}`} title={riskTitle} />
          : <AlertIcon className={`risk-mark tone-${riskTone}`} title={riskTitle} />}
        <strong>{card.remainingText}</strong>
      </span>
      <SegmentBar remaining={card.remaining} accent={accent} label={`${card.name} ${card.windowTitle}`} />
      <span className="popover-quota-meta">
        <span title={card.windowTitle}>{card.windowTitle}</span>
        <span title={card.resetText}>{card.resetText}</span>
      </span>
      {card.notice && (
        <span className="popover-quota-notice"><AlertIcon /><span title={card.notice}>{card.notice}</span></span>
      )}
    </button>
  );
}

/// The Mac SegmentBar: any non-zero remainder lights at least one cell so a
/// nearly-empty window never reads as fully depleted.
function SegmentBar({ remaining, accent, label }) {
  const clamped = Math.min(100, Math.max(0, remaining));
  const raw = clamped / 100 * SEGMENTS;
  const filled = clamped > 0 && raw < 1 ? 1 : Math.min(SEGMENTS, Math.round(raw));
  return (
    <span
      className="segment-bar"
      style={{ height: 5 }}
      role="meter"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(clamped)}
      aria-valuetext={`${formatPercent(clamped)} remaining`}
      aria-label={`${label} quota remaining`}
    >
      {Array.from({ length: SEGMENTS }, (_, index) => (
        <i key={index} style={index < filled ? { background: accent } : undefined} />
      ))}
    </span>
  );
}

// MARK: - Today's local usage

function UsageSection({ usage, empty, onOpen }) {
  if (!usage) {
    return (
      <section className="popover-card" aria-label="Today's local usage">
        <div className="popover-card-head"><h2>Today's Local Usage</h2></div>
        <p className="popover-empty"><strong>{empty.title}</strong>{empty.message}</p>
      </section>
    );
  }
  const peak = Math.max(1, ...usage.trend.map((point) => point.tokens));
  return (
    <section className="popover-card" aria-label="Today's local usage">
      <div className="popover-card-head">
        <h2>Today's Local Usage</h2>
        <strong title={usage.today.label}>
          {Number.isFinite(usage.today.cost) ? formatMoney(usage.today.cost) : "Price unavailable"}
        </strong>
      </div>
      <div className="popover-usage-rows">
        {usage.entries.map((entry) => (
          <div className="popover-usage-row" key={entry.id}>
            <i style={{ background: entry.color }} />
            <span>{entry.displayName}</span>
            <em>{compactNumber(entry.tokens)}</em>
            <b>{Number.isFinite(entry.tokenShare) ? formatPercent(Math.round(entry.tokenShare)) : "—"}</b>
          </div>
        ))}
      </div>
      <div className="popover-spend">
        <SpendRow label="Today" bucket={usage.today} />
        <SpendRow label="Yesterday" bucket={usage.yesterday} />
        <SpendRow label="Last 30 Days" bucket={usage.last30Days} />
      </div>
      {usage.trend.length >= 2 && (
        <div className="popover-trend-row">
          <span id="popover-trend-label">Usage Trend</span>
          <div className="popover-trend" role="img" aria-labelledby="popover-trend-label">
            {usage.trend.map((point, index) => (
              <i
                key={point.day}
                className={point.tokens > 0 ? (index === usage.trend.length - 1 ? "is-latest" : undefined) : "is-zero"}
                style={point.tokens > 0 ? { height: `${Math.max(8, point.tokens / peak * 100)}%` } : undefined}
                title={`${point.day}: ${compactNumber(point.tokens)} tokens`}
              />
            ))}
          </div>
          <button className="link-button" onClick={onOpen} title="Open the full usage trend">View all</button>
        </div>
      )}
    </section>
  );
}

function SpendRow({ label, bucket }) {
  return (
    <div className="popover-spend-row">
      <span>{label}</span>
      <strong title={bucket.hasData ? bucket.label : "No synced data for this period"}>{bucket.label}</strong>
    </div>
  );
}

// MARK: - AI Feed

function FeedSection({ feed, onOpen, onOpenPost }) {
  return (
    <section className="popover-card" aria-label="AI Feed">
      <div className="popover-card-head">
        <h2>AI Feed · Important updates</h2>
        {feed.status && <span className={`badge tone-${feed.cached ? "medium" : "cyan"}`} title={feed.error || feed.status}>{feed.status}</span>}
        <button className="link-button" onClick={() => onOpen("overview")} title="Open the full AI Feed">View all</button>
      </div>
      {feed.items.length ? (
        <div className="popover-feed">
          {feed.items.map((item) => (
            <button className="popover-feed-row" key={item.id} onClick={() => onOpenPost(item.url)} title={item.title}>
              <span className="popover-feed-meta">
                <i style={{ background: FEED_ACCENT[item.priority] || "var(--muted)" }} />
                <b>{item.source}</b>
                <time>{item.age}</time>
                {item.priorityLabel && <span className="feed-priority">{item.priorityLabel}</span>}
                <span className="open-arrow"><ArrowUpRightIcon /></span>
              </span>
              <p>{item.title}</p>
            </button>
          ))}
        </div>
      ) : (
        <p className="popover-empty">
          <strong>{feed.error ? "Feed is temporarily unavailable" : "Finding updates worth your attention…"}</strong>
          {feed.error || "Quota, pricing, and service-status updates appear here automatically."}
        </p>
      )}
    </section>
  );
}

if (api) createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
else document.getElementById("root").textContent = "TokenRemain popover requires the desktop app.";
