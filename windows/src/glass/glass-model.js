// Liquid Glass model, ported from the macOS authority
// (Sources/UsageDock/Views/Theme/LiquidGlassSupport.swift). Kept free of React
// and the DOM so the radius ladder, the role parameters and the opacity
// arithmetic can be asserted directly in tests.
//
// The two popup styles are two *materials*, not two densities of one material:
//
//   Frosted — a fixed, thick diffusion tier (`UsageDockPopoverAppearance
//   .frostedMaterial` = `.regularMaterial`) plus the shared scrim. Its cards are
//   the app's own charcoal panes, dense, wearing a flat border. The slider never
//   touches the diffusion: that is what stopped the two styles from trading
//   places at the ends of the slider's travel on macOS.
//
//   Clear — no material tier at all. On macOS that is native `Glass.clear`; here
//   it is the DWM acrylic the window already sits on, and nothing else. Its
//   cards spend `clearSurfaceTintCoefficient` of the reference on tint so the
//   desktop stays faintly readable through them, and they are the ones wearing
//   the top-lit gradient rim, the second blur and the inner lip — the whole
//   liquid-glass ingredient list lives on this side.
//
// The slider owns exactly one thing in both styles: the flat canvas scrim.

export const GLASS_STYLES = ["frosted", "clear"];
export const DEFAULT_GLASS_STYLE = "frosted";

/// macOS `referenceBackdropOpacity`: the point at which the popup reaches its
/// historical fully-tinted look, and the default the preference ships with.
export const DEFAULT_BACKDROP_OPACITY = 0.62;
/// The preference is stored on a 2% grid so the readout and the stored value
/// always agree.
export const BACKDROP_OPACITY_STEP = 0.02;
/// Floor for the flat scrim. On macOS this is a hit-testing guarantee (a
/// transparent panel stops receiving clicks below ~0.05 alpha); an Electron
/// window hit-tests as a whole, so here the same floor is purely about keeping
/// the popover legible over a bright desktop at the transparent end of the
/// slider.
export const MINIMUM_SCRIM_OPACITY = 0.12;

/// Frosted's diffusion tier — the Windows stand-in for `.regularMaterial`.
///
/// DWM acrylic alone is not it: acrylic is the *system* blur both styles sit on,
/// the counterpart of the desktop showing through `Glass.clear`. Frosted's
/// identity is a second, thicker diffusion on top of it, and on Windows that has
/// to be built by hand — a charcoal veil at a fixed alpha over a shell-level
/// blur, thick enough that content behind is unreadable at every slider
/// position.
///
/// `tint` is the veil's own alpha and is a constant of the material: the slider
/// moves the scrim underneath, never this. `blur`/`saturation` are likewise
/// fixed — a changing blur radius is a full re-composite of everything behind
/// the window on every frame, so the radius is never animated and never
/// slider-derived. Saturation stays a few points over 100 because a box blur
/// averages colour toward grey.
export const FROSTED_DIFFUSION = { tint: 0.52, blur: 24, saturation: 108 };

/// Clear cards spend a fraction of the reference tint so the surface behind
/// stays faintly readable through them.
export const CLEAR_SURFACE_TINT_COEFFICIENT = 0.42;

/// Frosted's card ladder: the app's own three charcoals, made translucent. The
/// opaque Windows 10 fallback stacks #121316 / #1a1b1f / #23252a, and Frosted is
/// that exact hierarchy seen through glass — a card is a dense pane, a control
/// on it is one step denser and lighter, its hover one step further. Card
/// density is `cardTintOpacity` below, which is the macOS reference value.
const FROSTED_CONTROL_TINT = 0.72;
const FROSTED_CONTROL_HOVER_TINT = 0.8;

/// Clear's control ladder: a white veil, not a slab of ink. This is the Fluent
/// layering the previous pass applied to both styles, now scoped to the style it
/// was always right for — Clear is the one that reveals the desktop, so a
/// surface above its cards has to read as *lighter*, the way Windows itself
/// layers on acrylic. Its cards need no veil at all: their fill is the faint
/// dark tint, which is what keeps the desktop legible through them.
const CLEAR_CONTROL_FILL = 0.1;
const CLEAR_CONTROL_HOVER_FILL = 0.16;

