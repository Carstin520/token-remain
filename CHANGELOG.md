# Changelog

All notable product changes are recorded here. TokenRemain uses Semantic
Versioning for public releases.

## Unreleased (1.1.4, build 6)

### Added

- Expanded the product website with a clearer AI Feed, privacy, and provider
  story.
- Added a secondary sync-details screen so advanced diagnostics remain
  available without crowding the main settings page.

### Changed

- Ranked popular AI Feed posts consistently across Mac, broadcast delivery, and
  iPhone.
- Improved iPhone Feed typography and spacing for long author names, handles,
  timestamps, and multi-line posts.
- Made quota reset labels use weeks, days, or an `HH:mm:ss` countdown according
  to the remaining interval.
- Updated installer and Apple Watch artwork to match the current TokenRemain
  brand.

### Fixed

- Prevented background provider refreshes from prompting for Keychain access.
- Fixed stale Mac snapshot timestamps and ignored invalid past reset dates on
  iPhone.
- Added clearer sync security diagnostics while retaining the last known-good
  snapshot after a failed validation.

## 1.1.2 — 2026-07-24

### Fixed

- Prevented a terminated provider subprocess from holding the automatic quota
  refresh open indefinitely.
- Applied each provider result immediately so a slow local probe no longer
  delays fresh Mac data or CloudKit delivery.
- Isolated ccusage history collection from the quota refresh lock and restored
  a fixed one-minute automatic capture cadence.

## 1.1.1 — 2026-07-24

### Added

- Added signed, automatic background updates for the Developer ID Mac app.
- Added release-time appcast generation with EdDSA archive and feed
  verification.

### Fixed

- Updated the iPhone production build so it reads the same CloudKit Production
  database as the released Mac app.

## 1.1.0 — 2026-07-24

### Changed

- Isolated ordinary local development builds from the stable CloudKit-enabled
  Mac application.
- Added staged, incoming, and installed bundle validation before a sync build
  can replace `TokenRemain.app`.
- Reduced the unchanged-data Mac heartbeat interval to five minutes while
  retaining the four-second changed-data debounce.
- Added regression checks for the automatic-sync and installation-isolation
  contracts.

- Deployed the reviewed `TRCurrentSnapshot` schema to CloudKit Production and
  verified a Developer ID build saving the encrypted current snapshot in the
  user's private database.

## 1.0.0 — 2026-07-23

- Established the first packaged TokenRemain release baseline.
- Published the server-curated AI broadcast path.

[1.0.0]: https://github.com/Carstin520/token-remain/releases/tag/v1.0.0
[1.1.0]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.0
[1.1.1]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.1
[1.1.2]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.2
