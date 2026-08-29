import React, { createContext, useContext, useRef } from "react";
import LiquidGlass from "liquid-glass-react";
import {
  DEFAULT_BACKDROP_MODE,
  DEFAULT_BACKDROP_OPACITY,
  DEFAULT_GLASS_STYLE,
  DEFAULT_RADIUS_LADDER,
  SURFACE_HIGHLIGHT_LIFT,
  glassParams,
  normalizeBackdropMode,
  normalizeBackdropOpacity,
  normalizeGlassStyle,
  normalizeRadiusLadder,
  roleRadius,
  surfaceVariables,
} from "./glass-model.js";
import "./glass.css";

/// The macOS environment values (`usageDockPopoverGlassStyle` and
/// `usageDockPopoverBackdropOpacity`) as one React context, so a surface deep in
/// the widget stack does not have to be threaded the popover's preferences.
const GlassContext = createContext({
  glassStyle: DEFAULT_GLASS_STYLE,
  backdropOpacity: DEFAULT_BACKDROP_OPACITY,
  backdrop: DEFAULT_BACKDROP_MODE,
  radiusLadder: DEFAULT_RADIUS_LADDER,
  active: true,
});

export function GlassProvider({ glassStyle, backdropOpacity, backdrop, radiusLadder, active, children }) {
  const value = {
    glassStyle: normalizeGlassStyle(glassStyle),
    backdropOpacity: normalizeBackdropOpacity(backdropOpacity),
    backdrop: normalizeBackdropMode(backdrop),
    radiusLadder: normalizeRadiusLadder(radiusLadder),
    active: active !== false,
  };
  return <GlassContext.Provider value={value}>{children}</GlassContext.Provider>;
}

export function useGlass() {
  return useContext(GlassContext);
}

// The library re-renders on every mousemove to drive elasticity. Supplying both
// mouse props switches that listener off entirely, which is exactly what a
// non-interactive surface wants: static refraction, no per-frame work.
const STATIC_MOUSE = Object.freeze({ x: 0, y: 0 });

// Pins the library's centred pill onto the surface: `top/left: 50%` plus its own
// translate(-50%, -50%) resolves to inset 0 once the box is the surface's size.
// Zero is deliberately not used for top/left — the library reads them with `||`,
// so a falsy value silently falls back to "50%".
const LAYER_STYLE = Object.freeze({
  position: "absolute",
  top: "50%",
  left: "50%",
  width: "100%",
  height: "100%",
});

/// One glass surface. `role` picks the current corner-radius ladder step and
/// the matching refraction parameters; `glassStyle`
/// and `backdropOpacity` default to the popover's preferences.
///
/// `active` is the performance guardrail: a hidden popover window keeps its
/// renderer alive, and every mounted surface would otherwise keep an SVG
/// displacement filter and a backdrop-filter layer resident. When false the
/// surface renders as the plain styled element, which is also the Windows 10
/// and forced-colours appearance.
///
/// `backdrop` picks how the material is produced: `"material"` mounts the
/// library, `"none"` draws the same box — tint, specular, rim — out of plain
/// CSS. A window with no system backdrop behind it has to use `"none"`, because
/// Chromium paints the backdrop root of a transparent Windows window opaque
/// black whenever a backdrop-filter exists anywhere in the document. It is
/// inherited from the provider so a whole window opts in once.
///
/// `elementRole` sets the DOM `role` attribute, since `role` itself names the
/// glass role here.
export function GlassSurface({
  role = "card",
  as: Tag = "div",
  glassStyle,
  backdropOpacity,
  backdrop,
  radiusLadder,
  interactive = false,
  active,
  elementRole,
  className = "",
  style,
  ref,
  children,
  ...rest
}) {
  const inherited = useGlass();
  const surfaceRef = useRef(null);
  const resolvedStyle = normalizeGlassStyle(glassStyle ?? inherited.glassStyle);
  const resolvedOpacity = normalizeBackdropOpacity(backdropOpacity ?? inherited.backdropOpacity);
  const isActive = (active ?? inherited.active) !== false;
  const resolvedBackdrop = normalizeBackdropMode(backdrop ?? inherited.backdrop);
  const resolvedRadiusLadder = normalizeRadiusLadder(radiusLadder ?? inherited.radiusLadder);
  const radius = roleRadius(role, resolvedRadiusLadder);
  const params = glassParams(role, resolvedStyle);

  const attachRef = (node) => {
    surfaceRef.current = node;
    if (typeof ref === "function") ref(node);
    else if (ref) ref.current = node;
  };

  return (
    <Tag
      {...rest}
      ref={attachRef}
      role={elementRole}
      className={`glass-surface ${className}`.trim()}
      data-glass-role={role}
      data-glass-style={resolvedStyle}
      data-glass-interactive={interactive ? "true" : undefined}
      style={{
        ...surfaceVariables({
          role,
          glassStyle: resolvedStyle,
          backdropOpacity: resolvedOpacity,
          radiusLadder: resolvedRadiusLadder,
        }),
        "--glass-lift-opacity": String(SURFACE_HIGHLIGHT_LIFT),
        ...style,
      }}
    >
      {isActive && (
        <span className="glass-layer" data-glass-layer data-glass-backdrop={resolvedBackdrop} aria-hidden="true">
          {resolvedBackdrop === "material" && (
            <LiquidGlass
              {...params}
              elasticity={interactive ? params.elasticity : 0}
              // Tracking has to listen on the surface itself: the effect stack is
              // pointer-events:none, so a listener bound inside it never fires.
              mouseContainer={interactive ? surfaceRef : null}
              globalMousePos={interactive ? undefined : STATIC_MOUSE}
              mouseOffset={interactive ? undefined : STATIC_MOUSE}
              cornerRadius={radius}
              padding="0"
              mode="standard"
              style={LAYER_STYLE}
            />
          )}
          {interactive && <i className="glass-lift" />}
        </span>
      )}
      {children}
    </Tag>
  );
}

/// Footer command chip — the control step of the radius ladder.
export function GlassChip({ className = "", children, ...rest }) {
  return (
    <GlassSurface role="control" as="button" type="button" className={`glass-chip ${className}`.trim()} {...rest}>
      <span className="glass-label">{children}</span>
    </GlassSurface>
  );
}

/// Round header button. Same parameters as a chip, drawn as a circle.
export function GlassCircle({ className = "", children, ...rest }) {
  return (
    <GlassSurface role="circle" as="button" type="button" className={`glass-circle ${className}`.trim()} {...rest}>
      <span className="glass-label">{children}</span>
    </GlassSurface>
  );
}
