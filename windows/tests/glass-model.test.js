import assert from "node:assert/strict";
import test from "node:test";
import {
  ADAPTIVE_SHADOW_OPACITY,
  BACKDROP_MODES,
  BACKDROP_OPACITY_STEP,
  BLUR_TIERS,
  CLEAR_SURFACE_TINT_COEFFICIENT,
  DEFAULT_BACKDROP_MODE,
  DEFAULT_BACKDROP_OPACITY,
  DEFAULT_RADIUS_LADDER,
  FLYOUT_SCRIM_OPACITY,
  FROSTED_BORDER_WHITE_COEFFICIENT,
  FROSTED_DIFFUSION,
  INNER_HIGHLIGHT_OPACITY,
  MINIMUM_SCRIM_OPACITY,
  RADIUS_LADDERS,
  RIM_GRADIENT_ANGLE_DEG,
  SURFACE_SHADOW,
  adaptiveShadowOpacity,
  backdropModeForWindow,
  backdropOpacityPercent,
  borderOpacity,
  cardStrokeOpacity,
  cardTintOpacity,
  controlFillOpacity,
  controlHoverFillOpacity,
  controlHoverTintOpacity,
  controlTintOpacity,
  diffusionFilter,
  frostedBorderOpacity,
  glassParams,
  innerHighlightOpacity,
  isGlassStyle,
  layerBackdropFilter,
  layerBlurRadius,
  layerSaturation,
  mountsDiffusionTier,
  needsAdaptiveForeground,
  normalizeBackdropMode,
  normalizeBackdropOpacity,
  normalizeGlassStyle,
  normalizeRadiusLadder,
  rimGradientStops,
  rimOpacity,
  roleRadius,
  scrimOpacity,
  shellInkOpacity,
  shellStrokeOpacity,
  specularOpacity,
  surfaceShadow,
  surfaceVariables,
  wearsGradientRim,
} from "../src/glass/glass-model.js";

/// Tokens whose value is a whole CSS value rather than a bare number, so the
/// "every step survives an inline style as a number" sweep below can skip them.
const CSS_VALUE_TOKENS = new Set([
  "--glass-radius",
  "--glass-shell-radius",
  "--glass-card-radius",
  "--glass-control-radius",
  "--glass-diffusion-filter",
  "--glass-card-backdrop",
  "--glass-control-backdrop",
  "--glass-flyout-backdrop",
  "--glass-surface-shadow",
]);

/// Every position the 2% slider can take, as the styles' shared input.
const SLIDER_POSITIONS = Array.from({ length: 51 }, (_, step) => step / 50);

test("The default corner-radius ladder matches the Mac shell/card/control steps", () => {
  assert.equal(DEFAULT_RADIUS_LADDER, "mac");
  assert.equal(roleRadius("shell"), 14);
  assert.equal(roleRadius("card"), 13);
  assert.equal(roleRadius("control"), 9);
  assert.equal(roleRadius("circle"), 999);
  // An unknown role falls back to the card step rather than to the library's
  // 999px pill default, which would round a full-width panel into a lozenge.
  assert.equal(roleRadius("banner"), 13);
  assert.equal(roleRadius(undefined), 13);
});

test("The Fluent corner-radius ladder matches the Windows popover", () => {
  assert.deepEqual(RADIUS_LADDERS.fluent, { shell: 0, card: 8, control: 6, circle: 999 });
  assert.equal(roleRadius("shell", "fluent"), 0);
  assert.equal(roleRadius("card", "fluent"), 8);
  assert.equal(roleRadius("control", "fluent"), 6);
  assert.equal(roleRadius("circle", "fluent"), 999);
  assert.equal(roleRadius("banner", "fluent"), 8);
  assert.equal(normalizeRadiusLadder("fluent"), "fluent");
  for (const value of [undefined, null, "windows", "Fluent"]) {
    assert.equal(normalizeRadiusLadder(value), DEFAULT_RADIUS_LADDER);
  }
});

