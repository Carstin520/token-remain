import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { compactNumber, formatMoney, formatPercent } from "./format.js";
import {
  AlertIcon,
  ArrowUpRightIcon,
  CheckCircleIcon,
  ChevronRightIcon,
  MoreIcon,
  PlusIcon,
  RefreshIcon,
  ResetIcon,
} from "./icons.jsx";
import { DirectReorderGrid } from "./direct-reorder.jsx";
import { LIMITS_ORDER_KEY, peekStoredOrder } from "./layout.js";
import {
  AI_FEED_WIDGET_ID,
  LOCAL_USAGE_WIDGET_ID,
  POPOVER_LAYOUT_KEY,
  canPinWidget,
  isWidgetPinned,
  moveVisibleWidget,
  normalizeLayout,
  reorderVisibleWidgets,
  restorablePinnedIDs,
  setWidgetHidden,
  toggleWidgetPinned,
  visibleWidgetIDs,
  writeStoredLayout,
} from "./popover-layout.js";
import { buildPopoverModel } from "./popover-model.js";
import { createPopoverPreviewAPI } from "./popover-preview.js";
import { feedSummaryText, providerSummaryText, usageSummaryText } from "./popover-summary.js";
import { usageRingSegmentAtPoint, usageRingStops } from "./popover-usage.js";
import "./popover.css";

const PROVIDER_ICON_MODULES = import.meta.glob("../../site/assets/providers/*.{svg,png}", { eager: true, import: "default" });
const PROVIDER_ICONS = Object.fromEntries(Object.entries(PROVIDER_ICON_MODULES).map(([path, url]) => [path.split("/").pop(), url]));
const FEED_ACCENT = { token_reset: "var(--cyan)", major_update: "var(--violet-dim)" };
const CLOCK_INTERVAL_MS = 60_000;
const COPIED_FEEDBACK_MS = 2_000;
const SEGMENTS = 14;
const BUILTIN_WIDGET_TITLES = {
  [LOCAL_USAGE_WIDGET_ID]: "Today's Local Usage",
  [AI_FEED_WIDGET_ID]: "AI Feed",
};

// The real preload bridge always wins; the synthetic preview API only exists
// in Vite dev so /popover.html can be inspected without Electron. A production
// build without the preload still shows the requires-desktop-app message.
const api = globalThis.tokenRemain ?? (import.meta.env.DEV ? createPopoverPreviewAPI() : undefined);

// Main only asks for acrylic on Windows 11 22H2+; everywhere else the surface
// stays opaque, so the popover reads the same on every supported build.
if (new URLSearchParams(globalThis.location?.search || "").get("material") === "acrylic") {
  document.documentElement.dataset.material = "acrylic";
}

/// The stored layout as-is, unrepaired: providers arrive asynchronously, so the
/// raw shape must survive until they do or a custom order would be flattened.
function readRawLayout(storage) {
  try {
    return JSON.parse(storage?.getItem(POPOVER_LAYOUT_KEY) || "null");
  } catch {
    return null;
  }
}

