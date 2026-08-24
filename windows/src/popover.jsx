import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { compactNumber, formatMoney, formatPercent } from "./format.js";
import {
  AlertIcon,
  ArrowUpRightIcon,
  CheckCircleIcon,
  CheckIcon,
  ChevronRightIcon,
  CloseIcon,
  FeedIcon,
  MoreIcon,
  PinIcon,
  PlusIcon,
  RefreshIcon,
  ResetIcon,
} from "./icons.jsx";
import { DirectReorderGrid } from "./direct-reorder.jsx";
import { GlassChip, GlassCircle, GlassProvider, GlassSurface } from "./glass/GlassSurface.jsx";
import {
  adaptiveShadowOpacity,
  backdropOpacityPercent,
  needsAdaptiveForeground,
  normalizeBackdropMode,
  normalizeBackdropOpacity,
  normalizeGlassStyle,
} from "./glass/glass-model.js";
import { activateLanguage, SYSTEM_LANGUAGE, tr, trKey } from "./i18n.js";
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
import { createPopoverPreviewAPI, installAcrylicPreviewBackdrop } from "./popover-preview.js";
import { feedSummaryText, providerSummaryText, usageSummaryText } from "./popover-summary.js";
import { USAGE_RING_STROKE, usageCostText, usageRingSegmentAtPoint, usageRingStops, usageShareText } from "./popover-usage.js";
import "./popover.css";

const PROVIDER_ICON_MODULES = import.meta.glob("../../site/assets/providers/*.{svg,png}", { eager: true, import: "default" });
const PROVIDER_ICONS = Object.fromEntries(Object.entries(PROVIDER_ICON_MODULES).map(([path, url]) => [path.split("/").pop(), url]));
const FEED_ACCENT = { token_reset: "var(--cyan)", major_update: "var(--violet-dim)" };
const CLOCK_INTERVAL_MS = 60_000;
const COPIED_FEEDBACK_MS = 2_000;
const SEGMENTS = 14;
// Every out-of-flow panel the window has to grow for. Marked on the element
// rather than listed as class names so a new flyout opts in where it is written.
const FLYOUT_SELECTOR = "[data-flyout]";
// The 6px a footer flyout sits above the footer, plus the gutter that keeps it
// from touching the header's hairline once the window has grown for it.
const FLYOUT_GUTTER = 16;
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
const hasAcrylic = new URLSearchParams(globalThis.location?.search || "").get("material") === "acrylic";
if (hasAcrylic) {
  document.documentElement.dataset.material = "acrylic";
  // In Vite dev there is no DWM behind the tab, so the acrylic layers would
  // composite over nothing and the tuning could not be judged. `?wallpaper=dark`
  // switches the simulated desktop. Dropped from every build.
  if (import.meta.env.DEV) installAcrylicPreviewBackdrop();
}

