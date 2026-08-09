# TokenRemain Brand Integration QA

final result: passed

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
