# TokenRemain Desktop Visual QA

final result: passed

## 2026-08-02 Brand Palette And AI Feed Edge

### Scope

- Brand reference: `/var/folders/7w/9frvs6s13qg3_w5rmk61b_cc0000gn/T/TemporaryItems/NSIRD_screencaptureui_zEuIpU/截屏2026-08-02 13.59.49.png`
- Washed-out card reference: `/Users/jamesli/Desktop/截屏2026-08-02 14.09.40.png`
- Current implementation: `/tmp/tokenremain-ai-feed-component-edge.png`
- Focused wordmark implementation: `/tmp/tokenremain-wordmark-desktop-focus.png`
- State: macOS dark Dashboard, Overview / AI Feed, idle cards.
- Viewport: 1180 × 760 pt at 2×; implementation capture 2360 × 1520 px.
- Source pixels: wordmark 328 × 110; card reference 1870 × 406. The focused
  implementation crop is 370 × 115 px, close enough for direct glyph/color
  inspection without resampling.

### Required fidelity surfaces

- Fonts and typography: both wordmarks use a bold monospaced face with the same
  Token/Remain split; the app keeps its established SF Mono optical size so the
  sidebar hierarchy is preserved.
- Spacing and layout rhythm: the wordmark remains aligned with the existing robot
  and sidebar grid. Card padding, radius, row spacing, and content wrapping are
  unchanged.
- Colors and visual tokens: sampled reference colors `#080A11`, `#EAEDF4`, and
  `#8B7CEB` are now the desktop canvas, Token text, and Remain/product accent.
  Cyan and violet priority edges are fully visible in the idle state.
- Image quality and asset fidelity: no raster replacement was introduced; the
  existing robot artwork stays sharp, while the wordmark remains native text.
- Copy and content: all labels and post content remain unchanged.

### Comparison history

1. Initial comparison found a P2 visibility mismatch: the important-card edge was
   blended by the macOS Liquid Glass surface and was difficult to distinguish.
2. `AIFeedPostCard` was changed to own an opaque neutral fill, independent glow,
   priority stroke, corner ticks, and side rail instead of delegating its
   edge to the shared glass modifier.
3. The revised capture shows continuous cyan and violet edges on every side with
   no loss of text contrast or layout. No actionable P0/P1/P2 differences remain.
4. A brightness refinement reduced the priority stroke to 1.5 pt at 80% opacity,
   cut the idle glow to 11%, and softened the rail/ticks. The edge remains visible
   without competing with article text.
5. A semantic-color audit aligned quota, price, Token, and reset announcements
   with the fluorescent cyan already used by Trending. Amber is now reserved for
   stale data, missing credentials, sync failures, and quota-risk warnings.

### Focused comparison evidence

- The source and focused implementation were inspected together. Token is cool
  white, Remain is violet, and the split occurs at the same character boundary.
- The full implementation and washed-out reference were inspected together. The
  new component-owned stroke remains visible around all four sides instead of
  disappearing into the glass surface.

### Follow-up polish

- Hover glow was not included in the static comparison; idle-state visibility was
  the acceptance target and passed.

## Previous Brand Integration Record

## Scope

- Reference: `design/token-remain-logo-gallery/public/logos/background-waterline-emotion-states-11/50-neutral-dashes.png`
- Popover capture: `design/audit/2026-07-19-token-remain-brand/popover-final.png`
- Dashboard capture: `design/audit/2026-07-19-token-remain-brand/dashboard-final.png`
- Side-by-side comparison: `design/audit/2026-07-19-token-remain-brand/reference-comparison.png`

## Visual checks

- The selected pixel robot, violet stepped shell, dark face, cyan water field, and neutral dash eyes remain recognizable in the 36 pt popover logo.
- The logo was center-cropped before app packaging so the robot remains legible at menu-bar and sidebar sizes.
- The live 46% minimum-provider state selects the intended neutral-dash expression.
- `TokenRemain` is visible in the popover header, Dashboard sidebar lockup, navigation title, and native window title.
- The icon does not collide with the header subtitle or refresh control.
- The Dashboard sidebar remains aligned and readable with the wider product name.

## Functional checks