// The popover never mounts the refracting library, on either path. Being a
// non-transparent window under acrylic makes `backdrop-filter` work again, but
// what that buys is the CSS material in popover.css — one blur per surface off
// the glass-model ladder — not liquid-glass-react. The library would add a
// second backdrop-filter *and* an SVG displacement filter to each of this
// popup's ten surfaces, forty filter nodes resident all day in a tray utility,
// and its refraction would fight the blur underneath it rather than add to it.
// Without acrylic the same plain layer is the only thing that can be drawn at
// all, since Chromium paints a transparent window's backdrop root opaque black.
// The opaque dashboard — not content-sized, not always open — still refracts.
const backdropMode = normalizeBackdropMode("none");

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
  const [appearanceOpen, setAppearanceOpen] = useState(false);
  activateLanguage(state?.languagePreference || SYSTEM_LANGUAGE, state?.systemLocale);
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
  const appearanceOpenRef = useRef(false);
  appearanceOpenRef.current = appearanceOpen;
  const glassStyle = normalizeGlassStyle(state?.popoverGlassStyle);
  const backdropOpacity = normalizeBackdropOpacity(state?.popoverBackdropOpacity);
  // Without acrylic there is no desktop behind the text to compete with it, so
  // the raised palette would only be a second, brighter theme on an opaque
  // window. Under acrylic it is the style that decides: Clear is transparent by
  // definition at every slider position and can find its text over a bright
  // desktop, while Frosted's diffusion tier is a floor the slider cannot remove
  // — even at the transparent end its shell carries ~0.58 of canvas over a 24px
  // blur, and the ordinary charcoal palette holds against that. See
  // needsAdaptiveForeground.
  const adaptiveForeground = hasAcrylic && needsAdaptiveForeground({ glassStyle });

  useEffect(() => {
    api.getState().then(setState).catch((reason) => setError(reason.message));
    return api.onStateChanged(setState);
  }, []);
  useLayoutEffect(() => {
    document.documentElement.dataset.reducedMotion = state?.reducedMotion ? "true" : "false";
  }, [state?.reducedMotion]);

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
    setAppearanceOpen(false);
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
      else if (appearanceOpenRef.current) setAppearanceOpen(false);
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
  //
  // A flyout — the Settings menu, the appearance panel, a widget's overflow
  // menu — is positioned out of flow, so it contributes nothing to either
  // measured block and the content-sized window simply clips it. Both kinds are
  // marked `data-flyout` and folded into the same measurement here, so the
  // window grows exactly enough to show one and shrinks back when it closes.
  // The requested height is computed from scratch every time rather than added
  // to the current one, so opening and closing cannot walk the window upward.
  const measure = useCallback(() => {
    cancelAnimationFrame(frameRef.current);
    frameRef.current = requestAnimationFrame(() => {
      const scroller = scrollRef.current;
      const content = contentRef.current;
      if (!scroller || !content) return;
      const style = getComputedStyle(scroller);
      const inset = Number.parseFloat(style.paddingTop) + Number.parseFloat(style.paddingBottom);
      const chrome = (headerRef.current?.offsetHeight || 0) + (footerRef.current?.offsetHeight || 0);
      // offsetHeight/clientHeight differ only by the shell's border here. Read
      // it instead of baking in 2px so the requested BrowserWindow height stays
      // exactly equal to the shell's painted border box if that edge changes.
      const shellBorder = rootRef.current
        ? rootRef.current.offsetHeight - rootRef.current.clientHeight
        : 2;
      // A footer flyout opens upward into the scroll region, so what it needs is
      // that region being at least as tall as the flyout plus its gutter.
      let footerFlyout = 0;
      for (const flyout of footerRef.current?.querySelectorAll(FLYOUT_SELECTOR) || []) {
        footerFlyout = Math.max(footerFlyout, flyout.offsetHeight + FLYOUT_GUTTER);
      }
      // A widget's overflow menu is anchored inside the scroll region and moves
      // with it, so the deterministic quantity is how far past the content box
      // it hangs — the same on every pass, whatever the window ends up being.
      const contentBottom = content.getBoundingClientRect().bottom;
      let overhang = 0;
      for (const flyout of content.querySelectorAll(FLYOUT_SELECTOR)) {
        overhang = Math.max(overhang, flyout.getBoundingClientRect().bottom - contentBottom);
      }
      const body = Math.max(content.offsetHeight + overhang + inset, footerFlyout);
      api.resizePopover?.(Math.ceil(chrome + body + shellBorder));
    });
  }, []);

  useEffect(() => {
    const element = contentRef.current;
    if (!element || typeof ResizeObserver === "undefined") return undefined;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => { observer.disconnect(); cancelAnimationFrame(frameRef.current); };
  }, [measure, Boolean(state)]);

  // Opening or closing a flyout changes nothing the ResizeObserver watches — it
  // observes the in-flow content box, which an out-of-flow panel never touches.
  useEffect(() => { measure(); }, [measure, openMenu, appearanceOpen, Boolean(state)]);

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

  if (!model) return <div className="popover-loading">{tr("Loading data…")}</div>;

  const visibleIDs = visibleWidgetIDs(layout);
  const widgetName = (id) => tr(BUILTIN_WIDGET_TITLES[id] || model.quota.find((card) => card.id === id)?.name || id);

  /// Shared overflow-menu entries for one reorderable widget, in the fixed
  /// Copy / pin / expand / move / hide order.
  function widgetMenuItems(id, summaryText) {
    const index = visibleIDs.indexOf(id);
    const expandable = canPinWidget(id);
    const pinned = isWidgetPinned(layout, id);
    const expanded = expandedIDs.includes(id);
    return [
      { key: "copy", label: tr("Copy Summary"), onSelect: () => copySummary(id, summaryText) },
      ...(expandable ? [
        { key: "pin", label: trKey(pinned ? "widget.stop_keep_expanded" : "widget.keep_expanded"), onSelect: () => togglePinned(id) },
        { key: "expand", label: trKey(expanded ? "widget.collapse" : "widget.expand"), onSelect: () => toggleExpanded(id) },
      ] : []),
      { key: "up", label: trKey("widget.move_up"), disabled: index <= 0, onSelect: () => updateLayout((current) => moveVisibleWidget(current, id, -1)) },
      { key: "down", label: trKey("widget.move_down"), disabled: index < 0 || index >= visibleIDs.length - 1, onSelect: () => updateLayout((current) => moveVisibleWidget(current, id, +1)) },
      { key: "hide", label: trKey("widget.remove_named", [widgetName(id)]), onSelect: () => hideWidget(id) },
    ];
  }

  const addItems = layout.hidden.length
    ? layout.hidden.map((id) => ({
      key: id,
      label: trKey("widget.add_named", [widgetName(id)]),
      onSelect: () => updateLayout((current) => setWidgetHidden(current, id, false)),
    }))
    : [{ key: "none", label: trKey("widget.all_visible"), disabled: true }];

  const widgetProps = (id, summaryText) => {
    const pinned = isWidgetPinned(layout, id);
    return {
      menu: {
        id,
        label: tr("%1$@ options", [widgetName(id)]),
        items: widgetMenuItems(id, summaryText),
        open: openMenu === id,
        onOpenChange: (wantOpen) => setOpenMenu(wantOpen ? id : null),
      },
      copied: copiedID === id,
      // The Mac's trailing keep-expanded toggle. Local Usage has no expanded
      // form, so it never gets one.
      pin: canPinWidget(id)
        ? { pinned, label: trKey(pinned ? "widget.stop_keep_expanded" : "widget.keep_expanded"), onToggle: () => togglePinned(id) }
        : undefined,
    };
  };

  // The Mac shows one amber line above the footer whenever a source could not
  // be read, alongside (not instead of) the in-card notice.
  const providerNotice = model.quota.find((card) => card.notice);
  const noticeText = error || (providerNotice ? `${providerNotice.name} · ${providerNotice.notice}` : undefined);
  const noticeDetail = error || providerNotice?.noticeDetail || noticeText;

  return (
    <GlassProvider
      glassStyle={glassStyle}
      backdropOpacity={backdropOpacity}
      backdrop={backdropMode}
      radiusLadder="fluent"
      active={visible}
    >
    <GlassSurface
      role="shell"
      className={`popover-root ${visible ? "is-visible" : "is-hidden"}`}
      ref={rootRef}
      data-glass-adaptive={adaptiveForeground ? "true" : undefined}
      style={{ "--glass-fg-shadow-opacity": String(adaptiveShadowOpacity({ glassStyle })) }}
      tabIndex={-1}
      elementRole="dialog"
      aria-label={tr("TokenRemain quick view")}
    >
      <span className="sr-only" aria-live="polite">{copiedID ? tr("Summary copied to clipboard") : ""}</span>
      <div className="popover-content">
      <header className="popover-header" ref={headerRef}>
        {/* The Mac's two-line identity block: wordmark over the freshness read. */}
        <span className="popover-identity">
          <span className="popover-brand">TokenRemain</span>
          <span className="popover-updated" title={model.updatedLabel}>{model.updatedLabel}</span>
        </span>
        <Dropdown
          id="add-widget"
          label={trKey("action.add_widget")}
          title={tr(layout.hidden.length ? "Show a hidden widget" : "All widgets are visible")}
          triggerClassName="icon-button is-plain"
          icon={<PlusIcon />}
          items={addItems}
          open={openMenu === "add-widget"}
          onOpenChange={(wantOpen) => setOpenMenu(wantOpen ? "add-widget" : null)}
        />
        <GlassCircle
          className="icon-button"
          onClick={() => run(api.refresh)}
          disabled={model.isRefreshing}
          aria-label={tr(model.isRefreshing ? "Refreshing usage" : "Refresh usage")}
          title={tr("Refresh quotas, local usage, pricing, and the AI Feed")}
        >
          <RefreshIcon spinning={model.isRefreshing} />
        </GlassCircle>
        {/* Escape and click-outside are the pointer paths, so the Mac's
            header carries no close button. Keyboard users still need a
            reachable one: this stays out of the resting layout and only
            becomes visible when it takes focus. */}
        <button
          className="popover-close-keyboard"
          onClick={() => api.hidePopover?.()}
          title={tr("Close Quick View (Esc)")}
        >
          <CloseIcon />
          <span>{tr("Close Quick View")}</span>
        </button>
      </header>

      <div className="popover-scroll" ref={scrollRef}>
        <div className="popover-sections" ref={contentRef}>
          <RiskStrip risk={model.risk} />
          {!providerIDs.length && (
            <GlassSurface as="section" role="card" className="popover-card popover-widget" aria-label={tr("Official quota")}>
              <div className="widget-head"><WidgetTitle name={tr("Official Quota")} /></div>
              <p className="popover-empty">
                <strong>{tr(model.quotaNotice || "Reading official quota…")}</strong>
                {tr("Claude and Codex snapshots appear here as soon as this PC or your paired Mac reports one.")}
              </p>
            </GlassSurface>
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
                serviceStatus={state.serviceStatus?.[card.id]}
                expanded={expandedIDs.includes(id)}
                onToggleExpanded={() => toggleExpanded(id)}
                {...widgetProps(id, providerSummaryText(card))}
              />
            );
          }}
          />
        </div>
      </div>

      {/* Notice line and footer measure as one block: resizePopover reads the
          footer element's height, so a notice outside it would be clipped. */}
      <div className="popover-footer-area" ref={footerRef}>
      {noticeText && (
        <p className="popover-notice" role={error ? "alert" : "status"}>
          <AlertIcon />
          <span title={noticeDetail}>{noticeText}</span>
        </p>
      )}
      <footer className="popover-footer">
        {appearanceOpen && (
          <AppearancePanel
            glassStyle={glassStyle}
            backdropOpacity={backdropOpacity}
            onGlassStyle={(value) => run(() => api.setPopoverGlassStyle(value))}
            onBackdropOpacity={(value) => run(() => api.setPopoverBackdropOpacity(value))}
            onClose={() => setAppearanceOpen(false)}
          />
        )}
        <GlassChip className="footer-dashboard" onClick={() => openDashboard("overview")} title={trKey("action.open_dashboard_help")}>
          {trKey("action.open_dashboard")}
        </GlassChip>
        <span className="footer-spacer" />
        <Dropdown
          id="footer-settings"
          label={tr("Settings")}
          title={tr("Launch, settings, and restart options")}
          triggerClassName="footer-secondary"
          glassTrigger="chip"
          icon={tr("Settings")}
          items={[
            {
              key: "appearance",
              label: trKey("settings.popover_appearance"),
              onSelect: () => setAppearanceOpen(true),
            },
            {
              key: "launch",
              label: tr("Launch at login"),
              checked: Boolean(state.launchAtLogin),
              onSelect: () => run(() => api.setLaunchAtLogin(!state.launchAtLogin)),
            },
            {
              key: "floating",
              label: tr("Floating shortcut"),
              checked: Boolean(state.floatingWidgetEnabled),
              onSelect: () => run(() => api.setFloatingWidgetEnabled(!state.floatingWidgetEnabled)),
            },
            { key: "open-settings", label: tr("Open Settings"), onSelect: () => openDashboard("settings") },
            { key: "relaunch", label: tr("Restart TokenRemain"), onSelect: () => run(api.relaunch) },
          ]}
          open={openMenu === "footer-settings"}
          onOpenChange={(wantOpen) => setOpenMenu(wantOpen ? "footer-settings" : null)}
        />
        {/* Drawn as a dot in a fixed box rather than typed as a middot: a
            character is placed by the font's metrics, and Segoe UI and
            Microsoft YaHei disagree about where the middle of a line is. */}
        <span className="footer-separator" aria-hidden="true" />
        <GlassChip className="footer-quit" onClick={() => run(api.quit)} title={trKey("action.quit_app")}>{trKey("action.quit")}</GlassChip>
      </footer>
      </div>
      </div>
    </GlassSurface>
    </GlassProvider>
  );
}