/// Shell edge. The shell holds the window against an arbitrary desktop, so it is
/// the strongest edge in the popup. Clear carries slightly more of it because
/// Frosted's diffusion already separates the popup from what is behind it —
/// macOS `shellRimHighlightOpacity`, same direction.
const SHELL_STROKE = { frosted: 0.2, clear: 0.22 };

/// macOS `borderOpacity`. Frosted deliberately keeps its pre-redesign card edge:
/// a flat 1px border whose strength *falls* as the shell's ink rises, because
/// the denser the shell the less edge a card needs to sit apart from it. Clear
/// does not use this at all — it wears the gradient rim instead.
const FROSTED_BORDER_REFERENCE = 0.85;
const FROSTED_BORDER_SLOPE = 0.4;
/// The macOS formula's output is an alpha over `DashboardTheme.border`, a
/// charcoal hairline. Spent on white — which is what an edge has to be over an
/// acrylic surface, since a charcoal line disappears the moment the desktop
/// behind it is bright — the same numbers would be a blazing white outline. This
/// is the palette conversion: at the shipped 62% slider it lands on 0.169, a
/// crisper edge than the old 0.12 card stroke without becoming a drawn box, and
/// at 24% on 0.211, clearly visible against a bright desktop.
export const FROSTED_BORDER_WHITE_COEFFICIENT = 0.28;
/// Clear's flat edge, used only where the gradient ring cannot reach (forced
/// colours, the non-acrylic fallback, and any plain hairline inside a card).
const CLEAR_CARD_STROKE = 0.14;

/// Corner sheen. Kept under the threshold where it resolves as a shape: a wide
/// short surface cannot wear a visible highlight band. Hierarchy comes from the
/// per-style ladders above, not from highlights.
const SPECULAR_OPACITY = { frosted: 0.04, clear: 0.03 };

/// Second blur ladder — a per-style constant, not a coefficient.
///
/// DWM acrylic blurs the desktop once behind the whole window; these are the
/// blurs the surfaces *above* the shell apply to whatever still shows through
/// the scrim. On Clear that second pass is the entire difference between a card
/// that reads as a pane of glass and one that reads as a painted rectangle, and
/// it is only reachable at all because the acrylic popover is a non-transparent
/// BrowserWindow: inside a `transparent: true` window Chromium paints every
/// filtered element's backdrop root opaque black.
///
/// On Frosted the cards take none, exactly as on macOS — the material behind
/// them has already done the diffusing, and a card re-blurring a surface that is
/// itself a thick blur buys nothing but a compositing pass. The shell takes none
/// in either style for a structural reason: a backdrop-filter on the shell would
/// make the shell the backdrop root for everything inside it, so cards would
/// re-blur the shell's own paint instead of the desktop. Frosted's diffusion
/// carries its blur on a *child* layer of the shell, which does not isolate it.
///
/// A flyout blurs hardest, and in both styles, because it is the only tier that
/// has to hide what is under it rather than reveal it.
const LAYER_BLUR = {
  frosted: { shell: 0, card: 0, control: 0, flyout: 28 },
  clear: { shell: 0, card: 20, control: 16, flyout: 28 },
};
/// Saturation rides with the blur: a box blur averages colour toward grey, and a
/// few points back is what keeps a wallpaper recognisable through the card.
/// Deliberately under 120% — past that the desktop starts tinting the popup's
/// own neutrals, and the provider hues stop being the only colour in the frame.
/// Shared by both styles: it compensates for a blur, so a tier that does not
/// blur never reads it.
const LAYER_SATURATION = { shell: 100, card: 116, control: 112, flyout: 118 };
export const BLUR_TIERS = ["shell", "card", "control", "flyout"];