- The app selects one of eleven image states from the lowest available provider quota.
- Missing data uses the neutral state; zero quota uses the offline X-eye state.
- The installed app bundle includes all eleven state images and `TokenRemain.icns`.
- Build, tests, signing, installation, and launch verification passed.

## Remaining polish

- None required for this integration pass.

---

# Windows Popup Local Usage Ring QA

final result: passed

## Comparison target

- Source visual truth: `/var/folders/7w/9frvs6s13qg3_w5rmk61b_cc0000gn/T/TemporaryItems/NSIRD_screencaptureui_Sg7de0/Screenshot 2026-08-09 at 17.43.23.png`
- Rendered implementation: `/tmp/tokenremain-popover-usage-ring-after.png`
- Side-by-side comparison: `/tmp/tokenremain-usage-ring-comparison.png`
- Browser viewport: `400 x 720` CSS px, dark popup preview at `/popover.html`
- Source pixels: `736 x 438` at macOS 2x density, normalized to `368 x 219`
- Implementation crop: `374 x 215` at browser 1x density
- State: Local Usage populated with two providers; default and Codex-focused states checked

## Full-view evidence

- The 400 x 720 popup keeps its fixed header/footer, quota cards, Local Usage card, AI Feed, and vertical scrolling without horizontal overflow.
- Adding the 52 px ring does not clip the provider rows or push the card outside the 374 px content width.
- Page identity, meaningful DOM, framework-overlay check, and warning/error console check all passed.

## Focused component evidence

- The focused card comparison uses the same dark theme and populated two-provider state as the source.
- The implementation restores the source's ring-left/provider-rows-right composition, 52 px diameter, 8 px ring thickness, empty default center, and provider-color segments.
- The implementation card is 6 px wider and 4 px shorter than the normalized macOS crop because the Windows popup retains its existing 400 px frame and denser Segoe/Cascadia typography. This is an intentional platform constraint, not component drift.

## Required fidelity surfaces

- Fonts and typography: Windows keeps the existing Segoe UI Variable and Cascadia Mono stack; title, amount, provider labels, token totals, and percentages retain the source hierarchy without truncation.
- Spacing and layout rhythm: 52 px ring, 14 px composition gap, 22 px provider rows, 7 px row radius, and the existing spend divider align closely with the macOS card.
- Colors and tokens: Codex `#6687c5`, Claude `#bf8471`, surface, border, secondary text, and muted text use the shared TokenRemain tokens.
- Image quality and asset fidelity: the usage chart is rendered from live proportions at display resolution; no raster placeholder or generated image is used.
- Copy and content: Today's Local Usage, provider names, token totals, percentages, Today, Yesterday, Last 30 Days, and Usage Trend remain unchanged.

## Comparison history

1. P1 before fix: the Windows popup rendered provider dots and percentages but omitted the macOS circular composition chart entirely.
2. Fix: added the proportional ring, provider-row/focus linkage, center detail on highlight, accessible distribution label, and shared geometry tests.
3. Post-fix evidence: the default screenshot shows both colored segments; focusing Codex highlights its row, dims Claude's segment, and shows `$10.70 / 14.60M` in the center. No actionable P0, P1, or P2 mismatch remains.

## Verification

- `npm run check`: 97/97 tests passed and Vite production build succeeded.
- `git diff --check`: clean.
- Browser interaction: Codex row focus changed the row class to `is-highlighted`, updated the ring gradient, and populated the center detail.
- Console warnings/errors: none.

final result: passed

---

# Windows Trends macOS-Parity QA

## Comparison target

- Source visual truth: `/var/folders/7w/9frvs6s13qg3_w5rmk61b_cc0000gn/T/TemporaryItems/NSIRD_screencaptureui_TjlbEq/Screenshot 2026-08-09 at 18.28.19.png`
- Pre-fix Windows evidence: `/var/folders/7w/9frvs6s13qg3_w5rmk61b_cc0000gn/T/TemporaryItems/NSIRD_screencaptureui_Qd3B12/Screenshot 2026-08-09 at 18.27.58.png`
- Rendered implementation: `/tmp/tokenremain-trends-windows-final-900x704.png`
- Normalized source: `/tmp/tokenremain-trends-macos-reference-900x704.png`
- Side-by-side comparison: `/tmp/tokenremain-trends-comparison.png`
- Browser viewport: `1124 x 704` CSS px at DPR 1; implementation comparison clips the 900 px main-content region after the 224 px Windows sidebar.
- Source pixels: `1800 x 1408` at macOS 2x density, normalized to `900 x 704`.
- Implementation pixels: `900 x 704` at browser 1x density.
- State: dark theme, Daily Usage default `14 d / Tokens`, Quota Consumption default `7 d`, three populated quota rows.