// MARK: - Popup appearance

const GLASS_STYLE_CHIPS = [
  { value: "frosted", key: "settings.popover_glass_frosted" },
  { value: "clear", key: "settings.popover_glass_clear" },
];

/// Port of the macOS PopoverSettingsPanel appearance section: the Frosted/Clear
/// switch and the backdrop-opacity slider. Both apply the moment they change —
/// this popup never interrupts a setting to ask for confirmation.
function AppearancePanel({ glassStyle, backdropOpacity, onGlassStyle, onBackdropOpacity, onClose }) {
  return (
    <GlassSurface
      as="section"
      role="card"
      className="popover-card popover-appearance"
      // Measured by measure(): the panel is out of flow, so the window has to
      // be told to grow for it or its own bounds clip the top off.
      data-flyout
      aria-label={trKey("settings.popover_appearance")}
    >
      <div className="popover-card-head">
        <h2>{trKey("settings.popover_appearance")}</h2>
        <button className="icon-button" onClick={onClose} aria-label={trKey("action.close")} title={trKey("action.close")}>
          <CloseIcon />
        </button>
      </div>
      <div className="popover-appearance-row">
        <span className="popover-appearance-label" id="popover-glass-style-label">{trKey("settings.popover_glass_style")}</span>
        <span
          className="popover-appearance-chips"
          role="radiogroup"
          aria-labelledby="popover-glass-style-label"
          aria-describedby="popover-glass-style-hint"
        >
          {GLASS_STYLE_CHIPS.map((chip) => (
            <button
              key={chip.value}
              type="button"
              role="radio"
              aria-checked={glassStyle === chip.value}
              className={glassStyle === chip.value ? "selected" : ""}
              onClick={() => onGlassStyle(chip.value)}
            >
              {trKey(chip.key)}
            </button>
          ))}
        </span>
      </div>
      <p className="sr-only" id="popover-glass-style-hint">{trKey("settings.popover_glass_style_hint")}</p>
      <div className="popover-appearance-row">
        <label className="popover-appearance-label" htmlFor="popover-backdrop-opacity">
          {trKey("settings.popover_background_opacity")}
        </label>
        <strong className="popover-appearance-readout">{`${backdropOpacityPercent(backdropOpacity)}%`}</strong>
      </div>
      <input
        id="popover-backdrop-opacity"
        className="popover-appearance-slider"
        type="range"
        min="0"
        max="100"
        step="2"
        value={backdropOpacityPercent(backdropOpacity)}
        aria-describedby="popover-backdrop-opacity-hint"
        onChange={(event) => onBackdropOpacity(Number(event.target.value) / 100)}
      />
      <div className="popover-appearance-scale">
        <span>{trKey("settings.popover_more_transparent")}</span>
        <span>{trKey("settings.popover_more_opaque")}</span>
      </div>
      <p className="sr-only" id="popover-backdrop-opacity-hint">
        {trKey("settings.popover_background_opacity_hint")}
      </p>
    </GlassSurface>
  );
}

