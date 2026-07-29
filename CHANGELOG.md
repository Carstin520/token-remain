# Changelog

All notable product changes are recorded here. TokenRemain uses Semantic
Versioning for public releases.

## 1.2.0 — Unreleased

### Added

- Added encrypted multi-Mac `source-v2` synchronization: every Mac owns a
  stable private source record, the iPhone authenticates and aggregates up to
  16 independent sources, and stale, malformed, replayed, or deleted sources
  are isolated without rolling back healthy data.
- Added per-Mac source visibility and management, anonymous health/data
  exports, single-source removal, and separate controls for disconnecting this
  Mac versus deleting all iCloud sync data.
- Added dynamic local-usage sources for every agent discovered by the bundled
  ccusage collector, with per-source inclusion controls and stable names for
  Claude, Codex, OpenCode, Amp, Droid, Codebuff, Hermes, pi, Goose, OpenClaw,
  Kilo, Kimi, Qwen, Copilot, and Gemini.
- Added a privacy-minimized Trae Agent trajectory reader that decodes only
  timestamps, provider/model names, and aggregate token counters from
  user-selected local trajectory folders.
- Added an independent Windsurf quota provider, local app detection, official
  brand artwork, and cross-device provider support.
- Added an explicit, user-initiated read-only Keychain authorization action for
  Claude and Codex while keeping every background credential read silent.

### Changed

- Parse unchanged Codex session files from cache, tolerate bounded filesystem
  clock skew, and prune deleted-session entries instead of rescanning history.
- Pause AI Feed polling while all Feed surfaces are hidden and refresh stale
  content when a surface becomes visible again.
- Reduce background installed-tool detection from every ten seconds to every
  five minutes while retaining immediate foreground scans.

### Fixed

- Recalculate recognized OpenClaw and relay model usage from token counts when
  a source records a zero cost, and normalize relay model names back to direct
  official-model API list-price entries. Explicit user ccusage cost modes and
  custom price overrides remain authoritative.
- Keep expired quota reset labels static instead of leaving a one-second
  TimelineView active indefinitely.
- Include provider identity and row presence in Dock artwork cache keys so
  same-level Claude and Codex meters cannot reuse the wrong colour rendering.

### Privacy

- Public price refreshes remain fixed, bodyless complete-table downloads. No
  locally observed model name, token count, prompt, response, project, or
  trajectory content is sent to the pricing source.

## 1.1.11 — 2026-07-28

### Changed

- Build and validate Universal macOS packages for both Apple Silicon and Intel,
  including the app executable, Sparkle helpers, and the bundled ccusage helper.
- Removed runtime ccusage version notices; installed apps only report whether
  the bundled helper can read local usage successfully.
- Made release preflight and packaging update the bundled ccusage helper to the
  latest verified stable npm package before signing a new TokenRemain version.
- Publish both the stable `TokenRemain.dmg` download name and a byte-identical
  versioned DMG so each release remains directly identifiable and downloadable.

### Fixed

- Report an explicit Claude Code signed-out state immediately instead of
  waiting for the fallback terminal probe to time out at the login screen.

## 1.1.10 — 2026-07-26

### Changed

- Refresh the complete public LiteLLM model-price table at most once per day,
  cache only validated pricing locally, and keep every ccusage log scan in
  offline mode with the signed embedded snapshot as fallback.
- Clarify that price refreshes contain no credentials or usage-derived fields,
  while ordinary connection metadata may be visible to GitHub.

## 1.1.9 — 2026-07-26

### Added

- Added clickable provider service-status details with a clear explanation,
  affected components, freshness, and a direct link to the official status
  page.
- Added complete service-status explanations in every fully localized language.

### Changed

- Show provider health once beside the provider instead of repeating the same
  badge on every quota window.
- Refreshed the website with current English and Chinese iPhone and Home Screen
  widget captures, including an explicit demo-data disclosure.

## 1.1.8 — 2026-07-26

### Added

- Added ccusage price-coverage reporting and a privacy-preserving freshness
  check against the official npm package metadata.
