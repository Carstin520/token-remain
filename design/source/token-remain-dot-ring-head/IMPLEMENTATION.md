# O4-C production integration

The accepted artwork is the native Icon Composer refinement under `review/apple-refinement-v2/`. `reference/` remains the geometry source; it is not a production replacement asset.

## Product decision after the original specification

On 2026-10-27 the user requested one app selector because the Dock now displays one quota ring. The settings preview and runtime Dock therefore use the first selected app only. The old two-element `dockLogoProviders` storage format is unchanged for downgrade compatibility; its second element does not drive or backfill the ring. The original minimum-of-slots helper remains available and tested.

## Reproduction

- `script/build_token_remain_icons.sh` builds the macOS ICNS and the website/Windows PNG sources from `DotRingIconArtwork.swift` and the approved `native-lighting/` images. It does not generate expression or full-body resources.
- `windows`: `npm run icon:generate` selects small, medium, or full input by the actual ICO size. `npm run locales:generate` reads the authoritative macOS strings.
- The iOS repository uses `script/generate_dynamic_app_icons.swift` and its `design/app-icon-dot-ring/native-head-lighting.png` to generate Any, Dark, Tinted, alternate, and Watch catalogs. It keeps the iOS 18-compatible appiconset path and does not enable alternate-icon switching.
- The native `.icon` groups are stored front to back as Face, Head, Ring. Only Head receives native material lighting. Runtime Dock drawing keeps the same geometry and base palette without native glass.

`native-lighting/` contains the accepted native render for each size variant. Generation clips that material to the head silhouette, then paints the face, eyes, and quota dots in sRGB. It does not bake the system background bezel into the full-bleed platform tiles.

## Validation notes

Use the normal `iconutil` encoder for ICNS. Small `ic04`/`ic05` chunks store ARGB planes; their original bytes are checked by the logo regression test. Reverse conversion through `iconutil` is not used as a pixel oracle for these chunks.

Stage B validation evidence, exact source hashes, file manifest, baseline backups, and platform limitations are recorded in the task-local verification handoff. No release, deployment, or Git publication is implied by generation or local verification.