/// Gradient rim — Clear's edge, and Clear's alone.
///
/// A flat 1px stroke reads as a drawn outline; the same stroke carried from a
/// bright top-left to a faint bottom-right reads as one light source crossing a
/// pane, and that is the single ingredient that makes a translucent box look
/// like glass. Frosted does not wear it: its edge is the flat macOS border curve
/// above, which is what keeps the two styles distinct at a glance rather than
/// only in density.
const RIM_GRADIENT = { start: 0.25, end: 0.11 };
/// Top-left to bottom-right, in CSS gradient degrees.
export const RIM_GRADIENT_ANGLE_DEG = 135;
/// A faint lip along the top edge, inside the rim: the thickness of the glass
/// catching light, not a second border. Clear only — a lip on a dense charcoal
/// pane is a highlight with nothing to be the thickness of.
export const INNER_HIGHLIGHT_OPACITY = 0.1;
/// Lift under a card. Soft and low-contrast on purpose — up to eight of these
/// stack in one scroll region, and anything heavier turns the widget list into
/// a stack of trays.
export const SURFACE_SHADOW = { y: 8, blur: 24, opacity: 0.25 };
/// A flyout covers text the user is still reading, so it has to occlude rather
/// than reveal. Blur alone cannot do that — blurred text still reads as text —
/// so a scrim under the veil is what guarantees nothing bleeds through. It is
/// the one value the style switch does not touch: a Clear menu that leaked the
/// card behind it would read as a rendering fault, not as a material.
export const FLYOUT_SCRIM_OPACITY = 0.85;

/// Pointer lift for interactive cards. macOS carries two far-apart nominal
/// values because a white overlay lands differently on `Glass.clear` than on
/// `Glass.regular`; both are tuned to reach ~0.05 effective, which is what a
/// plain CSS overlay produces directly.
export const SURFACE_HIGHLIGHT_LIFT = 0.05;

export const MATERIAL_TRANSITION_MS = 200;
export const FOREGROUND_TRANSITION_MS = 160;

/// macOS `glassShadowOpacity` for the secondary role. CSS inherits one
/// `text-shadow` down the whole subtree rather than being applied per label, so
/// the Mac's per-role spread (primary 0.72 / secondary 0.78 / muted 0.84)
/// collapses to its middle value here.
export const ADAPTIVE_SHADOW_OPACITY = 0.78;

export const DEFAULT_ROLE = "card";

/// How a surface produces its material. `material` mounts liquid-glass-react —
/// real refraction, at the cost of a `backdrop-filter` and an SVG displacement
/// filter. `none` draws the same box out of plain CSS only.
///
/// The distinction is not cosmetic on Windows: Chromium paints the backdrop
/// root of a `transparent: true` window opaque black as soon as anything in the
/// document carries a backdrop-filter, so a window without a system backdrop
/// behind it (the floating shortcut always; the popover whenever DWM refuses
/// acrylic) turns into a black rectangle the moment the material mounts.
export const BACKDROP_MODES = ["material", "none"];
export const DEFAULT_BACKDROP_MODE = "material";

export function normalizeBackdropMode(value) {
  return value === "none" ? "none" : DEFAULT_BACKDROP_MODE;
}

/// The mode a window may use. CSS backdrop-filter does not work inside a
/// `transparent: true` Electron window on Windows (electron/electron#30412):
/// Chromium paints each filtered element's backdrop root opaque black, DWM
/// acrylic or not, and SVG displacement filters rasterize on the CPU. So the
/// popover and the floating shortcut — the two transparent windows — always
/// take the plain CSS backdrop and let the system material supply the blur;
/// only the opaque dashboard mounts the refracting material.
export function backdropModeForWindow(kind) {
  return kind === "opaque" ? "material" : "none";
}