test("Role parameters stay well below the library's demo defaults", () => {
  const shell = glassParams("shell", "frosted");
  const card = glassParams("card", "frosted");
  const control = glassParams("control", "frosted");

  // Displacement grows as surfaces get smaller and more hand-adjacent.
  assert.ok(shell.displacementScale < card.displacementScale);
  assert.ok(card.displacementScale < control.displacementScale);
  // Controls trade diffusion for refraction so small labels stay crisp.
  assert.ok(control.blurAmount < card.blurAmount);
  assert.ok(card.blurAmount < shell.blurAmount);
  // A utility popup, not a demo: aberration stays under the library's 2.
  for (const params of [shell, card, control]) {
    assert.ok(params.aberrationIntensity <= 1.4, JSON.stringify(params));
    assert.ok(params.saturation < 140, JSON.stringify(params));
  }
  // The shell is never elastic — the window it decorates cannot move.
  assert.equal(shell.elasticity, 0);
  assert.deepEqual(glassParams("circle", "frosted"), control);
});

test("Clear removes the diffusion and spends it on refraction", () => {
  const frosted = glassParams("card", "frosted");
  const clear = glassParams("card", "clear");
  assert.equal(clear.blurAmount, 0);
  assert.ok(clear.displacementScale > frosted.displacementScale);
  assert.ok(clear.saturation > frosted.saturation);
  // Frozen against accidental drift; the value has to stay on one decimal so it
  // survives the round trip into an inline style.
  assert.equal(clear.displacementScale, 45.9);
});

test("Backdrop opacity clamps to 0-1 and snaps to the 2% grid", () => {
  assert.equal(BACKDROP_OPACITY_STEP, 0.02);
  assert.equal(normalizeBackdropOpacity(0.62), 0.62);
  assert.equal(normalizeBackdropOpacity(0.629), 0.62);
  // Exactly halfway rounds up, so dragging never sticks below a step boundary.
  assert.equal(normalizeBackdropOpacity(0.63), 0.64);
  assert.equal(normalizeBackdropOpacity(1.4), 1);
  assert.equal(normalizeBackdropOpacity(-3), 0);
  assert.equal(normalizeBackdropOpacity(0), 0);
  // Every stepped value has to come back as an exact multiple of 2%, not as
  // float noise a readout would render as "61%".
  for (let step = 0; step <= 50; step += 1) {
    const value = normalizeBackdropOpacity(step / 50);
    assert.equal(backdropOpacityPercent(value), step * 2);
    assert.equal(String(value), String(Math.round(value * 50) / 50));
  }
});

test("Unusable opacity falls back to the shipped default, never to invisible", () => {
  assert.equal(DEFAULT_BACKDROP_OPACITY, 0.62);
  for (const value of [undefined, null, Number.NaN, "0.4", {}, Number.POSITIVE_INFINITY]) {
    assert.equal(normalizeBackdropOpacity(value), DEFAULT_BACKDROP_OPACITY);
  }
});

test("Glass style normalizes to the two supported materials", () => {
  assert.equal(normalizeGlassStyle("clear"), "clear");
  assert.equal(normalizeGlassStyle("frosted"), "frosted");
  assert.equal(normalizeGlassStyle("etched"), "frosted");
  assert.equal(normalizeGlassStyle(undefined), "frosted");
  assert.ok(isGlassStyle("clear"));
  assert.ok(!isGlassStyle("etched"));
});

test("The scrim follows the slider one-to-one above its readability floor", () => {
  assert.equal(scrimOpacity(0.62), 0.62);
  assert.equal(scrimOpacity(0.3), 0.3);
  // Below the floor the popup would stop being legible over a bright desktop.
  assert.equal(scrimOpacity(0.04), MINIMUM_SCRIM_OPACITY);
  assert.equal(scrimOpacity(0), MINIMUM_SCRIM_OPACITY);
  // Monotonic across the whole travel: no plateau the user reads as a dead zone.
  let previous = -1;
  for (const position of SLIDER_POSITIONS) {
    const value = scrimOpacity(position);
    assert.ok(value >= previous, `${position}: ${value} < ${previous}`);
    previous = value;
  }
  // The scrim is the one thing the two styles share exactly, at every position.
  assert.equal(scrimOpacity(0.24), 0.24);
});