// MARK: - Menus

/// One anchored dropdown: a trigger button plus, while open, an accessible
/// menu that supports arrow-key navigation, Escape-to-close, and flips upward
/// when the bottom of the window would clip it.
function Dropdown({ id, label, title, icon, items, open, onOpenChange, triggerClassName, triggerHidden, glassTrigger }) {
  // The trigger carries the glass, not the menu: an anchored menu already sits
  // on its own elevation and a second material behind it reads as a double edge.
  const Trigger = glassTrigger === "circle" ? GlassCircle : glassTrigger === "chip" ? GlassChip : "button";
  const wrapRef = useRef(null);
  const triggerRef = useRef(null);
  const [opensUp, setOpensUp] = useState(false);
  const hasChecks = items.some((item) => item.checked !== undefined);

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
      <Trigger
        ref={triggerRef}
        className={`${triggerClassName || "icon-button"}${triggerHidden ? " is-anchor" : ""}`}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? `${id}-menu` : undefined}
        aria-label={label}
        title={title || label}
        aria-hidden={triggerHidden || undefined}
        tabIndex={triggerHidden ? -1 : undefined}
        onClick={() => onOpenChange(!open)}
      >
        {icon}
      </Trigger>
      {open && (
        <div
          className={`menu-pop ${opensUp ? "menu-up" : ""}`}
          // Measured by popover.jsx's measure() so the window grows to fit an
          // open flyout instead of clipping it against its own bounds.
          data-flyout
          role="menu"
          id={`${id}-menu`}
          aria-label={label}
        >
          {items.map((item) => (
            <button
              key={item.key}
              role={item.checked === undefined ? "menuitem" : "menuitemcheckbox"}
              aria-checked={item.checked === undefined ? undefined : item.checked}
              className="menu-item"
              disabled={item.disabled}
              onClick={() => {
                onOpenChange(false);
                triggerRef.current?.focus();
                item.onSelect?.();
              }}
            >
              {/* The column is reserved on every row of a menu that has any
                  checkable item, so the labels stay in one line whether or not
                  the row is checked. */}
              {hasChecks && (
                <span className="menu-item-mark" aria-hidden="true">{item.checked ? <CheckIcon /> : null}</span>
              )}
              <span className="menu-item-label">{item.label}</span>
            </button>
          ))}
        </div>
      )}
    </span>
  );
}