/// Corner-radius ladders. The macOS-derived ladder remains the default for the
/// dashboard and floating shortcut. The popover opts into Fluent: its shell
/// draws square corners and leaves rounding to DWM (`roundedCorners`), which
/// clips the filled window itself — so whether or not DWM rounds a transparent
/// window, nothing ever shows outside the shell. Cards take Windows 11's 8px
/// step and controls tighten to 6px. `circle` remains round on both platforms.
export const DEFAULT_RADIUS_LADDER = "mac";
export const RADIUS_LADDERS = {
  mac: { shell: 14, card: 13, control: 9, circle: 999 },
  fluent: { shell: 0, card: 8, control: 6, circle: 999 },
};

/// liquid-glass-react parameters per role. Deliberately far below the library's
/// demo defaults (displacement 70, saturation 140, aberration 2): this is an
/// always-resident tray utility, so the shell only hints at a material, cards
/// are present enough to read as separate panes, and small controls trade blur
/// for refraction so their labels stay crisp.
const ROLE_PARAMS = {
  shell: { displacementScale: 18, blurAmount: 0.11, saturation: 118, aberrationIntensity: 0.6, elasticity: 0 },
  card: { displacementScale: 34, blurAmount: 0.07, saturation: 126, aberrationIntensity: 1, elasticity: 0.12 },
  control: { displacementScale: 46, blurAmount: 0.03, saturation: 134, aberrationIntensity: 1.4, elasticity: 0.18 },
};
ROLE_PARAMS.circle = ROLE_PARAMS.control;

/// Clear removes the diffusion and spends the difference on refraction, the way
/// the macOS style switch swaps `.regularMaterial` for native `Glass.clear`.
const CLEAR_DISPLACEMENT_GAIN = 1.35;
const CLEAR_SATURATION_GAIN = 6;

function clamp01(value) {
  return Math.min(Math.max(value, 0), 1);
}

function round1(value) {
  return Math.round(value * 10) / 10;
}

function round2(value) {
  return Math.round(value * 100) / 100;
}

function round3(value) {
  return Math.round(value * 1000) / 1000;
}

export function normalizeGlassStyle(value) {
  return value === "clear" ? "clear" : DEFAULT_GLASS_STYLE;
}

export function isGlassStyle(value) {
  return GLASS_STYLES.includes(value);
}

function isClear(glassStyle) {
  return normalizeGlassStyle(glassStyle) === "clear";
}

export function normalizeRadiusLadder(value) {
  return value === "fluent" ? "fluent" : DEFAULT_RADIUS_LADDER;
}

/// Clamp to 0–1 and snap to the 2% grid. Anything that is not a finite number
/// falls back to the shipped default rather than to zero, which would hand the
/// user an invisible popover.
export function normalizeBackdropOpacity(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return DEFAULT_BACKDROP_OPACITY;
  // Dividing by the step accumulates float noise (0.62 comes back as
  // 0.6200000000000001); multiplying by its reciprocal lands on the grid exactly.
  return Math.round(clamp01(value) * (1 / BACKDROP_OPACITY_STEP)) / (1 / BACKDROP_OPACITY_STEP);
}

export function roleRadius(role, radiusLadder) {
  const ladder = RADIUS_LADDERS[normalizeRadiusLadder(radiusLadder)];
  return ladder[role] ?? ladder[DEFAULT_ROLE];
}

export function glassParams(role, glassStyle) {
  const base = ROLE_PARAMS[role] || ROLE_PARAMS[DEFAULT_ROLE];
  if (!isClear(glassStyle)) return { ...base };
  return {
    ...base,
    displacementScale: round1(base.displacementScale * CLEAR_DISPLACEMENT_GAIN),
    blurAmount: 0,
    saturation: base.saturation + CLEAR_SATURATION_GAIN,
  };
}

// MARK: - Shell

/// The slider owns the shell's ink and nothing else, so the whole travel of the
/// control is visible as a linear change above the readability floor.
export function scrimOpacity(backdropOpacity) {
  return Math.max(clamp01(normalizeBackdropOpacity(backdropOpacity)), MINIMUM_SCRIM_OPACITY);
}