function App() {
  const [state, setState] = useState();
  const [visible, setVisible] = useState(false);
  const [tick, setTick] = useState(() => Date.now());
  const [error, setError] = useState();
  const [savedLayout, setSavedLayout] = useState(() => readRawLayout(globalThis.localStorage));
  const [expandedIDs, setExpandedIDs] = useState(() => restorablePinnedIDs(readRawLayout(globalThis.localStorage)));
  const [openMenu, setOpenMenu] = useState(null);
  const [copiedID, setCopiedID] = useState(null);
  const rootRef = useRef(null);
  const headerRef = useRef(null);
  const scrollRef = useRef(null);
  const footerRef = useRef(null);
  const contentRef = useRef(null);
  const frameRef = useRef(0);
  const copyTimerRef = useRef(0);
  // The raw durable layout, readable from stable event handlers. The shown
  // handler restores pins from this rather than the normalized layout, which
  // would drop provider pins whenever provider data has not arrived yet.
  const savedLayoutRef = useRef(savedLayout);
  savedLayoutRef.current = savedLayout;
  const openMenuRef = useRef(null);
  openMenuRef.current = openMenu;

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

  // Each open starts from the persisted pins: session-only expansions collapse
  // back, pinned widgets come back expanded.
  useEffect(() => api.onPopoverShown?.(() => {
    setVisible(true);
    setError(undefined);
    setOpenMenu(null);
    setExpandedIDs(restorablePinnedIDs(savedLayoutRef.current));
    scrollRef.current?.scrollTo({ top: 0 });
    rootRef.current?.focus({ preventScroll: true });
  }), []);

  // Escape backs out one layer at a time: an open menu closes first, and only
  // a second press dismisses the popover itself.
  useEffect(() => {
    const onKeyDown = (event) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      if (openMenuRef.current) setOpenMenu(null);
      else api.hidePopover?.();
    };
    globalThis.addEventListener("keydown", onKeyDown);
    return () => globalThis.removeEventListener("keydown", onKeyDown);
  }, []);

  useEffect(() => {
    if (!openMenu) return undefined;
    const onPointerDown = (event) => {
      if (!event.target?.closest?.("[data-menu-root]")) setOpenMenu(null);
    };
    document.addEventListener("pointerdown", onPointerDown, true);
    return () => document.removeEventListener("pointerdown", onPointerDown, true);
  }, [openMenu]);

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
    quotaLimit: Number.POSITIVE_INFINITY,
    storedOrder: peekStoredOrder(globalThis.localStorage, LIMITS_ORDER_KEY),
  }) : undefined), [state, tick]);

  const providerIDs = useMemo(() => (model?.quota || []).map((card) => card.id), [model]);
  const layout = useMemo(
    () => normalizeLayout(savedLayout, providerIDs),
    [savedLayout, providerIDs.join("|")], // eslint-disable-line react-hooks/exhaustive-deps
  );

  const updateLayout = useCallback((mutate) => {
    setSavedLayout((previous) => {
      const next = mutate(normalizeLayout(previous, providerIDs));
      writeStoredLayout(globalThis.localStorage, next);
      return next;
    });
  }, [providerIDs]);

  function toggleExpanded(id) {
    const wasExpanded = expandedIDs.includes(id);
    setExpandedIDs((previous) => (wasExpanded ? previous.filter((entry) => entry !== id) : [...previous, id]));
    // Collapsing a pinned widget is a statement it should stay collapsed.
    if (wasExpanded && isWidgetPinned(layout, id)) updateLayout((current) => toggleWidgetPinned(current, id));
  }

  function togglePinned(id) {
    const willPin = !isWidgetPinned(layout, id);
    updateLayout((current) => toggleWidgetPinned(current, id));
    if (willPin) setExpandedIDs((previous) => (previous.includes(id) ? previous : [...previous, id]));
  }

  function hideWidget(id) {
    updateLayout((current) => setWidgetHidden(current, id, true));
    setExpandedIDs((previous) => previous.filter((entry) => entry !== id));
  }

  async function run(operation) {
    setError(undefined);
    try { await operation(); }
    catch (reason) { setError(reason.message); }
  }

  async function copySummary(id, text) {
    setError(undefined);
    try {
      await api.copyText(text);
      setCopiedID(id);
      clearTimeout(copyTimerRef.current);
      copyTimerRef.current = setTimeout(() => setCopiedID(null), COPIED_FEEDBACK_MS);
    } catch (reason) {
      setError(reason.message);
    }
  }

  const openDashboard = (section) => run(() => api.openDashboard(section));

  if (!model) return <div className="popover-loading">Loading TokenRemain…</div>;

  const visibleIDs = visibleWidgetIDs(layout);
  const widgetName = (id) => BUILTIN_WIDGET_TITLES[id] || model.quota.find((card) => card.id === id)?.name || id;

  /// Shared overflow-menu entries for one reorderable widget, in the fixed
  /// Copy / pin / expand / move / hide order.
  function widgetMenuItems(id, summaryText) {
    const index = visibleIDs.indexOf(id);
    const expandable = canPinWidget(id);
    const pinned = isWidgetPinned(layout, id);
    const expanded = expandedIDs.includes(id);
    return [
      { key: "copy", label: "Copy Summary", onSelect: () => copySummary(id, summaryText) },
      ...(expandable ? [
        { key: "pin", label: pinned ? "Unpin" : "Pin Expanded", onSelect: () => togglePinned(id) },
        { key: "expand", label: expanded ? "Collapse" : "Expand", onSelect: () => toggleExpanded(id) },
      ] : []),
      { key: "up", label: "Move Up", disabled: index <= 0, onSelect: () => updateLayout((current) => moveVisibleWidget(current, id, -1)) },
      { key: "down", label: "Move Down", disabled: index < 0 || index >= visibleIDs.length - 1, onSelect: () => updateLayout((current) => moveVisibleWidget(current, id, +1)) },
      { key: "hide", label: "Hide", onSelect: () => hideWidget(id) },
    ];
  }

  const addItems = layout.hidden.length
    ? layout.hidden.map((id) => ({
      key: id,
      label: `Show ${widgetName(id)}`,
      onSelect: () => updateLayout((current) => setWidgetHidden(current, id, false)),
    }))
    : [{ key: "none", label: "All widgets are visible", disabled: true }];

  const widgetProps = (id, summaryText) => ({
    menu: {
      id,
      label: `${widgetName(id)} options`,
      items: widgetMenuItems(id, summaryText),
      open: openMenu === id,
      onOpenChange: (wantOpen) => setOpenMenu(wantOpen ? id : null),
    },
    copied: copiedID === id,
  });

  return (
    <div className="popover-root" ref={rootRef} tabIndex={-1} role="dialog" aria-label="TokenRemain quick view">
      <span className="sr-only" aria-live="polite">{copiedID ? "Summary copied to clipboard" : ""}</span>
      <header className="popover-header" ref={headerRef}>
        <span className="popover-brand">Token<b>Remain</b></span>
        <span className="popover-updated" title={model.updatedLabel}>{model.updatedLabel}</span>
        <Dropdown
          id="add-widget"
          label="Show a hidden widget"
          title={layout.hidden.length ? "Show a hidden widget" : "All widgets are visible"}
          icon={<PlusIcon />}
          items={addItems}
          open={openMenu === "add-widget"}
          onOpenChange={(wantOpen) => setOpenMenu(wantOpen ? "add-widget" : null)}
        />
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
          {!providerIDs.length && (
            <section className="popover-card" aria-label="Official quota">
              <div className="popover-card-head"><h2>Official Quota</h2></div>
              <p className="popover-empty">
                <strong>{model.quotaNotice || "Reading official quota…"}</strong>
                Claude and Codex snapshots appear here as soon as this PC or your paired Mac reports one.
              </p>
            </section>
          )}
          <DirectReorderGrid
            className="popover-reorder"
            order={visibleIDs}
            onOrderChange={(next) => updateLayout((current) => reorderVisibleWidgets(current, next))}
            renderItem={(id) => {
            if (id === LOCAL_USAGE_WIDGET_ID) {
              return (
                <UsageWidget
                  usage={model.usage}
                  empty={model.usageEmpty}
                  onOpen={() => openDashboard("trends")}
                  {...widgetProps(id, usageSummaryText(model.usage, model.usageEmpty))}
                />
              );
            }
            if (id === AI_FEED_WIDGET_ID) {
              return (
                <FeedWidget
                  feed={model.feed}
                  expanded={expandedIDs.includes(id)}
                  onToggleExpanded={() => toggleExpanded(id)}
                  onOpen={() => openDashboard("overview")}
                  onOpenPost={(url) => run(() => api.openExternal(url))}
                  {...widgetProps(id, feedSummaryText(model.feed))}
                />
              );
            }
            const card = model.quota.find((entry) => entry.id === id);
            if (!card) return null;
            return (
              <QuotaWidget
                card={card}
                expanded={expandedIDs.includes(id)}
                onToggleExpanded={() => toggleExpanded(id)}
                {...widgetProps(id, providerSummaryText(card))}
              />
            );
          }}
          />
        </div>
      </div>

      <footer className="popover-footer" ref={footerRef}>
        <button className="footer-dashboard" onClick={() => openDashboard("overview")} title="Open the full TokenRemain dashboard">
          Open Dashboard
        </button>
        <Dropdown
          id="footer-settings"
          label="Settings"
          title="Launch, settings, and restart options"
          triggerClassName="footer-secondary"
          icon="Settings"
          items={[
            {
              key: "launch",
              label: "Launch at login",
              checked: Boolean(state.launchAtLogin),
              onSelect: () => run(() => api.setLaunchAtLogin(!state.launchAtLogin)),
            },
            {
              key: "floating",
              label: "Floating shortcut",
              checked: Boolean(state.floatingWidgetEnabled),
              onSelect: () => run(() => api.setFloatingWidgetEnabled(!state.floatingWidgetEnabled)),
            },
            { key: "open-settings", label: "Open Settings", onSelect: () => openDashboard("settings") },
            { key: "relaunch", label: "Restart TokenRemain", onSelect: () => run(api.relaunch) },
          ]}
          open={openMenu === "footer-settings"}
          onOpenChange={(wantOpen) => setOpenMenu(wantOpen ? "footer-settings" : null)}
        />
        <span className="footer-spacer" />
        <button className="footer-quit" onClick={() => run(api.quit)} title="Quit TokenRemain">Quit</button>
      </footer>
    </div>
  );
}