test("Frosted's diffusion tier is a constant of the style, not of the slider", () => {
  // macOS pins `.regularMaterial` at full strength for the same reason: with the
  // slider driving the material, the two styles traded places at the ends of its
  // travel and users read the setting as reversed.
  assert.deepEqual(FROSTED_DIFFUSION, { tint: 0.52, blur: 24, saturation: 108 });
  assert.equal(mountsDiffusionTier("frosted"), true);
  assert.equal(mountsDiffusionTier(undefined), true);
  // Clear has no material tier at all — not a thinner one.
  assert.equal(mountsDiffusionTier("clear"), false);
  // The filter is a compile-time constant, which is what keeps the cross-fade
  // off `filter`: only the layer's opacity moves.
  assert.equal(diffusionFilter(), "blur(24px) saturate(108%)");
  // Thick enough to be a material rather than a tint, thin enough that the
  // popup is still glass and not a painted panel.
  assert.ok(FROSTED_DIFFUSION.tint >= 0.48 && FROSTED_DIFFUSION.tint <= 0.55);
  // A box blur averages colour toward grey; a few points back is what keeps the
  // desktop from turning monochrome behind the popup.
  assert.ok(FROSTED_DIFFUSION.saturation > 100 && FROSTED_DIFFUSION.saturation < 120);
});

test("Frosted is denser than Clear at every single slider position", () => {
  // This is the property the whole rework exists to guarantee. The old model
  // scaled the material with the slider, so at the transparent end Frosted was
  // the *lighter* of the two.
  //
  // Stated exactly: Frosted always removes a further 52% of whatever
  // transparency the slider left, so it is never behind Clear at any position
  // and the two only meet where the slider has made both fully opaque anyway.
  for (const position of SLIDER_POSITIONS) {
    const frosted = shellInkOpacity("frosted", position);
    const clear = shellInkOpacity("clear", position);
    assert.ok(frosted >= clear, `${position}: frosted ${frosted} vs clear ${clear}`);
    assert.ok(
      Math.abs((1 - frosted) - (1 - clear) * (1 - FROSTED_DIFFUSION.tint)) < 0.0005,
      `${position}: frosted ${frosted} vs clear ${clear}`
    );
  }
  // Across the whole range the slider is actually used in — the shipped default
  // is 0.62 and the panel's own scale tops out well below opaque — the gap is
  // wide enough to read as two materials rather than two densities.
  for (const position of SLIDER_POSITIONS.filter((value) => value <= DEFAULT_BACKDROP_OPACITY)) {
    assert.ok(
      shellInkOpacity("frosted", position) - shellInkOpacity("clear", position) >= 0.19,
      String(position)
    );
  }
  // Clear is the scrim and nothing else.
  assert.equal(shellInkOpacity("clear", 0.24), 0.24);
  assert.equal(shellInkOpacity("clear", 0), MINIMUM_SCRIM_OPACITY);
  // Frosted's floor: even with the slider at zero the shell keeps well over half
  // its ink, which is why its foreground never needs the raised palette.
  assert.equal(shellInkOpacity("frosted", 0), 0.578);
  assert.equal(shellInkOpacity("frosted", 0.24), 0.635);
  assert.equal(shellInkOpacity("frosted", 0.62), 0.818);
  assert.ok(shellInkOpacity("frosted", 0) > 0.5);
});

test("Card tint belongs to the style switch, not to the slider", () => {
  assert.equal(cardTintOpacity("frosted"), DEFAULT_BACKDROP_OPACITY);
  assert.equal(cardTintOpacity("clear"), 0.26);
  assert.equal(CLEAR_SURFACE_TINT_COEFFICIENT, 0.42);
  assert.ok(cardTintOpacity("clear") < DEFAULT_BACKDROP_OPACITY * CLEAR_SURFACE_TINT_COEFFICIENT + 0.01);
  // Both are a tint of the same charcoal card colour: Clear is not a lighter
  // card, it is the same card with most of its ink removed.
  assert.ok(cardTintOpacity("clear") < cardTintOpacity("frosted") / 2);
  // The slider must not reach it, at either style.
  for (const style of ["frosted", "clear"]) {
    const values = new Set(SLIDER_POSITIONS.map(() => cardTintOpacity(style)));
    assert.equal(values.size, 1, style);
  }
});