/// The control cluster every reorderable widget shows in its header: the
/// transient Copied chip, the overflow menu, and the Mac's keep-expanded pin.
/// The Mac reaches the same actions through a right-click context menu only,
/// so the "…" trigger rests invisible and surfaces on hover or focus — the
/// header then reads like the Mac's while the actions stay one click away.
// `anchorOnly` keeps the menu and its right-click path without spending a
// column of the header on a trigger: the button collapses to a zero-size,
// untabbable anchor the flyout can hang off, and the widget's trailing value
// runs flush to the card's content edge. Shift+F10 or the Menu key still opens
// it from anything focused inside the card, which is how the actions stay
// reachable from the keyboard.
function WidgetControls({ menu, copied, pin, anchorOnly }) {
  return (
    <span className={`widget-controls${anchorOnly ? " is-anchor-only" : ""}`}>
      {copied && <span className="copied-chip" aria-hidden="true">{tr("Copied")}</span>}
      <Dropdown
        id={menu.id}
        label={menu.label}
        triggerClassName="icon-button widget-menu-button"
        triggerHidden={anchorOnly}
        icon={<MoreIcon />}
        items={menu.items}
        open={menu.open}
        onOpenChange={menu.onOpenChange}
      />
      {pin && (
        <button
          className="icon-button widget-pin-button"
          aria-pressed={pin.pinned}
          aria-label={pin.label}
          title={pin.label}
          onClick={pin.onToggle}
        >
          <PinIcon filled={pin.pinned} />
        </button>
      )}
    </span>
  );
}

/// The Mac widget header's leading half: identity glyph, title, and the
/// expand chevron immediately after the title.
function WidgetTitle({ icon, name, expandable, expanded, onToggleExpanded, title }) {
  if (!expandable) {
    return (
      <span className="widget-title-row">
        {icon}
        <h2 className="widget-title">{name}</h2>
      </span>
    );
  }
  return (
    <button className="widget-title-row is-toggle" aria-expanded={expanded} onClick={onToggleExpanded} title={title}>
      {icon}
      <h2 className="widget-title">{name}</h2>
      <ChevronRightIcon className={expanded ? "widget-chevron is-open" : "widget-chevron"} />
    </button>
  );
}

