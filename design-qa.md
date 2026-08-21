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
