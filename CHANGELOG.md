# Changelog

All notable product changes are recorded here. TokenRemain uses Semantic
Versioning for public releases.

## Unreleased

### Fixed

- Grok's menu-bar mark no longer sits flush against the remaining-percent
  text. The Lobe glyph is a diagonal that fills the PNG canvas; the status
  item now rasterizes a padded 13pt attachment instead of handing the 640px
  bitmap to `NSTextAttachmentCell`.

## 1.3.8 — 2026-08-29

### Added

- Add the Mac side of encrypted Direct Sync pairing for the Windows companion.
  A one-time code establishes a device key on the local network, quota
  snapshots remain application-layer encrypted, and daily usage history is
  shared only when explicitly enabled.

### Fixed

- Pasted provider credentials (including DeepSeek) no longer appear missing
  when an older development build owns the Keychain ACL. TokenRemain now
  distinguishes authorization from absence, validates a replacement before
  rebuilding the app-owned item, verifies the repaired value, and isolates
  development Keychain services from production so the collision cannot recur.
- Claude sessions can renew when TokenRemain starts from the macOS GUI and the
  network requires a system proxy. The quota probe now projects the system
  proxy into the CLI environment and reconstructs Claude Code's incremental
  terminal repaint before parsing its usage screen.
- A single-window quota card can grow to fit Codex reset-credit controls instead
  of clipping them behind a fixed slot or showing a needless scroll bar (#44).

## 1.3.7 — 2026-08-25

### Changed

- Show Cursor's two usage pools as separate bars, matching Cursor's own
  dashboard. The blended `totalPercentUsed` hid the real bottleneck: a
  spend-weighted 13% could mask "Other Models" at 91% used. The busier pool
  now drives the primary bar (and the menu-bar summary), while the other
  pool renders as a named "Cursor Models" / "Other Models" row alongside it.
  Accounts whose response lacks the per-pool fields keep the single bar.
- Apply the same busier-pool-first convention everywhere an upstream splits
  one billing cycle into pools: Copilot's free-tier Chat/Completions
  counters, Qoder's Personal/Shared credits (previously summed together, so
  an exhausted personal pool could read as "91% left"), and Z.ai ZCode's
  per-model pools (now named by model, with cycle length derived from the
  real period end).
- Stop dropping quota dimensions that lost a slot race: Kimi keeps every
  window the API reports (shortest → longest, middle tiers as named rows),
  Ollama shows Session, Hourly, and Weekly instead of whichever two rendered
  first, Codex model pools keep both their 5-hour and weekly windows, MiMo
  surfaces its daily token pool, and Z.ai time-based limits use their real
  duration and name instead of a hardcoded "MCP · 30 d".
- Named pool rows (Fable, Codex-Spark, Antigravity third-party, MiMo daily,
  Ollama hourly, DeepSeek extra currencies, OpenRouter credits) now share
  one visibility store with a smart default: a pool the account actually
  uses shows up on its own; an idle one stays hidden until switched on.
  Existing Fable/Spark/third-party choices migrate as-is.
- OpenRouter prepaid credits keep their percentage bar even when the API key
  has no periodic limit, and Copilot paid plans estimate overage spend
  ($0.04 per extra premium request) in the extra-usage row.

### Added