/// Whether the style mounts the diffusion tier at all. One of the two facts
/// about a style that is a *branch* rather than a value — `wearsGradientRim` is
/// the other — so the stylesheet expresses it by selecting on
/// `[data-glass-style]`, and this is the assertable statement of the same thing.
///
/// Deliberately not published as a token. A `--…-presence` custom property
/// carrying only 0 or 1 would be a boolean wearing a number's clothes, and the
/// stylesheet would still need the attribute for the `visibility` step that ends
/// the fade. One branch expressing one branch is the smaller of the two shapes.
export function mountsDiffusionTier(glassStyle) {
  return !isClear(glassStyle);
}

/// The diffusion tier's filter. A constant, and that is the point: the blur
/// radius is never animated and never slider-derived, so the cross-fade only
/// ever moves an opacity. A faded-out tier is `visibility: hidden` once the fade
/// ends, so Clear pays nothing for a filter it does not use.
export function diffusionFilter() {
  return `blur(${FROSTED_DIFFUSION.blur}px) saturate(${FROSTED_DIFFUSION.saturation}%)`;
}

/// Total canvas ink over the desktop: the scrim the slider owns, plus the
/// diffusion veil above it. Both layers are the same canvas colour, so the order
/// they composite in does not change the result — what matters is that Frosted
/// starts from a floor no slider position can take away.
export function shellInkOpacity(glassStyle, backdropOpacity) {
  const scrim = scrimOpacity(backdropOpacity);
  const veil = mountsDiffusionTier(glassStyle) ? FROSTED_DIFFUSION.tint : 0;
  return round3(1 - (1 - scrim) * (1 - veil));
}

export function shellStrokeOpacity(glassStyle) {
  return isClear(glassStyle) ? SHELL_STROKE.clear : SHELL_STROKE.frosted;
}

// MARK: - Cards and controls

/// Card density belongs to the style switch, not to the slider: Frosted keeps
/// the historical fully-tinted card, Clear a fixed translucent one. Both are a
/// tint of the app's own charcoal card colour — Clear is not a *lighter* card,
/// it is the same card with most of its ink removed.
export function cardTintOpacity(glassStyle) {
  return isClear(glassStyle)
    ? round2(DEFAULT_BACKDROP_OPACITY * CLEAR_SURFACE_TINT_COEFFICIENT)
    : DEFAULT_BACKDROP_OPACITY;
}

/// Frosted's control, one step denser than its card. Zero on Clear, which puts
/// its controls on the white ladder below instead.
export function controlTintOpacity(glassStyle) {
  return isClear(glassStyle) ? 0 : FROSTED_CONTROL_TINT;
}

export function controlHoverTintOpacity(glassStyle) {
  return isClear(glassStyle) ? 0 : FROSTED_CONTROL_HOVER_TINT;
}

/// Clear's control, as a white veil over whatever the scrim still lets through.
/// Zero on Frosted, whose controls are dense charcoal instead.
export function controlFillOpacity(glassStyle) {
  return isClear(glassStyle) ? CLEAR_CONTROL_FILL : 0;
}

export function controlHoverFillOpacity(glassStyle) {
  return isClear(glassStyle) ? CLEAR_CONTROL_HOVER_FILL : 0;
}

/// macOS `borderOpacity`, unscaled: the alpha the Mac spends on its charcoal
/// card border. Exported so the curve itself stays assertable against the
/// authority; `frostedBorderOpacity` is what the stylesheet reads.
export function borderOpacity(backdropOpacity) {
  const progress = clamp01(normalizeBackdropOpacity(backdropOpacity));
  return round3(FROSTED_BORDER_REFERENCE - FROSTED_BORDER_SLOPE * progress);
}

/// Frosted's flat card edge, in white, for a Windows acrylic surface. This is
/// the one place the slider reaches past the scrim, and deliberately so: it is
/// the macOS curve, where a card needs *more* edge the less ink the shell has.
export function frostedBorderOpacity(backdropOpacity) {
  return round3(borderOpacity(backdropOpacity) * FROSTED_BORDER_WHITE_COEFFICIENT);
}