## Full-view evidence

- The first card now restores the macOS hierarchy: title/source, LIVE tag, provider legend, 7/14/30-day selector, Tokens/Cost selector, dotted total trend, one labeled y-axis, thin stacked daily bars, and responsive x-axis labels.
- The former fixed-height tracks are gone. Every stack now starts on the baseline and represents its real value against a rounded shared axis maximum.
- The missing Quota Consumption Trend card is present immediately below Daily Usage, with range selection, APP/WINDOW/USED/TREND columns, provider assets, and a fixed 0–100% sparkline per row.
- At the normalized 900 x 704 comparison size, the two primary cards occupy the same above-the-fold hierarchy as the macOS source. Summary cards continue below without horizontal overflow.

## Focused component evidence

- Daily Usage interaction checks passed for 7, 14, and 30 days; Tokens and Cost each update the bars, total sparkline, axis values, accessible labels, and tooltip values.
- Hovering a day exposes a bounded tooltip with date, Claude, Codex, and total values while dimming neighboring stacks.
- Quota range checks passed for 7, 14, and 30 days. Provider rows follow the saved Limits order instead of introducing a second Windows-only ordering preference.
- The Cursor mark uses the supplied brand SVG with a Windows presentation tint, removing the black-on-charcoal failure visible during the first comparison.

## Required fidelity surfaces

- Fonts and typography: Windows keeps Segoe UI Variable and Cascadia Mono as the platform-native equivalent; sizes, weights, uppercase table labels, numeric alignment, and compact control labels match the source hierarchy without truncation.
- Spacing and layout rhythm: the oversized first card was reduced from 394 px to approximately 339 px at the QA viewport; chart plot height, row height, card gaps, panel padding, and radii now track the normalized macOS composition.
- Colors and visual tokens: violet selection, Claude `#BF8471`, Codex `#6687C5`, Cursor `#9684CD`, charcoal surfaces, borders, gridlines, and muted axis text use the shared TokenRemain palette.
- Image quality and asset fidelity: Claude, Codex, and Cursor use the existing provider assets. Charts are rendered from live vector/data geometry at display resolution; there are no raster chart placeholders.
- Copy and content: macOS labels and control names are preserved. Source wording intentionally says `synced daily aggregate` / `synced from your Mac` on Windows instead of falsely claiming Windows-local ccusage.

## Comparison history

1. P1 before fix: Daily Usage was a non-interactive seven-day track chart with no range or metric controls, total trend, real y-axis, tooltip, or macOS density.
2. Fix: ported the three ranges, two metrics, shared nice axis, total sparkline, stacked bars, date thinning, hover/focus tooltip, and accessible per-day summaries.
3. P1 before fix: Quota Consumption Trend was omitted entirely and Windows retained no quota history to power it.
4. Fix: added DPAPI-protected local quota history with 15-minute buckets and 45-day retention, plus the complete range-controlled percentage trend table and honest accumulating state.
5. P2 first comparison: the Daily Usage card remained too tall and the Cursor SVG rendered black.
6. Fix: normalized the chart/card proportions against the 2x source and tinted the supplied currentColor Cursor asset with its provider token.
7. Post-fix evidence: the normalized side-by-side comparison has no remaining actionable P0, P1, or P2 mismatch. Platform font rendering and Windows-specific synced-source copy are intentional.

## Verification

- `npm run check`: 103/103 tests passed and the Vite production build succeeded.
- `git diff --check`: clean.
- Browser interactions: 7/14/30-day Daily Usage, Tokens/Cost, 7/14/30-day Quota Consumption, and day hover tooltip passed.
- Browser console warnings/errors: none.

## Follow-up polish

- P3: native Windows validation should confirm the same density under 125% and 150% display scaling; browser evidence cannot replace that final device check.

final result: passed