// MARK: - Menus

/// One anchored dropdown: a trigger button plus, while open, an accessible
/// menu that supports arrow-key navigation, Escape-to-close, and flips upward
/// when the bottom of the window would clip it.
function Dropdown({ id, label, title, icon, items, open, onOpenChange, triggerClassName }) {
  const wrapRef = useRef(null);
  const triggerRef = useRef(null);
  const [opensUp, setOpensUp] = useState(false);

  useEffect(() => {
    if (!open) return;
    const rect = wrapRef.current?.getBoundingClientRect();
    const estimated = items.length * 30 + 12;
    setOpensUp(Boolean(rect && globalThis.innerHeight - rect.bottom < estimated && rect.top > estimated));
    wrapRef.current?.querySelector("[role^=menuitem]:not(:disabled)")?.focus();
  }, [open, items.length]);

  const focusables = () => [...(wrapRef.current?.querySelectorAll("[role^=menuitem]:not(:disabled)") || [])];

  const onKeyDown = (event) => {
    if (!open) return;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onOpenChange(false);
      triggerRef.current?.focus();
      return;
    }
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const options = focusables();
    if (!options.length) return;
    const index = options.indexOf(document.activeElement);
    const next = event.key === "Home" ? 0
      : event.key === "End" ? options.length - 1
        : (index + (event.key === "ArrowDown" ? 1 : -1) + options.length) % options.length;
    options[next].focus();
  };

  return (
    <span className="menu-wrap" data-menu-root ref={wrapRef} onKeyDown={onKeyDown}>
      <button
        ref={triggerRef}
        className={triggerClassName || "icon-button"}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? `${id}-menu` : undefined}
        aria-label={label}
        title={title || label}
        onClick={() => onOpenChange(!open)}
      >
        {icon}
      </button>
      {open && (
        <div className={`menu-pop ${opensUp ? "menu-up" : ""}`} role="menu" id={`${id}-menu`} aria-label={label}>
          {items.map((item) => (
            <button
              key={item.key}
              role={item.checked === undefined ? "menuitem" : "menuitemcheckbox"}
              aria-checked={item.checked === undefined ? undefined : item.checked}
              className={item.checked === undefined ? "menu-item" : "menu-item menu-item-check"}
              disabled={item.disabled}
              onClick={() => {
                onOpenChange(false);
                triggerRef.current?.focus();
                item.onSelect?.();
              }}
            >
              {item.label}
            </button>
          ))}
        </div>
      )}
    </span>
  );
}