- Added language-specific English and Chinese product screenshots to the
  website and repository documentation.

### Changed

- Serialized Mac CloudKit snapshot publishing, advanced sequence numbers past
  the authenticated remote value, and retried one stale-record conflict after
  refetching the server record.
- Refined the curated AI feed source set and accepted original quote posts while
  continuing to reject replies, retweets, and nullcasts.

### Fixed

- Prevented incomplete model pricing from being shown as a misleading zero-cost
  total.
- Removed stale stable app copies after a verified Sparkle replacement and kept
  generated release app bundles out of LaunchServices discovery.

## 1.1.7 — 2026-07-26

### Added

- Added a local percentage-based quota consumption trend for every connected
  provider with an available primary quota window.
- Added official Claude Code and Codex service-health checks to quota cards,
  with menu-bar alerts shown only when a provider is degraded or unavailable.
- Bundled authentic provider artwork with documented upstream provenance.

### Changed

- Removed the misleading add-series control from the ccusage trend legend;
  tracked applications now determine which available series are displayed.

## 1.1.6 — 2026-07-25

### Added

- Added a quiet sidebar update reminder that appears only when Sparkle finds a
  newer signed release and opens the verified install flow on demand.
- Added continuous local detection for supported coding tools installed after
  onboarding, with an explicit prompt before tracking begins.

### Changed

- Expanded installed-tool discovery across app bundles, executable search
  paths, local data directories, and editor extensions.
- Show enabled API key and Cookie sources in Data Sources before their first
  successful connection so credentials can be entered immediately.

### Fixed

- Restored the missing first-use credential entry point for Z.ai, OpenRouter,
  and other manually configured providers.
- Prevented background installation scans from polling manual credentials or
  triggering Keychain interaction.

## 1.1.5 — 2026-07-25

### Added

- Added full, compact, and minimal menu bar display modes with live previews.
- Expanded local usage history to every supported agent returned by the bundled
  collector instead of limiting the trend to Claude and Codex.
- Added actionable loading, empty, failure, and retry states for local usage
  diagnostics.

### Changed

- Refresh local usage history every minute and whenever a relevant usage
  surface is presented.
- Preserve the menu bar item's position while applying display-mode changes
  immediately.

### Fixed

- Show zero for unavailable today, yesterday, and 30-day totals instead of
  dropping the values.
- Keep sparse and all-zero 30-day trends stable, with zero-height days rendered
  as a visible baseline instead of a missing chart or oversized bar.
- Merge today's live totals into the final 30-day slot without duplicating or
  losing prior history.
- Surface bounded collector timeout and invalid-output failures without
  blocking official quota refreshes.

## 1.1.4 — 2026-07-25

### Added

- Expanded the product website with a clearer AI Feed, privacy, and provider
  story.
- Added a secondary sync-details screen so advanced diagnostics remain
  available without crowding the main settings page.

### Changed

- Ranked popular AI Feed posts consistently across Mac and broadcast delivery.
- Made quota reset labels use weeks, days, or an `HH:mm:ss` countdown according
  to the remaining interval.
- Updated installer artwork to match the current TokenRemain brand.

### Fixed

- Prevented background provider refreshes from prompting for Keychain access.
- Fixed stale Mac snapshot timestamps.
- Added clearer sync security diagnostics while retaining the last known-good
  snapshot after a failed validation.

## 1.1.3 — 2026-07-24

### Added

- Bundled the official native arm64 ccusage 20.0.18 helper so a new Mac no
  longer needs Node or npm for local usage history.
- Added a branded drag-to-Applications DMG window.

### Changed

- Collected today's totals and 30-day history in one offline ccusage pass.
- Added release checks for the bundled helper's version, architecture, hash,
  and signature.

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
[1.1.3]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.3
[1.1.4]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.4
[1.1.5]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.5
[1.1.6]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.6
[1.1.7]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.7
[1.1.8]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.8
[1.1.9]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.9
[1.1.10]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.10
[1.1.11]: https://github.com/Carstin520/token-remain/releases/tag/v1.1.11
[1.2.0]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.0