test("Frosted spends ink on its controls and Clear spends light", () => {
  // Frosted paints the app's own charcoal ladder — the Windows 10 fallback's
  // #121316 / #1a1b1f / #23252a hierarchy, seen through glass.
  assert.equal(controlTintOpacity("frosted"), 0.72);
  assert.equal(controlHoverTintOpacity("frosted"), 0.8);
  assert.ok(controlTintOpacity("frosted") > cardTintOpacity("frosted"));
  assert.ok(controlHoverTintOpacity("frosted") > controlTintOpacity("frosted"));
  // Clear puts the same two steps on white instead, because a control above a
  // faint card has to read as lighter or the desktop stops showing through.
  assert.equal(controlFillOpacity("clear"), 0.1);
  assert.equal(controlHoverFillOpacity("clear"), 0.16);
  assert.ok(controlHoverFillOpacity("clear") > controlFillOpacity("clear"));
  // Exactly one of the two ladders is live per style; neither ever stacks a
  // white veil on a dense charcoal pane or vice versa.
  assert.equal(controlFillOpacity("frosted"), 0);
  assert.equal(controlHoverFillOpacity("frosted"), 0);
  assert.equal(controlTintOpacity("clear"), 0);
  assert.equal(controlHoverTintOpacity("clear"), 0);
});

test("Frosted keeps the macOS flat border curve and Clear keeps the ring", () => {
  // macOS `borderOpacity`: 0.85 − 0.40 × slider, unscaled.
  assert.equal(borderOpacity(0), 0.85);
  assert.equal(borderOpacity(1), 0.45);
  assert.equal(borderOpacity(0.24), 0.754);
  assert.equal(borderOpacity(DEFAULT_BACKDROP_OPACITY), 0.602);
  // The Mac spends that alpha on a charcoal hairline. On an acrylic surface the
  // edge has to be white — a charcoal line vanishes over a bright desktop — so
  // the curve is converted rather than copied.
  assert.equal(FROSTED_BORDER_WHITE_COEFFICIENT, 0.28);
  assert.equal(frostedBorderOpacity(0.24), 0.211);
  assert.equal(frostedBorderOpacity(DEFAULT_BACKDROP_OPACITY), 0.169);
  assert.equal(frostedBorderOpacity(0), 0.238);
  assert.equal(frostedBorderOpacity(1), 0.126);
  // Visible at the transparent end, never a drawn white box at either end.
  for (const position of SLIDER_POSITIONS) {
    const value = frostedBorderOpacity(position);
    assert.ok(value >= 0.12 && value <= 0.24, `${position}: ${value}`);
  }
  // The curve falls: the denser the shell, the less edge a card needs on it.
  assert.ok(frostedBorderOpacity(0.24) > frostedBorderOpacity(0.62));
  assert.equal(cardStrokeOpacity("frosted", 0.24), frostedBorderOpacity(0.24));
  // Clear's flat stroke is a constant — its real edge is the gradient ring, and
  // this only covers what the ring cannot (forced colours, no acrylic).
  assert.equal(cardStrokeOpacity("clear", 0.24), 0.14);
  assert.equal(cardStrokeOpacity("clear", 1), 0.14);
});

test("Only Clear wears the top-lit gradient rim", () => {
  assert.equal(RIM_GRADIENT_ANGLE_DEG, 135);
  assert.equal(wearsGradientRim("clear"), true);
  assert.equal(wearsGradientRim("frosted"), false);
  assert.equal(wearsGradientRim(undefined), false);
  const clear = rimGradientStops("clear");
  assert.deepEqual(clear, { start: 0.25, end: 0.11 });
  // The falloff is the whole effect: an even stroke reads as a drawn outline, a
  // falling one reads as a single light source crossing a pane.
  assert.ok(clear.start > clear.end * 2);
  // Frosted's ring is not merely faint, it does not exist — the CSS ::after that
  // draws it is scoped to Clear, and these zeros are the belt to that braces.
  assert.deepEqual(rimGradientStops("frosted"), { start: 0, end: 0 });
  // Same split for the inner lip: it is the thickness of a pane of glass, and a
  // dense charcoal card is not one.
  assert.equal(INNER_HIGHLIGHT_OPACITY, 0.1);
  assert.equal(innerHighlightOpacity("clear"), 0.1);
  assert.equal(innerHighlightOpacity("frosted"), 0);
});