/// The flat 1px edge a card carries. Frosted rides the macOS curve; Clear holds
/// a constant hairline, because its real edge is the gradient ring and this is
/// only the fallback the ring cannot cover (forced colours, no acrylic, plain
/// hairlines inside a card).
export function cardStrokeOpacity(glassStyle, backdropOpacity) {
  return isClear(glassStyle) ? CLEAR_CARD_STROKE : frostedBorderOpacity(backdropOpacity);
}

/// Only Clear wears the top-lit gradient rim. Frosted keeps the flat border, so
/// the two styles differ in edge treatment and not only in density — the same
/// split macOS makes between `surfaceRimGradient` and the pre-redesign stroke.
export function wearsGradientRim(glassStyle) {
  return isClear(glassStyle);
}

/// The two ends of the 135° rim gradient: bright at the top-left corner, faint
/// at the bottom-right one. Zero on Frosted, which does not wear the ring at all.
export function rimGradientStops(glassStyle) {
  if (!wearsGradientRim(glassStyle)) return { start: 0, end: 0 };
  return { ...RIM_GRADIENT };
}

/// The inner lip, likewise Clear's alone.
export function innerHighlightOpacity(glassStyle) {
  return wearsGradientRim(glassStyle) ? INNER_HIGHLIGHT_OPACITY : 0;
}

/// Edge strength for the plain (non-acrylic, non-refracting) backdrop layer.
/// Independent of the slider: deriving it from the inverse of the fill made the
/// most transparent popover the most heavily outlined one, which is the opposite
/// of how glass behaves.
export function rimOpacity(role, glassStyle) {
  const clear = isClear(glassStyle);
  if (role === "shell") return clear ? 0.32 : 0.24;
  return clear ? 0.17 : 0.13;
}

/// Strength of the corner sheen. Small enough to be felt rather than seen.
export function specularOpacity(glassStyle) {
  return isClear(glassStyle) ? SPECULAR_OPACITY.clear : SPECULAR_OPACITY.frosted;
}

/// Blur radius, in px, that a tier applies to whatever shows through the shell.
export function layerBlurRadius(tier, glassStyle) {
  const ladder = LAYER_BLUR[isClear(glassStyle) ? "clear" : "frosted"];
  return ladder[tier] ?? ladder.card;
}

/// Saturation percentage for the same tier. Independent of the style: it
/// compensates for what the blur takes out, so a tier that does not blur never
/// reads it.
export function layerSaturation(tier) {
  return LAYER_SATURATION[tier] ?? LAYER_SATURATION.card;
}

/// The whole `backdrop-filter` for a tier as one CSS value, so the stylesheet
/// never has to assemble a filter list out of separate numeric tokens — and so
/// a tier that takes no blur resolves to a keyword rather than to `blur(0px)`,
/// which still costs Chromium a compositing pass. On Frosted that is every tier
/// but the flyout.
export function layerBackdropFilter(tier, glassStyle) {
  const blur = layerBlurRadius(tier, glassStyle);
  if (!blur) return "none";
  return `blur(${blur}px) saturate(${layerSaturation(tier)}%)`;
}

/// Outer lift under a card, as one CSS shadow. Style-independent: the shadow
/// belongs to the geometry of the layer, not to the material in it.
export function surfaceShadow() {
  return `0 ${SURFACE_SHADOW.y}px ${SURFACE_SHADOW.blur}px rgb(0 0 0 / ${SURFACE_SHADOW.opacity})`;
}

