# Changelog

All notable product changes are recorded here. TokenRemain uses Semantic
Versioning for public releases.

## 1.2.11 — 2026-08-07

### Added

- Discover the running Qoder desktop session through its read-only local IPC
  service, with the existing manually supplied cookie retained as a fallback.
- Discover fresh Kimi Code CLI credentials and ZCode Start/Coding Plan
  credentials from their app-owned local files without refreshing or writing
  those credentials.

### Fixed

- Keep Qoder international and China sessions pinned to their matching origin,
  avoiding the stale-cookie request path that could return HTTP 401.
- Send Kimi CLI tokens only to the official Kimi Code usage endpoint, and bind
  each ZCode credential to its own plan contract and Z.ai/BigModel jurisdiction.
- Align Codex reset-card availability and expiry presentation with the official
  response instead of inferring usable credit from incomplete fields.

## 1.2.10 — 2026-08-06

### Added

- Detect third-party API routing used by Claude Code, Codex, and OpenCode while
  keeping each coding app as the card identity and naming the API that owns the
  displayed balance or limit.

### Fixed

- Fetch quota from the routed provider instead of falling back to the host
  application's official subscription or local snapshots, and isolate cached
  history when the active billing route changes.
- Carry the routed API name, icon, and accent through quota cards, Overview,
  risk and trend surfaces, menu-bar summaries, tooltips, accessibility labels,
  and privacy-filtered device sync.

## 1.2.9 — 2026-08-06

### Added

- Add a persistent quota-summary preference: default to the shortest
  account-wide window, or optionally show the account-wide window with the
  least remaining quota across the menu bar, Dock, and Dashboard summaries.

### Fixed

- Keep Claude account-wide quota summaries consistent across the Dashboard,
  Dock icon, menu bar, tooltip, risk level, and synced mobile snapshot instead
  of allowing the tighter Fable model quota to impersonate the general limit.
- Deduplicate repeated scoped quota readings case-insensitively while retaining
  the newest reading, preventing terminal repaint rows from producing duplicate
  Fable entries on Mac, iPhone, Apple Watch, and widgets.

## 1.2.8 — 2026-08-06

### Added

- Add single-account GLM Team quota monitoring and configurable third-party
  balance adapters for New API account tokens, API tokens, and field-mapped
  HTTPS balance endpoints.
- Add optional Antigravity third-party 5-hour and weekly pools, model-scoped
  MiniMax quota rows, and an OpenCode Go monthly spending window.
- Add pinned-day model breakdowns to Dashboard Trends with token/cost modes,
  input/output/cache detail, unpriced-model markers, and a bounded Other tail.

### Changed

- Expand Z.ai with explicit Global/China endpoint selection, multiple token
  windows, and a separate MCP monthly pool without cross-region credential
  retries.
- Preserve OpenRouter key limits, prepaid credits, account balance, plan name,
  and official daily/weekly/monthly/all-time spend in one snapshot.
- Combine active MiMo Token Plan usage with wallet balance while forwarding
  only the required cookie fields and refusing credential-bearing redirects.
- Keep scoped model pools out of the global risk, pace, quota-history, Dock,
  and primary menu-bar summary calculations; Spark weekly display remains
  optional while its 5-hour pool is ignored.
- Keep model-level ccusage history local to the Mac and publish only aggregate
  mobile history through the explicit mobile provider allowlist.

### Fixed

- Keep depleted and zero-value monetary balances visible instead of treating
  them as missing data, and avoid duplicate lifetime OpenRouter windows.
- Decode older usage-history caches without model detail and bound new model
  history so it cannot grow without limit.

## 1.2.7 — 2026-08-04

### Changed

- Keep AI Feed recommendations timely with priority-specific freshness windows,
  a higher relevance threshold, and balanced engagement, relevance, and recency
  scoring.
- Classify quota changes and major AI releases using paired meaning instead of
  broad single-word matches, reducing false priority labels on ordinary posts.
- Show Codex reset cards as usable, not yet usable, or empty while preserving
  the official banked balance and accurately explaining the expiry-data limit.

### Fixed

- Prevent three- or four-day-old AI Feed items from remaining in Dashboard top
  stories after the server or local cache has fresher recommendations.
- Require daily AI Feed digests to have an item from the last 24 hours instead
  of notifying from a two-week-old feed history.

## 1.2.6 — 2026-08-02

### Added

- Show Codex banked reset credits when the official usage endpoint provides
  them, while preserving compatibility with older cached quota snapshots.
- Add a Dashboard setting that can show or hide TokenRemain in the Dock and
  app switcher without removing its persistent menu-bar entry.
- Organize Dashboard settings into General, Menu Bar, Refresh & Sync, and About
  categories so related controls remain one click away.

### Changed

- Unify the desktop palette around neutral glass surfaces while retaining each
  provider's assigned identity color and conventional status colors.
- Use a monochrome TokenRemain wordmark in the compact popover, semantic AI
  Feed dots for quota and major-update stories, and a denser non-scrolling risk
  card in Dashboard Overview.
- Refine quota, usage-cost, Trending, and AI Feed cards for clearer hierarchy,
  calmer contrast, and more consistent fixed-size layouts.