test("The shell edge is strongest where the popup meets the desktop", () => {
  // Clear carries slightly more because Frosted's diffusion already separates
  // the popup from whatever sits behind it — macOS shellRimHighlightOpacity.
  assert.equal(shellStrokeOpacity("frosted"), 0.2);
  assert.equal(shellStrokeOpacity("clear"), 0.22);
  assert.ok(shellStrokeOpacity("clear") > shellStrokeOpacity("frosted"));
  // The shell holds the whole window; a card sits on the shell and needs less.
  for (const style of ["frosted", "clear"]) {
    assert.ok(shellStrokeOpacity(style) > cardStrokeOpacity(style, DEFAULT_BACKDROP_OPACITY), style);
  }
});

test("Rim strength on the plain backdrop is independent of the fill", () => {
  // Deriving the edge from the inverse of the fill made the most transparent
  // popup the most heavily outlined one — the opposite of how glass behaves.
  assert.equal(rimOpacity("shell", "clear"), 0.32);
  assert.equal(rimOpacity("shell", "frosted"), 0.24);
  assert.equal(rimOpacity("card", "clear"), 0.17);
  assert.equal(rimOpacity("card", "frosted"), 0.13);
  // Cards sit on the shell, not on the desktop, so they carry less edge.
  assert.ok(rimOpacity("card", "frosted") < rimOpacity("shell", "frosted"));
});

test("The foreground raise is Clear's alone", () => {
  // Clear is transparent by definition, at every slider position.
  for (const position of SLIDER_POSITIONS) {
    assert.equal(needsAdaptiveForeground({ glassStyle: "clear", backdropOpacity: position }), true, String(position));
    // Frosted's diffusion floor means the ordinary palette always holds. The
    // previous threshold existed because Frosted at a low slider value really
    // was thin, and the fixed tier is exactly what removed that case.
    assert.equal(needsAdaptiveForeground({ glassStyle: "frosted", backdropOpacity: position }), false, String(position));
    assert.ok(shellInkOpacity("frosted", position) > 0.5, String(position));
  }
  assert.equal(needsAdaptiveForeground(), false);
});

test("The glyph edge rides with the raised palette and nothing else", () => {
  assert.equal(adaptiveShadowOpacity({ glassStyle: "clear" }), ADAPTIVE_SHADOW_OPACITY);
  assert.equal(ADAPTIVE_SHADOW_OPACITY, 0.78);
  // A surface that does not need the raise gets no shadow, so the token can be
  // written unconditionally and the CSS never has to branch.
  assert.equal(adaptiveShadowOpacity({ glassStyle: "frosted" }), 0);
  assert.equal(adaptiveShadowOpacity({ glassStyle: "frosted", backdropOpacity: 0 }), 0);
  assert.equal(adaptiveShadowOpacity(), 0);
});

test("Only the opaque dashboard window earns the refracting material", () => {
  // CSS backdrop-filter does not work inside a `transparent: true` Electron
  // window on Windows (electron/electron#30412): each filtered element's
  // backdrop root paints opaque black, with or without DWM acrylic. The
  // popover and the floating shortcut are both transparent, so they always
  // take the plain CSS backdrop; only the opaque dashboard refracts.
  assert.equal(backdropModeForWindow("opaque"), "material");
  for (const kind of ["transparent", undefined, "", "acrylic", "Opaque"]) {
    assert.equal(backdropModeForWindow(kind), "none", String(kind));
  }
});