- A "Background depth" slider in Settings → General → Appearance (#42).
  It lifts the deep-black surfaces toward a soft cool grey across the
  Dashboard, the menu-bar widgets, and the desktop float together — text,
  provider identity colors, and status colors are unchanged, and the range
  is capped where secondary text still meets WCAG AA. The default keeps
  today's look; the popup's glass opacity remains its own separate control.

### Fixed

- Quota cards no longer show a scroll bar next to trailing blank space
  when their content already fits the fixed card slot (#42) — scrolling
  now engages only when the measured content actually overflows, so a
  future extra window row re-enables it automatically.
- Clicking a bar in the Daily Usage Trend now opens that day's model
  detail instead of always the most recent day's (#42). Every bar's tap
  target was silently inflated to the whole chart — the hit shape was
  declared after `.position`, which wraps the bar in a chart-sized frame —
  so the topmost (latest) column swallowed every click while the hover
  tooltip, computed from the pointer location, kept looking correct.
- Qoder now trusts a saved dashboard cookie over the auto-discovered
  local session, and computes usage from the concrete used/total counters
  instead of the IPC's `totalUsagePercentage` (#18). On paid accounts the
  local `credit/usage` probe reports a different pool than the Credits
  dashboard (a real account read 99.9% remaining while the dashboard
  showed 89.9%), so the pasted cookie — which matches the billing page —
  wins whenever present, with the local probe kept as the no-cookie
  fallback. An account-routed cookie still never substitutes the local
  reading on failure.
- A Copilot free plan or a multi-pool Z.ai ZCode plan no longer breaks
  mobile sync for every provider: same-length sibling pools now travel as
  named rows instead of two identical account windows, which the sync
  schema rejects wholesale.
- MiMo's empty pay-as-you-go wallet no longer pins the menu bar at "0%
  remaining" under the lowest-remaining strategy; the wallet is shown as a
  balance line instead of a second quota window.
- Volcengine no longer picks a random usage percentage when the response
  holds several: the parser prefers the documented path and traverses
  deterministically.
- Claude's terminal-based fallback no longer lets a model-scoped
  "Current session (…)" line overwrite the account-wide 5-hour reading.
- Antigravity third-party rows no longer vanish for a refresh cycle when
  only the Gemini buckets report.

## 1.3.6 — 2026-08-21

### Changed

- Cut the download from 19.7 MB to 11.8 MB and the installed app from 40 MB
  to 23 MB. The release executable is now stripped (its debug symbols were
  larger than its code; the DWARF is archived beside each release so crash
  reports still symbolicate), the mascot artwork ships at the 256px its
  largest consumer actually draws (which also quarters its decoded memory),
  the SVG icon regeneration sources stay in the repository instead of the
  bundle, and the DMG is LZMA-compressed. The build now fails on any
  regression of these, because a size regression is invisible in QA.
- Keep the release pipeline on the verified bundled ccusage when the
  official package publishes a defective build, instead of failing the
  release: upstream 20.0.19 remains bundled while 20.0.20 is rejected for
  shipping without its license file.

### Fixed

- Stop the Claude quota card from inventing reset times. A repaint-damaged
  `/usage` readout could turn "Aug 14 at 3pm" into a bare "Aug 14", which
  read as already past and rolled the reset a full year forward; a reset is
  now rejected unless it carries a complete time and fits the window it was
  read from.
- Make "Always Allow" stick for Claude credential reads. The Claude Code
  keychain item's own protections rejected every silent read no matter how
  often access was granted; TokenRemain now delegates the read to the one
  tool the item already trusts, and only after metadata that cannot raise a
  dialog proves it safe.
- Report a signed-out Claude account as exactly that, immediately — once
  per sign-out with a daily reminder while it lasts — instead of blaming a
  timeout after thirty seconds of probing a login screen.
- Answer the Claude CLI's "Do you trust this folder?" prompt during quota
  probes. The probe used to type `/usage` into the dialog itself, so first
  runs in a new folder silently fell back to stale snapshots until the
  timeout.
- Tell a running Antigravity with no quota data apart from a missing one.
  Both cases used to claim "not logged in; install Antigravity"; now a
  running app is asked to update, and an absent one to be opened, since the
  local quota service needs a running app rather than credentials.

## 1.3.5 — 2026-08-13

### Added

- Guide users through adding isolated Codex and Claude accounts with CLI
  readiness checks, official installation help, and explicit browser sign-in.
- Add reusable credential setup and update guidance for Keychain-managed
  provider accounts, including short-lived Antigravity credentials.
- Add a setting for whether the menu-bar popup shows Claude's Fable weekly
  quota. It is on by default, because Fable often runs out well before the
  all-models cap does.

### Fixed

- Fix the crash that made TokenRemain quit a few seconds after launch on
  macOS 26, with no user interaction, on 1.3.0 through 1.3.4. Background
  refresh checked whether the menu-bar popup was visible, which built the
  hidden popup window; that window then resized itself during its own layout
  pass until the main thread ran out of stack. Both glass styles were
  affected, because the material was never the cause.
- Add an escape hatch for future glass problems: writing
  `tokenRemain.forceLegacyPopover.v1` returns the menu-bar popup to the
  pre-macOS 26 presentation without downgrading the app.
- Read Claude's Fable weekly quota again. Anthropic moved it into a new field
  in the usage response, so TokenRemain had stopped seeing it and kept showing
  the last value it had.
- Stop showing a second, wrong Fable row. A reading captured by an older
  version could survive every refresh and appear as `100% remaining` next to
  the real quota; it is now discarded on sight, with no need to reinstall.
- Discover Codex and Claude CLIs installed through NVM and other common Node
  version managers when TokenRemain starts from the macOS GUI environment.
- Keep the default provider account available when an optional CLI is missing,
  and validate replacement credentials before changing the saved Keychain item.

## 1.3.4 — 2026-08-12

### Changed

- Move popup appearance controls into an inline editor inside the live menu-bar
  popup, so Clear/Frosted glass and backdrop opacity can be judged against the
  content and desktop they affect.
- Keep launch-at-login, Dashboard settings, restart and quit actions directly
  reachable from the popup while removing the duplicate appearance card from
  Dashboard settings.

### Fixed

- Present the inline settings editor as a stable overlay outside the live
  Liquid Glass container, avoiding the macOS 26 recursive glass-transition
  crash while the popup is open.

## 1.3.3 — 2026-08-12

### Changed

- Rebuild the macOS 26 menu-bar popup as one continuous Clear/Frosted Liquid
  Glass silhouette, with a rounded beak, a readable opacity-controlled scrim,
  and visible pointer feedback on popup cards.

### Fixed

- Keep the transparent popup interactive at every opacity so clicks and hover
  states no longer pass through to the desktop or dismiss the popup.
- Preserve the selected Clear or Frosted appearance when the popup is opened
  from the real menu-bar item instead of a visual-test launch path.
- Separate material choice from backdrop opacity so Frosted remains visibly
  diffused and Clear remains crisply refractive across the slider range.

## 1.3.2 — 2026-08-11

### Changed

- Refine the macOS 26 popup into one coherent Liquid Glass object with a
  restrained top-lit rim, compact interactive footer controls, and matching
  Clear/Frosted header controls instead of heavy decorative outlines.

### Fixed

- Keep Clear and Frosted visually distinct in both the menu-bar popup and
  floating desktop widget, including at zero backdrop opacity, without turning
  transparent cards into near-black surfaces.
- Restore the popup's menu-bar beak, keep it centered under TokenRemain's own
  status-item metrics, and constrain the custom transparent panel to the active
  screen.

## 1.3.1 — 2026-08-11

### Added

- Extend the account switcher and currency-safe summaries from Claude to Codex,
  Antigravity, Cursor, Grok, Copilot, Z.ai/GLM, Windsurf, Devin, OpenRouter,
  DeepSeek, Kimi, MiniMax, MiMo, Qoder, Volcengine, Ollama, and configurable
  third-party APIs. CLI accounts use isolated homes; pasted credentials remain
  in per-account, device-only Keychain items.

### Fixed

- Recognize Codex Desktop's `openai_http` and `chatgpt_http` providers as the
  official ChatGPT quota route when they require OpenAI authentication and use
  an official or unset Base URL.
- Keep explicit Claude API credentials and custom OpenCode Go Base URLs out of
  their host application's official subscription quota path.
- Prevent managed Claude and Codex account processes from inheriting global API
  keys, Base URLs, or cloud routing overrides from the system account.

## 1.3.0 — 2026-08-10

### Added

- Add isolated Claude account profiles with official CLI sign-in, per-account
  refresh, account selection, rename, pause, removal, and currency-safe summary
  balances without copying credentials into TokenRemain storage.
- Let users choose frosted or clear Liquid Glass for the menu-bar popup and
  independently adjust its backdrop opacity.

### Changed

- Keep popup primary, secondary, and muted text on protected light foregrounds
  for both glass styles, while preserving provider and semantic colors.

### Fixed

- Isolate malformed repaint-damaged model quota rows so one optional scoped
  limit cannot reject an otherwise valid encrypted mobile snapshot.
- Keep managed Claude profiles from falling through to the active system
  account's configuration or Keychain credentials.

## 1.2.11 — 2026-08-07

### Added

- Discover the running Qoder desktop session through its read-only local IPC
  service, with the existing manually supplied cookie retained as a fallback.
- Discover fresh Kimi Code CLI credentials and ZCode Start/Coding Plan
  credentials from their app-owned local files without refreshing or writing
  those credentials.

### Fixed

- Stop the Claude weekly "all models" row from reappearing as one or two extra
  model cards when the `/usage` terminal capture drops glyphs from its label,
  and drop such rows from snapshots cached by an earlier build.
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
[1.2.11]: https://github.com/Carstin520/token-remain/releases/tag/v1.2.11%2Bbuild.26
[1.3.0]: https://github.com/Carstin520/token-remain/releases/tag/v1.3.0
[1.3.1]: https://github.com/Carstin520/token-remain/releases/tag/v1.3.1
[1.3.7]: https://github.com/Carstin520/token-remain/releases/tag/v1.3.7
[1.3.8]: https://github.com/Carstin520/token-remain/releases/tag/v1.3.8
