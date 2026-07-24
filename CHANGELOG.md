# Changelog

All notable product changes are recorded here. TokenRemain uses Semantic
Versioning for public releases.

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