/// The control cluster every reorderable widget shows in its header: the
/// transient Copied chip, an optional expand chevron, and the overflow menu.
function WidgetControls({ menu, copied, expandable, expanded, onToggleExpanded, expandLabel }) {
  return (
    <span className="widget-controls">
      {copied && <span className="copied-chip" aria-hidden="true">Copied</span>}
      {expandable && (
        <button
          className="icon-button"
          aria-expanded={expanded}
          aria-label={expanded ? `Collapse ${expandLabel}` : `Expand ${expandLabel}`}
          title={expanded ? `Collapse ${expandLabel}` : `Expand ${expandLabel}`}
          onClick={onToggleExpanded}
        >
          <ChevronRightIcon className={expanded ? "chevron is-open" : "chevron"} />
        </button>
      )}
      <Dropdown
        id={menu.id}
        label={menu.label}
        icon={<MoreIcon />}
        items={menu.items}
        open={menu.open}
        onOpenChange={menu.onOpenChange}
      />
    </span>
  );
}

function widgetContextMenu(menu) {
  return (event) => {
    event.preventDefault();
    menu.onOpenChange(true);
  };
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

/// Risk-and-pace cue for one quota window, spelled out so colour never carries
/// the meaning alone.
function windowRiskCue(window) {
  const healthy = window.level === "low" && !window.aheadOfPace;
  const tone = window.level === "high" ? "high" : window.level === "medium" || window.aheadOfPace ? "medium" : "low";
  const title = window.aheadOfPace
    ? "Current usage is ahead of pace"
    : window.level === "high" ? "Quota is nearly depleted"
      : window.level === "medium" ? "Watch your usage pace" : "Usage pace is healthy";
  return { healthy, tone, title };
}

function QuotaWidget({ card, expanded, onToggleExpanded, menu, copied }) {
  const accent = card.remaining < 10 ? "var(--danger)" : card.color;
  const icon = PROVIDER_ICONS[card.iconFile];
  const cue = windowRiskCue(card);
  return (
    <section className="popover-card popover-widget" aria-label={`${card.name} quota`} onContextMenu={widgetContextMenu(menu)}>
      <div className="widget-head">
        <button
          className="quota-summary-toggle"
          aria-expanded={expanded}
          onClick={onToggleExpanded}
          title={`${card.name} · ${card.windowTitle} · ${card.remainingText}. ${expanded ? "Collapse" : "Expand"} to ${expanded ? "hide" : "see"} every window.`}
        >
          {icon
            ? <img src={icon} alt="" />
            : <span className="provider-mark-fallback" aria-hidden="true">{card.name.slice(0, 2).toUpperCase()}</span>}
          <span className="quota-name">{card.name}</span>
          {cue.healthy
            ? <CheckCircleIcon className={`risk-mark tone-${cue.tone}`} title={cue.title} />
            : <AlertIcon className={`risk-mark tone-${cue.tone}`} title={cue.title} />}
          <strong>{card.remainingText}</strong>
        </button>
        <WidgetControls
          menu={menu}
          copied={copied}
          expandable
          expanded={expanded}
          onToggleExpanded={onToggleExpanded}
          expandLabel={`${card.name} windows`}
        />
      </div>
      <SegmentBar remaining={card.remaining} accent={accent} label={`${card.name} ${card.windowTitle}`} />
      <span className="popover-quota-meta">
        {/* The summary row is the Mac's stable first window: expanding never
            repeats it below, it only enriches this row with the pace read. */}
        <span title={expanded ? `${card.windowTitle} · ${cue.title}` : card.windowTitle}>
          {expanded ? `${card.windowTitle} · ${cue.title}` : card.windowTitle}
        </span>
        <span title={card.resetText}>{card.resetText}</span>
      </span>
      {card.notice && (
        <span className="popover-quota-notice"><AlertIcon /><span title={card.notice}>{card.notice}</span></span>
      )}
      {expanded && (
        <div className="quota-windows">
          {[...card.windows.slice(1), ...(card.scopedWindows || [])].map((window) => {
            const windowCue = windowRiskCue(window);
            return (
              <div className="quota-window" key={window.key}>
                <span className="quota-window-head">
                  <span className="quota-window-title">{window.title}</span>
                  {windowCue.healthy
                    ? <CheckCircleIcon className={`risk-mark tone-${windowCue.tone}`} title={windowCue.title} />
                    : <AlertIcon className={`risk-mark tone-${windowCue.tone}`} title={windowCue.title} />}
                  <strong>{window.remainingText}</strong>
                </span>
                <SegmentBar
                  remaining={window.remaining}
                  accent={window.remaining < 10 ? "var(--danger)" : card.color}
                  label={`${card.name} ${window.title}`}
                />
                <span className="popover-quota-meta">
                  <span title={windowCue.title}>{windowCue.title}</span>
                  <span title={window.resetText}>{window.resetText}</span>
                </span>
              </div>
            );
          })}
          {card.capturedText && (
            <span
              className={card.capturedStale ? "quota-captured is-stale" : "quota-captured"}
              title={card.capturedStale ? "Snapshot is more than 10 minutes old" : card.capturedText}
            >
              {card.capturedStale ? <AlertIcon /> : <CheckCircleIcon />}
              <span>{card.capturedText}</span>
            </span>
          )}
        </div>
      )}
    </section>
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

function UsageWidget({ usage, empty, onOpen, menu, copied }) {
  const [highlightedUsageID, setHighlightedUsageID] = useState(null);
  if (!usage) {
    return (
      <section className="popover-card popover-widget" aria-label="Today's local usage" onContextMenu={widgetContextMenu(menu)}>
        <div className="widget-head popover-card-head">
          <h2>Today's Local Usage</h2>
          <WidgetControls menu={menu} copied={copied} />
        </div>
        <p className="popover-empty"><strong>{empty.title}</strong>{empty.message}</p>
      </section>
    );
  }
  const peak = Math.max(1, ...usage.trend.map((point) => point.tokens));
  const highlightedEntry = usage.entries.find((entry) => entry.id === highlightedUsageID);
  return (
    <section className="popover-card popover-widget" aria-label="Today's local usage" onContextMenu={widgetContextMenu(menu)}>
      <div className="widget-head popover-card-head">
        <h2>Today's Local Usage</h2>
        <strong title={usage.today.label}>
          {Number.isFinite(usage.today.cost) ? formatMoney(usage.today.cost) : "Price unavailable"}
        </strong>
        <WidgetControls menu={menu} copied={copied} />
      </div>
      <div className="popover-usage-composition" onPointerLeave={() => setHighlightedUsageID(null)}>
        <div
          className="popover-usage-ring"
          style={{ background: `conic-gradient(${usageRingStops(usage.entries, highlightedUsageID)})` }}
          role="img"
          aria-label={`Token usage by provider: ${usage.entries.map((entry) => `${entry.displayName} ${formatPercent(Math.round(entry.tokenShare))}`).join(", ")}`}
          onPointerMove={(event) => {
            const rect = event.currentTarget.getBoundingClientRect();
            setHighlightedUsageID(usageRingSegmentAtPoint(
              usage.entries,
              { x: event.clientX - rect.left, y: event.clientY - rect.top },
              Math.min(rect.width, rect.height),
            ));
          }}
        >
          <span className="popover-usage-ring-center" aria-hidden="true">
            {highlightedEntry && (
              <>
                <strong>{Number.isFinite(usage.today.cost) ? formatMoney(highlightedEntry.cost) : "—"}</strong>
                <small>{compactNumber(highlightedEntry.tokens)}</small>
              </>
            )}
          </span>
        </div>
        <div className="popover-usage-rows" role="list" aria-label="Provider usage shares">
          {usage.entries.map((entry) => (
            <div
              className={`popover-usage-row ${highlightedUsageID === entry.id ? "is-highlighted" : ""}`}
              key={entry.id}
              role="listitem"
              tabIndex={0}
              aria-label={`${entry.displayName}, ${compactNumber(entry.tokens)} tokens, ${formatPercent(Math.round(entry.tokenShare))}`}
              style={{ "--provider-color": entry.color }}
              onFocus={() => setHighlightedUsageID(entry.id)}
              onBlur={() => setHighlightedUsageID(null)}
              onPointerEnter={() => setHighlightedUsageID(entry.id)}
            >
              <i style={{ background: entry.color }} />
              <span>{entry.displayName}</span>
              <em>{compactNumber(entry.tokens)}</em>
              <b>{Number.isFinite(entry.tokenShare) ? formatPercent(Math.round(entry.tokenShare)) : "—"}</b>
            </div>
          ))}
        </div>
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

function FeedWidget({ feed, expanded, onToggleExpanded, onOpen, onOpenPost, menu, copied }) {
  return (
    <section className="popover-card popover-widget" aria-label="AI Feed" onContextMenu={widgetContextMenu(menu)}>
      <div className="widget-head popover-card-head">
        <h2>AI Feed · Important updates</h2>
        {feed.status && <span className={`badge tone-${feed.cached ? "medium" : "cyan"}`} title={feed.error || feed.status}>{feed.status}</span>}
        <button className="link-button" onClick={onOpen} title="Open the full AI Feed">View all</button>
        <WidgetControls
          menu={menu}
          copied={copied}
          expandable
          expanded={expanded}
          onToggleExpanded={onToggleExpanded}
          expandLabel="AI Feed stories"
        />
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
              <p className={expanded ? "is-expanded" : undefined}>{item.title}</p>
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
