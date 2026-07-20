# Token Remain Brand Integration QA

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
- `Token Remain` is visible in the popover header, Dashboard sidebar lockup, navigation title, and native window title.
- The icon does not collide with the header subtitle or refresh control.
- The Dashboard sidebar remains aligned and readable with the wider product name.

## Functional checks

- The app selects one of eleven image states from the lowest available provider quota.
- Missing data uses the neutral state; zero quota uses the offline X-eye state.
- The installed app bundle includes all eleven state images and `TokenRemain.icns`.
- Build, tests, signing, installation, and launch verification passed.

## Remaining polish

- None required for this integration pass.