### Fixed

- Cancel an active direct-reorder sequence when the app or window is
  interrupted, preventing a lost mouse-up from leaving later drags frozen.
- Render provider menu-bar attachments without force-casting copied images,
  avoiding a possible status refresh crash with unexpected image subclasses.

## 1.2.5 — 2026-08-01

### Added

- Let users independently show Claude Fable and GPT-5.3-Codex-Spark weekly
  windows inside their corresponding menu-bar quota cards.
- Add hover and selection details to the Overview usage-cost ring so each
  provider reveals its token volume and API list-price estimate.

### Changed

- Give Dashboard quota cards a consistent size, fixed provider header, aligned
  first quota row, and internal scrolling when a provider has extra windows.
- Align and fill the Overview card grid, keep both default Trending stories
  directly visible, and keep the usage-cost ring fully inside its card.
- Place a concise one-line sign-in recovery notice beside the provider name.
- Expand the Chinese and English README with current screenshots, measured
  power-efficiency context, provider details, and privacy boundaries.

### Fixed

- Preserve a still-active Fable weekly window when an ordinary Claude refresh
  returns only the general quota windows, and immediately retry the scoped
  probe when Fable display is enabled.
- Keep model-specific settings scoped to the menu-bar cards they describe
  instead of changing the Dashboard quota rows.

## 1.2.4 — 2026-08-01

### Changed

- Make menu-bar widgets and Dashboard Limits cards use one trackpad-friendly
  selection stage: a short hold tolerates natural pointer drift, then the full
  rendered component follows continuously from the original grab point.

### Fixed

- Allow the same component to be dragged repeatedly without requiring a second
  press or leaving the reorder gesture unable to rearm.
- Keep drag pointer samples in a fixed window coordinate space so rendering the
  component's offset cannot feed back into the next sample and cause jitter.
- Remove flashing, scaling, lift, and system-preview feedback while preserving
  drop-time ordering and persistence.

## 1.2.3 — 2026-08-01

### Changed

- Keep Codex and Claude quota refreshes at minute-level while a local session
  is active or a primary surface is genuinely visible, then fall back to at
  least five minutes when both are idle. Apple devices still receive periodic
  Mac snapshots without forcing a permanently hot one-minute loop.
- Track local session activity with filesystem events, so steady-state checks
  are timestamp reads rather than repeated recursive directory scans.
- Parse only new or rewritten Codex session logs after the initial metadata
  baseline, while preserving large filesystem-clock rollback correctness.

### Fixed

- Pause the Dashboard robot animation whenever its window is closed,
  minimized, or fully occluded, while preserving the same animation whenever
  the user can see it.
- Preserve the user's selected refresh cadence for enabled non-Codex/Claude
  providers even while local AI sessions and primary surfaces are idle.
- Catch up due quota data as soon as the popover, Dashboard, or floating widget
  becomes visible, without forcing requests when the current snapshot is fresh.
- Begin monitoring Codex or Claude session directories created after TokenRemain
  launched, without requiring an app restart or a broad home-directory watcher.

### Performance

- In a hidden-Dashboard, active-Codex-session measurement on an Apple M5 Pro,
  process CPU fell from about 9.65% to 0.45%, attributed average power from
  31.6 mW to 7.34 mW, and interrupt wakeups from 64.0/s to 2.8/s. See
  `docs/performance-v1.2.3.md` for the method and comparison boundaries.

## 1.2.2 — 2026-07-31

### Added

- Added Claude Fable quota usage and GPT-5.3-Codex-Spark quota windows to the
  detailed quota experience and encrypted Apple-device snapshot.
- Added direct long-press card reordering with live displacement and dedicated
  drag regions that leave lock, pin, and expand controls clickable.
- Added Dashboard visibility controls for Fable and GPT-5.3-Codex-Spark; both
  model-specific rows start hidden until the user enables them.

### Changed

- Keep Fable out of the compact menu-bar summary while retaining it inside the
  Claude quota card when enabled.

### Fixed

- Prevent drag activation from covering card controls or entering a flashing,
  non-selectable state when the pointer presses the top of a component.

## 1.2.1 — 2026-07-29

### Changed

- Build signed Universal Mac distributions with Swift's optimized Release
  configuration, reducing download size while preserving both Apple Silicon
  and Intel support.

### Fixed

- Keep the important-reminder group focused on the seven highest-ranked items,
  allow direct quota/reset events to expand the group when needed, and enforce
  an absolute maximum of ten reminders.

## 1.2.0 — 2026-07-29

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
- Replace Sparkle's cached automatic-download cycle with adaptive signed-feed
  probes: four checks per day when current, two while an update reminder is
  pending, bounded retry backoff after failures, and a fresh latest-version
  check immediately before the user starts an update.

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
[1.2.1]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.1
[1.2.2]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.2
[1.2.3]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.3
[1.2.4]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.4
[1.2.5]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.5
[1.2.6]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.6
[1.2.7]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.7
[1.2.8]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.8
[1.2.9]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.9
[1.2.10]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.10
[1.2.11]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.11