test("The backdrop mode normalizes to the two supported modes", () => {
  assert.deepEqual(BACKDROP_MODES, ["material", "none"]);
  assert.equal(DEFAULT_BACKDROP_MODE, "material");
  assert.equal(normalizeBackdropMode("none"), "none");
  assert.equal(normalizeBackdropMode("material"), "material");
  // An unreadable value must fall back to the refracting material, not to the
  // plain one: a surface that quietly stops refracting is a look regression a
  // reviewer would have to notice by eye, while the black square is only
  // reachable through the two windows that ask for "none" explicitly.
  for (const value of [undefined, null, "plain", "", 0, false, {}]) {
    assert.equal(normalizeBackdropMode(value), DEFAULT_BACKDROP_MODE, String(value));
  }
  // The decision helper only ever produces modes the surface understands.
  for (const kind of ["opaque", "transparent", undefined]) {
    assert.ok(BACKDROP_MODES.includes(backdropModeForWindow(kind)));
    assert.equal(normalizeBackdropMode(backdropModeForWindow(kind)), backdropModeForWindow(kind));
  }
});

test("The specular is weak enough that it cannot resolve as a shape", () => {
  // The defect it replaces was the shared corner highlight at full rim strength:
  // spread across a card 376px wide it read as a pale band along the top edge.
  for (const style of ["frosted", "clear"]) {
    assert.ok(specularOpacity(style) <= 0.04, style);
    assert.ok(specularOpacity(style) > 0, style);
    assert.ok(specularOpacity(style) < rimOpacity("card", style), style);
  }
  assert.equal(specularOpacity("frosted"), 0.04);
  assert.equal(specularOpacity("clear"), 0.03);
});

test("The second blur is Clear's material, and the flyout's alone on Frosted", () => {
  assert.deepEqual(BLUR_TIERS, ["shell", "card", "control", "flyout"]);
  // Clear reveals the desktop, so every tier above the shell re-blurs what still
  // shows through the scrim — that pass is the difference between a card that
  // reads as glass and one that reads as paint.
  assert.equal(layerBlurRadius("card", "clear"), 20);
  assert.equal(layerBlurRadius("control", "clear"), 16);
  assert.equal(layerBlurRadius("flyout", "clear"), 28);
  assert.ok(layerBlurRadius("control", "clear") < layerBlurRadius("card", "clear"));
  // Frosted's diffusion tier has already made the desktop unreadable, so a card
  // re-blurring a blur would buy a compositing pass and nothing else.
  assert.equal(layerBlurRadius("card", "frosted"), 0);
  assert.equal(layerBlurRadius("control", "frosted"), 0);
  assert.equal(layerBackdropFilter("card", "frosted"), "none");
  assert.equal(layerBackdropFilter("control", "frosted"), "none");
  assert.equal(layerBackdropFilter("card", "clear"), "blur(20px) saturate(116%)");
  // The shell never blurs in either style: a backdrop-filter there would make it
  // the backdrop root for every card inside, which would then re-blur the
  // shell's own paint instead of the desktop. Frosted's diffusion carries its
  // blur on a child layer for exactly that reason.
  for (const style of ["frosted", "clear"]) {
    assert.equal(layerBlurRadius("shell", style), 0, style);
    assert.equal(layerBackdropFilter("shell", style), "none", style);
    // A flyout hides rather than reveals, so it keeps the hardest blur at both
    // styles — a menu that leaked the card behind it is a rendering fault.
    assert.equal(layerBlurRadius("flyout", style), 28, style);
  }
  // Saturation compensates for what a box blur averages away, and stays under
  // 120% so the desktop never starts tinting the popup's own neutrals.
  for (const tier of ["card", "control", "flyout"]) {
    assert.ok(layerSaturation(tier) >= 110 && layerSaturation(tier) < 120, tier);
  }
  // An unknown tier lands on the card step, the same fallback roleRadius takes.
  assert.equal(layerBlurRadius("banner", "clear"), layerBlurRadius("card", "clear"));
  assert.equal(layerSaturation(undefined), layerSaturation("card"));
});