/// Everything a surface hands to CSS. Keeping it here means the components stay
/// declarative and the numbers stay testable.
///
/// The whole set is republished by every surface, with the style's values, so a
/// style switch is a pure CSS swap: the stylesheet branches on
/// `[data-glass-style]` for the two rules that cannot be expressed as a value
/// (which ladder `--surface-2` reads, and whether the gradient ring exists), and
/// everything else cross-fades because its token changed.
///
/// The active radius, the card tint and the rim are role-scoped — they describe
/// *this* surface. The ladders are ambient, published identically by every
/// surface so that plain DOM inside a card — a menu, a badge, a feed row, the
/// widget header's bare buttons — can place itself on the ladder without being
/// wrapped in a GlassSurface first.
export function surfaceVariables({ role = DEFAULT_ROLE, glassStyle, backdropOpacity, radiusLadder } = {}) {
  const style = normalizeGlassStyle(glassStyle);
  const ladder = RADIUS_LADDERS[normalizeRadiusLadder(radiusLadder)];
  const rim = rimGradientStops(style);
  return {
    "--glass-radius": `${roleRadius(role, radiusLadder)}px`,
    "--glass-shell-radius": `${ladder.shell}px`,
    "--glass-card-radius": `${ladder.card}px`,
    "--glass-control-radius": `${ladder.control}px`,
    // The shell: one scrim the slider owns, one diffusion tier the style owns.
    "--glass-scrim-opacity": String(scrimOpacity(backdropOpacity)),
    "--glass-diffusion-tint": String(FROSTED_DIFFUSION.tint),
    "--glass-diffusion-filter": diffusionFilter(),
    "--glass-shell-stroke": String(shellStrokeOpacity(style)),
    // Cards and controls: the dark ladder on Frosted, the white one on Clear.
    "--glass-tint-opacity": String(cardTintOpacity(style)),
    "--glass-control-tint": String(controlTintOpacity(style)),
    "--glass-control-hover-tint": String(controlHoverTintOpacity(style)),
    "--glass-control-fill": String(controlFillOpacity(style)),
    "--glass-control-hover-fill": String(controlHoverFillOpacity(style)),
    "--glass-card-stroke": String(cardStrokeOpacity(style, backdropOpacity)),
    "--glass-rim-opacity": String(rimOpacity(role, style)),
    "--glass-specular-opacity": String(specularOpacity(style)),
    // Ambient like the ladders above: a menu or a chip that is plain DOM inside
    // a card still has to be able to re-blur its own backdrop without being
    // wrapped in a GlassSurface first. Only the acrylic stylesheet reads them —
    // a transparent window would paint a black backdrop root instead.
    "--glass-card-backdrop": layerBackdropFilter("card", style),
    "--glass-control-backdrop": layerBackdropFilter("control", style),
    "--glass-flyout-backdrop": layerBackdropFilter("flyout", style),
    "--glass-flyout-scrim": String(FLYOUT_SCRIM_OPACITY),
    "--glass-rim-gradient-start": String(rim.start),
    "--glass-rim-gradient-end": String(rim.end),
    "--glass-inner-highlight": String(innerHighlightOpacity(style)),
    "--glass-surface-shadow": surfaceShadow(),
  };
}

/// Whether a surface has to raise its foreground palette and spend the glyph
/// edge that goes with it.
///
/// Clear only. It is transparent by definition at every slider position, so its
/// text can find itself over a bright desktop. Frosted cannot: its diffusion
/// tier is a floor no slider position removes, so even at the transparent end
/// the shell carries `shellInkOpacity` ≈ 0.58 of canvas over a 24px blur, and
/// the ordinary charcoal-surface palette holds. That floor is exactly why this
/// no longer keys off the slider — the previous threshold existed because
/// Frosted at a low slider value really was thin, and it is not any more.
export function needsAdaptiveForeground({ glassStyle } = {}) {
  return isClear(glassStyle);
}

/// Ink of the glyph edge that keeps raised text legible over a bright desktop.
/// Zero when the surface is dense enough to carry the text on its own, so the
/// token can be set unconditionally.
export function adaptiveShadowOpacity({ glassStyle } = {}) {
  return needsAdaptiveForeground({ glassStyle }) ? ADAPTIVE_SHADOW_OPACITY : 0;
}

/// Percentage shown next to the slider, matching the macOS panel's readout.
export function backdropOpacityPercent(value) {
  return Math.round(normalizeBackdropOpacity(value) * 100);
}