function widgetContextMenu(menu) {
  return (event) => {
    event.preventDefault();
    menu.onOpenChange(true);
  };
}

// MARK: - Risk

/// The Mac's compact two-line strip: an outlined level badge beside a headline,
/// with the tightest window's remaining share directly under it. The badge is
/// the one place colour appears, and it always carries its own LOW/MEDIUM/HIGH
/// label, so the detail line stays neutral rather than repeating the status in
/// colour. The projected run-out never earned a row of its own on the Mac — it
/// is what the headline already says — so it rides along as the strip's title.
function RiskStrip({ risk }) {
  const tone = risk.level || "unknown";
  const headline = tr(risk.headline);
  return (
    <GlassSurface
      as="section"
      role="card"
      className="popover-card popover-risk"
      aria-label={[tr("Quota risk"), headline, risk.detail, risk.projection].filter(Boolean).join(" · ")}
      title={risk.projection || undefined}
    >
      <span className={`badge tone-${tone} ${tone === "high" ? "filled" : ""}`}>{tone === "unknown" ? tr("Unknown") : trKey(`risk.badge.${tone}`, [], risk.badge)}</span>
      <span className="popover-risk-text">
        <strong title={headline}>{headline}</strong>
        {risk.detail && <span className="popover-risk-detail" title={risk.windowLabel}>{risk.detail}</span>}
      </span>
    </GlassSurface>
  );
}

// MARK: - Provider quota

/// Risk-and-pace cue for one quota window, spelled out so colour never carries
/// the meaning alone.
function windowRiskCue(window) {
  const healthy = window.level === "low" && !window.aheadOfPace;
  const tone = window.level === "high" ? "high" : window.level === "medium" || window.aheadOfPace ? "medium" : "low";
  const title = window.aheadOfPace
    ? tr("Current usage is ahead of pace")
    : window.level === "high" ? tr("Quota is nearly depleted")
      : window.level === "medium" ? tr("Watch your usage pace") : tr("Usage pace is healthy");
  return { healthy, tone, title };
}

/// One quota window in the Mac's three-row shape: window name opposite the
/// bold mono remaining share, the segment bar under it, and the reset read
/// below that. A healthy window shows no glyph at all — the triangle appears
/// only when the pace is worth a look, and always with a spelled-out title.
function QuotaWindowRow({ title, remaining, remainingText, resetText, accent, label, cue }) {
  return (
    <div className="quota-window">
      <span className="quota-window-row">
        <span className="quota-window-title" title={title}>{title}</span>
        {!cue.healthy && <AlertIcon className={`risk-mark tone-${cue.tone}`} title={cue.title} />}
        <strong className="quota-window-remaining">{remainingText}</strong>
      </span>
      <SegmentBar remaining={remaining} accent={accent} label={label} />
      {/* Colour never carries the pace read alone: an unhealthy window spells
          the reason out on this line, beside the same glyph the row above uses. */}
      <span className={cue.healthy ? "quota-window-reset" : `quota-window-reset tone-${cue.tone}`}>
        {cue.healthy ? <ResetIcon /> : <AlertIcon />}
        <span title={cue.healthy ? resetText : `${cue.title} · ${resetText}`}>
          {cue.healthy ? resetText : `${cue.title} · ${resetText}`}
        </span>
      </span>
    </div>
  );
}

function QuotaWidget({ card, serviceStatus, expanded, onToggleExpanded, menu, copied, pin }) {
  const accent = card.remaining < 10 ? "var(--danger)" : card.color;
  const icon = PROVIDER_ICONS[card.iconFile];
  const cue = windowRiskCue(card);
  return (
    <GlassSurface as="section" role="card" interactive className="popover-card popover-widget" aria-label={tr("%1$@ quota", [card.name])} onContextMenu={widgetContextMenu(menu)}>
      <div className="widget-head">
        <WidgetTitle
          expandable
          expanded={expanded}
          onToggleExpanded={onToggleExpanded}
          title={`${card.name} · ${card.windowTitle} · ${card.remainingText}. ${trKey(expanded ? "widget.collapse" : "widget.expand")}.`}
          icon={icon
            ? <img className="widget-glyph" src={icon} alt="" />
            : <span className="widget-glyph provider-mark-fallback" aria-hidden="true">{card.name.slice(0, 2).toUpperCase()}</span>}
          name={card.name}
        />
        <ServiceStatusBadge status={serviceStatus} />
        <WidgetControls menu={menu} copied={copied} pin={pin} />
      </div>
      {/* The summary row is the Mac's stable first window: expanding never
          repeats it below, it only adds the remaining windows under it. */}
      <QuotaWindowRow
        title={card.windowTitle}
        remaining={card.remaining}
        remainingText={card.remainingText}
        resetText={card.resetText}
        accent={accent}
        label={`${card.name} ${card.windowTitle}`}
        cue={cue}
      />
      {card.notice && (
        <span className="popover-quota-notice"><AlertIcon /><span title={card.noticeDetail || card.notice}>{card.notice}</span></span>
      )}
      {expanded && (
        <div className="quota-windows">
          {[...card.windows.slice(1), ...(card.scopedWindows || [])].map((window) => {
            const windowCue = windowRiskCue(window);
            return (
              <QuotaWindowRow
                key={window.key}
                title={window.title}
                remaining={window.remaining}
                remainingText={window.remainingText}
                resetText={window.resetText}
                accent={window.remaining < 10 ? "var(--danger)" : card.color}
                label={`${card.name} ${window.title}`}
                cue={windowCue}
              />
            );
          })}
          {(card.detailRows || []).map((row) => (
            <div className="popover-spend-row" key={row.key}>
              <span>{row.label}</span>
              <strong>{row.value}</strong>
            </div>
          ))}
          {card.capturedText && (
            <span
              className={card.capturedStale ? "quota-captured is-stale" : "quota-captured"}
              title={card.capturedStale ? tr("Snapshot is more than 10 minutes old") : card.capturedText}
            >
              {card.capturedStale ? <AlertIcon /> : <CheckCircleIcon />}
              <span>{card.capturedText}</span>
            </span>
          )}
        </div>
      )}
    </GlassSurface>
  );
}