test("Surface variables expose every value CSS needs, as CSS values", () => {
  assert.deepEqual(surfaceVariables({ role: "shell", glassStyle: "frosted", backdropOpacity: 0.62 }), {
    "--glass-radius": "14px",
    "--glass-shell-radius": "14px",
    "--glass-card-radius": "13px",
    "--glass-control-radius": "9px",
    "--glass-scrim-opacity": "0.62",
    "--glass-diffusion-tint": "0.52",
    "--glass-diffusion-filter": "blur(24px) saturate(108%)",
    "--glass-shell-stroke": "0.2",
    "--glass-tint-opacity": "0.62",
    "--glass-control-tint": "0.72",
    "--glass-control-hover-tint": "0.8",
    "--glass-control-fill": "0",
    "--glass-control-hover-fill": "0",
    "--glass-card-stroke": "0.169",
    "--glass-rim-opacity": "0.24",
    "--glass-specular-opacity": "0.04",
    "--glass-card-backdrop": "none",
    "--glass-control-backdrop": "none",
    "--glass-flyout-backdrop": "blur(28px) saturate(118%)",
    "--glass-flyout-scrim": "0.85",
    "--glass-rim-gradient-start": "0",
    "--glass-rim-gradient-end": "0",
    "--glass-inner-highlight": "0",
    "--glass-surface-shadow": "0 8px 24px rgb(0 0 0 / 0.25)",
  });
  assert.deepEqual(surfaceVariables({ role: "control", glassStyle: "clear", backdropOpacity: 0 }), {
    "--glass-radius": "9px",
    "--glass-shell-radius": "14px",
    "--glass-card-radius": "13px",
    "--glass-control-radius": "9px",
    "--glass-scrim-opacity": "0.12",
    "--glass-diffusion-tint": "0.52",
    "--glass-diffusion-filter": "blur(24px) saturate(108%)",
    "--glass-shell-stroke": "0.22",
    "--glass-tint-opacity": "0.26",
    "--glass-control-tint": "0",
    "--glass-control-hover-tint": "0",
    "--glass-control-fill": "0.1",
    "--glass-control-hover-fill": "0.16",
    "--glass-card-stroke": "0.14",
    "--glass-rim-opacity": "0.17",
    "--glass-specular-opacity": "0.03",
    "--glass-card-backdrop": "blur(20px) saturate(116%)",
    "--glass-control-backdrop": "blur(16px) saturate(112%)",
    "--glass-flyout-backdrop": "blur(28px) saturate(118%)",
    "--glass-flyout-scrim": "0.85",
    "--glass-rim-gradient-start": "0.25",
    "--glass-rim-gradient-end": "0.11",
    "--glass-inner-highlight": "0.1",
    "--glass-surface-shadow": "0 8px 24px rgb(0 0 0 / 0.25)",
  });
  // Called with nothing at all it still produces a usable default surface, and
  // the default is Frosted at the shipped slider position.
  const fallback = surfaceVariables();
  assert.equal(fallback["--glass-radius"], "13px");
  assert.equal(fallback["--glass-tint-opacity"], "0.62");
  assert.equal(fallback["--glass-card-stroke"], "0.169");
  assert.equal(fallback["--glass-rim-opacity"], "0.13");
  const fluent = surfaceVariables({ role: "shell", radiusLadder: "fluent" });
  assert.equal(fluent["--glass-radius"], "0px");
  assert.equal(fluent["--glass-shell-radius"], "0px");
  assert.equal(fluent["--glass-card-radius"], "8px");
  assert.equal(fluent["--glass-control-radius"], "6px");
});

test("The theme defaults match what the model publishes for Frosted", () => {
  // theme.css carries a static copy of the Frosted token set, so a surface that
  // has not been re-rendered yet still paints the shipped style rather than an
  // arbitrary mix. Drift between the two would show as a one-frame flash.
  const frosted = surfaceVariables({ glassStyle: "frosted", backdropOpacity: DEFAULT_BACKDROP_OPACITY });
  assert.equal(frosted["--glass-diffusion-tint"], "0.52");
  assert.equal(frosted["--glass-diffusion-filter"], "blur(24px) saturate(108%)");
  assert.equal(frosted["--glass-control-tint"], "0.72");
  assert.equal(frosted["--glass-control-hover-tint"], "0.8");
  assert.equal(frosted["--glass-card-backdrop"], "none");
  assert.equal(frosted["--glass-control-backdrop"], "none");
  assert.equal(frosted["--glass-flyout-backdrop"], "blur(28px) saturate(118%)");
});

