# Changelog

All notable product changes are recorded here. TokenRemain uses Semantic
Versioning for public releases.

## Unreleased — 1.1.0

### Changed

- Isolated ordinary local development builds from the stable CloudKit-enabled
  Mac application.
- Added staged, incoming, and installed bundle validation before a sync build
  can replace `TokenRemain.app`.
- Reduced the unchanged-data Mac heartbeat interval to five minutes while
  retaining the four-second changed-data debounce.
- Added regression checks for the automatic-sync and installation-isolation
  contracts.

### Release blocker

- Deploy and verify the reviewed `TRCurrentSnapshot` schema in the CloudKit
  Production environment before tagging `v1.1.0`.

## 1.0.0 — 2026-07-23

- Established the first packaged TokenRemain release baseline.
- Published the server-curated AI broadcast path.

[1.0.0]: https://github.com/Carstin520/token-remain/releases/tag/v1.0.0