function ServiceStatusBadge({ status }) {
  const labels = {
    minor: "service_status.degraded",
    major: "service_status.partial_outage",
    critical: "service_status.major_outage",
  };
  const key = labels[status?.indicator];
  if (!key) return null;
  const label = trKey(key);
  return (
    <span
      className={`service-status-badge tone-${status.indicator}`}
      title={`${label}: ${status.description}`}
      aria-label={`${label}: ${status.description}`}
    >
      <AlertIcon />
      <span>{label}</span>
    </span>
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
      style={{ height: 6 }}
      role="meter"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(clamped)}
      aria-valuetext={tr("%1$@ remaining", [formatPercent(clamped)])}
      aria-label={tr("%1$@ quota remaining", [label])}
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
  // The Mac omits an identity glyph here on purpose: the donut is the card's
  // mark, and a second symbol in the header competes with it. It also gives the
  // day's cost the whole trailing edge — no control column is reserved beside
  // it — so this widget's actions live on the right-click menu alone and the
  // trigger stays an unsized anchor for the flyout it opens.
  if (!usage) {
    return (
      <GlassSurface as="section" role="card" interactive className="popover-card popover-widget" aria-label={tr("Today's local usage")} onContextMenu={widgetContextMenu(menu)}>
        <div className="widget-head">
          <WidgetTitle name={trKey("widget.local_usage")} />
          {copied && <span className="copied-chip" aria-hidden="true">{tr("Copied")}</span>}
          <WidgetControls menu={menu} anchorOnly />
        </div>
        <p className="popover-empty"><strong>{tr(empty.title)}</strong>{tr(empty.message)}</p>
      </GlassSurface>
    );
  }
  const peak = Math.max(1, ...usage.trend.map((point) => point.tokens));
  const highlightedEntry = usage.entries.find((entry) => entry.id === highlightedUsageID);
  return (
    <GlassSurface as="section" role="card" interactive className="popover-card popover-widget" aria-label={tr("Today's local usage")} onContextMenu={widgetContextMenu(menu)}>
      <div className="widget-head">
        <WidgetTitle name={trKey("widget.local_usage")} />
        {copied && <span className="copied-chip" aria-hidden="true">{tr("Copied")}</span>}
        <strong className="widget-amount" title={usage.today.label}>
          {Number.isFinite(usage.today.cost) ? formatMoney(usage.today.cost) : tr("Price unavailable")}
        </strong>
        <WidgetControls menu={menu} anchorOnly />
      </div>
      <div className="popover-usage-composition" onPointerLeave={() => setHighlightedUsageID(null)}>
        <div
          className="popover-usage-ring"
          style={{ "--ring-fill": `conic-gradient(${usageRingStops(usage.entries, highlightedUsageID)})` }}
          role="img"
          aria-label={`Token usage by provider: ${usage.entries.map((entry) => `${entry.displayName} ${usageShareText(entry.tokenShare)}`).join(", ")}`}
          onPointerMove={(event) => {
            const rect = event.currentTarget.getBoundingClientRect();
            setHighlightedUsageID(usageRingSegmentAtPoint(
              usage.entries,
              { x: event.clientX - rect.left, y: event.clientY - rect.top },
              Math.min(rect.width, rect.height),
              USAGE_RING_STROKE,
            ));
          }}
        >
          {/* The hole is a true cut-out, so the hovered provider's cost and
              tokens are the only thing that ever sits in it — two mono lines,
              no disc of their own to match against the acrylic behind them. */}
          <span className="popover-usage-ring-center" aria-hidden="true">
            {highlightedEntry && (
              <>
                <strong>{highlightedEntry.hasCompletePricing ? formatMoney(highlightedEntry.cost) : "—"}</strong>
                <small>{compactNumber(highlightedEntry.tokens)}</small>
              </>
            )}
          </span>
        </div>
        <div className="popover-usage-rows" role="list" aria-label={tr("Provider usage shares")}>
          {usage.entries.map((entry) => {
            const shareText = usageShareText(entry.tokenShare);
            const tokensText = compactNumber(entry.tokens);
            const costText = usageCostText(entry);
            return (
              <div
                className={`popover-usage-row ${highlightedUsageID === entry.id ? "is-highlighted" : ""}`}
                key={entry.id}
                role="listitem"
                tabIndex={0}
                title={trKey("usage.provider_help", [entry.displayName, costText, tokensText, shareText])}
                aria-label={entry.hasCompletePricing
                  ? `${entry.displayName}, ${trKey("usage.provider_accessibility", [shareText, costText, tokensText])}`
                  : trKey("usage.provider_price_unavailable_accessibility", [entry.displayName, tokensText])}
                style={{ "--provider-color": entry.color }}
                onFocus={() => setHighlightedUsageID(entry.id)}
                onBlur={() => setHighlightedUsageID(null)}
                onPointerEnter={() => setHighlightedUsageID(entry.id)}
              >
                <i style={{ background: entry.color }} />
                <span>{entry.displayName}</span>
                <em>{tokensText}</em>
                <b>{shareText}</b>
              </div>
            );
          })}
        </div>
      </div>
      <div className="popover-spend">
        <SpendRow label={tr("Today")} bucket={usage.today} />
        <SpendRow label={tr("Yesterday")} bucket={usage.yesterday} />
        <SpendRow label={tr("Last 30 Days")} bucket={usage.last30Days} />
      </div>
      {usage.trend.length >= 2 && (
        <div className="popover-trend-row">
          <span id="popover-trend-label">{tr("Usage Trend")}</span>
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
          <button className="link-button" onClick={onOpen} title={tr("Open the full usage trend")}>{tr("View all")}</button>
        </div>
      )}
    </GlassSurface>
  );
}