test("The ladder is ambient: every surface publishes the same steps", () => {
  // Plain DOM inside a card — a menu, a badge, a feed row, the widget header's
  // bare buttons — has to be able to place itself on the ladder without being
  // wrapped in a GlassSurface, so the steps cannot be role-scoped the way the
  // radius and the plain-backdrop rim are.
  const shell = surfaceVariables({ role: "shell", glassStyle: "frosted" });
  const card = surfaceVariables({ role: "card", glassStyle: "frosted" });
  const control = surfaceVariables({ role: "control", glassStyle: "frosted" });
  for (const token of [
    "--glass-diffusion-tint",
    "--glass-diffusion-filter",
    "--glass-shell-stroke",
    "--glass-tint-opacity",
    "--glass-control-tint",
    "--glass-control-hover-tint",
    "--glass-control-fill",
    "--glass-control-hover-fill",
    "--glass-card-stroke",
    "--glass-specular-opacity",
    "--glass-card-backdrop",
    "--glass-control-backdrop",
    "--glass-flyout-backdrop",
    "--glass-flyout-scrim",
    "--glass-rim-gradient-start",
    "--glass-rim-gradient-end",
    "--glass-inner-highlight",
    "--glass-surface-shadow",
  ]) {
    assert.equal(shell[token], card[token], token);
    assert.equal(card[token], control[token], token);
  }
  // Every step has to survive the round trip into an inline style as a number
  // CSS can read, never as exponential notation or float noise.
  for (const style of ["frosted", "clear"]) {
    for (const position of SLIDER_POSITIONS) {
      const variables = surfaceVariables({ role: "card", glassStyle: style, backdropOpacity: position });
      for (const [token, value] of Object.entries(variables)) {
        if (CSS_VALUE_TOKENS.has(token)) continue;
        assert.match(value, /^\d+(\.\d+)?$/, `${style} ${position} ${token}: ${value}`);
      }
    }
  }
});

test("The two styles are a different material everywhere it counts", () => {
  // One assertion for the whole point of the setting: at the same slider
  // position the styles have to differ in shell density, card density, edge
  // treatment and second blur — not in one of them.
  for (const position of [0, 0.24, DEFAULT_BACKDROP_OPACITY]) {
    assert.ok(shellInkOpacity("frosted", position) > shellInkOpacity("clear", position), String(position));
    assert.ok(cardTintOpacity("frosted") > cardTintOpacity("clear"));
    assert.notEqual(
      cardStrokeOpacity("frosted", position),
      cardStrokeOpacity("clear", position)
    );
    assert.notEqual(wearsGradientRim("frosted"), wearsGradientRim("clear"));
    assert.notEqual(layerBlurRadius("card", "frosted"), layerBlurRadius("card", "clear"));
  }
});

test("The lift and the flyout scrim are fixed, not style-dependent", () => {
  assert.deepEqual(SURFACE_SHADOW, { y: 8, blur: 24, opacity: 0.25 });
  assert.equal(surfaceShadow(), "0 8px 24px rgb(0 0 0 / 0.25)");
  // Soft on purpose: eight cards stack in one scroll region, and anything
  // heavier turns the widget list into a stack of trays.
  assert.ok(SURFACE_SHADOW.opacity < 0.3);
  // A Clear menu that leaked the card behind it would read as a rendering
  // fault, not as a material, so the occluding scrim is the one value the
  // style switch does not touch.
  assert.equal(FLYOUT_SCRIM_OPACITY, 0.85);
  for (const style of ["frosted", "clear"]) {
    assert.equal(surfaceVariables({ glassStyle: style })["--glass-flyout-scrim"], "0.85", style);
    assert.equal(surfaceVariables({ glassStyle: style })["--glass-surface-shadow"], surfaceShadow(), style);
  }
});