function SpendRow({ label, bucket }) {
  return (
    <div className="popover-spend-row">
      <span>{label}</span>
      <strong title={bucket.hasData ? bucket.label : tr("No recorded data for this period")}>{bucket.label}</strong>
    </div>
  );
}

// MARK: - AI Feed

function FeedWidget({ feed, expanded, onToggleExpanded, onOpen, onOpenPost, menu, copied, pin }) {
  const sectionLabel = feed.items.length
    ? trKey(expanded ? "feed.full_top_stories" : "feed.important_updates")
    : trKey("feed.filtering");
  return (
    <GlassSurface as="section" role="card" interactive className="popover-card popover-widget popover-feed-widget" aria-label={trKey("widget.ai_feed")} onContextMenu={widgetContextMenu(menu)}>
      <div className="widget-head">
        <WidgetTitle
          expandable
          expanded={expanded}
          onToggleExpanded={onToggleExpanded}
          title={`${trKey("widget.ai_feed")}. ${trKey(expanded ? "widget.collapse" : "widget.expand")}.`}
          icon={<FeedIcon className="widget-glyph" />}
          name={trKey("widget.ai_feed")}
        />
        <span className={feed.cached ? "widget-count is-cached" : "widget-count"} title={feed.error || undefined}>
          {feed.status ? tr(feed.status) : trKey("feed.item_count", [feed.items.length])}
        </span>
        <WidgetControls menu={menu} copied={copied} pin={pin} />
      </div>
      <div className="popover-feed-head">
        <span>{sectionLabel}</span>
        <button className="link-button" onClick={onOpen} title={tr("Open the full AI Feed")}>{trKey("feed.view_all")}</button>
      </div>
      {feed.items.length ? (
        <div className="popover-feed">
          {feed.items.map((item) => (
            <button
              className="popover-feed-row"
              key={item.id}
              onClick={() => onOpenPost(item.url)}
              title={item.priorityLabel ? `${tr(item.priorityLabel)} · ${item.title}` : item.title}
            >
              <i className="feed-dot" style={{ background: FEED_ACCENT[item.priority] || "var(--muted)" }} />
              <span className="popover-feed-text">
                <span className="popover-feed-meta">
                  <b>{item.source}</b>
                  <time>{item.age}</time>
                </span>
                <span className={expanded ? "popover-feed-title is-expanded" : "popover-feed-title"}>{item.title}</span>
              </span>
              <ArrowUpRightIcon className="feed-open-arrow" />
            </button>
          ))}
        </div>
      ) : (
        <p className="popover-empty">
          <strong>{tr(feed.error ? "Feed is temporarily unavailable" : "Finding updates worth your attention…")}</strong>
          {feed.error || tr("Quota, pricing, and service-status updates appear here automatically.")}
        </p>
      )}
    </GlassSurface>
  );
}

if (api) createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
else document.getElementById("root").textContent = tr("TokenRemain popover requires the desktop app.");
