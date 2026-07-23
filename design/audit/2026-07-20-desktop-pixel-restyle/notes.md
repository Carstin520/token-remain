# Desktop pixel restyle — 2026-07-20

Restyled the TokenRemain macOS popover and Dashboard to the confirmed mobile
pixel-tech, low-contrast, three-color robot design system
(`design/mobile/token-remain-apple-system-concept-2026-07-20.png`,
`apple/FABLE-FUNCTIONAL-SPEC.md` §3). Visual/theme only — no data logic, refresh
behavior, or copy semantics changed. zh-Hans copy preserved.

## Screenshots
- `popover-pixel.png` — menu-bar popover preview (`--open-popover`).
- `dashboard-pixel.png` — Dashboard Overview (`--open-dashboard`).

## Typography (synced to FABLE-FUNCTIONAL-SPEC §3.2)
- New token layer `Views/Theme/Typography.swift`: `DashboardTheme.Typo`
  (`mono`/`text`/`badge`/`wordmark` font factories) plus `View.numericFont(_:_:)`
  (SF Mono face + tabular digits) and `View.wordmarkFont(_:_:)`. Existing pt
  sizes/weights are preserved — this is a font-face sync, not a size redesign.
- Rule: body/labels stay system SF; **every numeral** (%, token counts, costs,
  countdowns, clock/relative times) renders SF Mono via `.numericFont`. SF Mono
  has no CJK, so mixed lines (e.g. `剩余 75%`, `更新于 14:56`) render digits in
  SF Mono while Chinese falls back to the system CJK face — this is the intended
  "mixed lines are fine" behavior.
- Hero values (metric-card heroes, popover/quota `剩余 XX%`, official-quota %,
  risk-strip constraining value, ring center) = monospaced semibold/bold.
- Brand wordmark "TokenRemain" (popover header + sidebar lockup) = SF Mono.
- Menu-bar status item upgraded from `monospacedDigitSystemFont` to
  `monospacedSystemFont` (SF Mono) — its text is pure percentages, so safe.
- Swept: QuotaCard, RiskStrip, MetricCard, RingChart, OverviewSection,
  UsageCostCompositionCard, LocalUsageCard, PopoverQuotaWidget,
  AIFeedPostCard/HotStoriesCard, TrendingStoriesCard, DashboardComponents
  (InfoRow value + SectionTitleHeader trailing), DataSourcesSection,
  UsageMenuView, DashboardView, StatusBarController. Every prior ad-hoc
  `.monospacedDigit()` now routes through `.numericFont`.
- Layout: monospaced digits are wider, but all values fit — the fixed-width
  popover `剩余 XX%` rows and the dashboard metric heroes/countdowns
  (`重置还有 02:13:04`) do not truncate or wrap (verified in the recaptures).

Captured with `screencapture -l <windowID>` against the running installed app
(window IDs resolved via CGWindowList). This run is on macOS 26, so the glass
surface path is exercised; the pixel tick ornament + new accent/text tokens are
layered on top of the system glass without opaque fills.

## Palette (DashboardTheme → mobile TRTheme)
- Surfaces: canvas #070B12, surface #0D1420, surface2 #141D2C, surface3 #1B2536,
  border #223044, track #1B2536.
- Text: #E9EDF5 / secondary #8B97AB / muted #55617A.
- Violet #8F7BF2 (dim #5B4FB0) = Claude, primary accent, LOW. Cyan #3ECFE0
  (dim #2B8FA0) = Codex, countdowns, on-track/confirmations. Link = cyan.
- Provider identity intentionally changed: Claude = violet, Codex = cyan
  (replaces old orange/blue). Gradient fills (`claudeFill`/`codexFill`) removed.
- Color roles are split: **brand identity/accents = violet + cyan** (providers,
  links, selection, meta badges, segment bars, pixel chrome); **semantic status
  = conventional green / amber / red** so a warning looks like a warning. Status
  is always paired with a glyph + text label, never color alone. `RiskLevel`
  threshold logic untouched; its `tint` delegates to `DashboardTheme.riskAccent`.
  - success #57D19A (green) = on-track / LOW; warning #FFB554 (amber) = MEDIUM /
    早于重置 / 用量超前; danger #FF6B6B (red) = HIGH (filled white-on-red badge) /
    projected run-out warning glyph.
  - `riskAccent(for:)`: .low → green, .medium → amber, .high → red,
    .unknown → secondaryText. Risk `PixelBadge`s follow `riskAccent` (filled for
    HIGH), so 中/MEDIUM = amber outline, HIGH = filled red badge.
  - Filled `PixelBadge` chips print **ink** text (`canvas` #070B12) on the
    status field, not white: white on red #FF6B6B measures only ~2.8:1 and fails
    the 3:1 component threshold, whereas ink is ≈7:1. (White remains reserved for
    violet fields, e.g. the sidebar selection capsule.)

## New components (Sources/UsageDock/Views/Components/)
- `SegmentBar.swift` — 14 rounded segments (10 for narrow contexts), flat accent
  fill over track. Replaces all `UsageProgressBar` gradient bars.
- `PixelCard.swift` — `PixelTickOverlay` Canvas drawing 4 corner L-ticks + a 2×2
  dot cluster (accessibilityHidden), a `.pixelTicks(cornerRadius:)` modifier, and
  a flat `PixelCard` fallback surface.
- `PixelBadge.swift` — uppercase monospaced chip in a 1px-bordered surface;
  `filled` variant = white-on-violet for HIGH risk. `TagPill` now delegates here.
- `DottedSparkline.swift` — cyan dot-per-sample Canvas sparkline (see deviation).

## Files changed
- `Views/Theme/DashboardTheme.swift` — full palette swap + `accent(for:)` (flat)
  and `riskAccent(for:)`; removed `claudeFill`/`codexFill`/`fill(for:)`.
- `Support/RiskLevel.swift` — `tint` delegates to `DashboardTheme.riskAccent`.
- `Views/Components/DashboardCard.swift` — `.pixelTicks` on the card chrome;
  `TagPill` → `PixelBadge`.
- `Views/Components/RiskStrip.swift` — pixel risk badge, readable `text` headline,
  tick chrome.
- `Views/Components/AIFeedPostCard.swift` — tick chrome.
- `Views/QuotaCard.swift`, `Views/Dashboard/OverviewSection.swift` — SegmentBar +
  pixel risk badges (filled for HIGH).
- `Views/Dashboard/DashboardView.swift` — sidebar/app tint → violet, and the
  sidebar nav rebuilt as a custom `ScrollView` list with an explicit violet
  (#8F7BF2) selection capsule + white label/icon. `.tint` alone does NOT recolor
  the macOS `NSTableView`/`List(selection:)` highlight (it follows the system
  accent → rendered system-blue), so the selection is now drawn manually.
- `Views/Dashboard/SettingsSection.swift`, `Views/Dashboard/AIFeedSection.swift`
  — the two `.tint(DashboardTheme.codex)` switch toggles realigned to
  `DashboardTheme.violet` (primary accent).
- `Views/Dashboard/TrendingStoriesCard.swift` — rank accents remapped to
  cyan (#1) / violet (#2), off-brand ember removed.
- Deleted `Views/Components/UsageProgressBar.swift`.

## Tests
- `Tests/UsageDockTests/ThemeContrastTests.swift` (new) — WCAG AA (≥4.5:1) for
  (text, surface), (secondaryText, surface) and the two brand accents; plus a
  ≥3:1 UI-component-contrast check for the semantic status colors (success /
  warning / danger) on surface (they are badge/glyph components paired with
  labels, not body text); plus an ink-on-filled-field check (canvas on danger
  and on warning ≥4.5:1) covering the filled HIGH badge text.
- Full suite: 45 tests pass (40 prior + 5 new) via the Xcode toolchain.

## Deviations from spec
- `DottedSparkline` is created and available but not wired into the desktop
  Trends section: desktop has no multi-day history (Trends shows an honest empty
  state today). Fabricating a 7-day curve would violate the app's data-honesty
  design, so the sparkline stays unused pending a real history source.
- Status glyphs remain SF Symbols (checkmark/exclamation) rather than ported
  pixel `☑`/`!`/`‼` glyphs — they already satisfy differentiate-without-color
  (glyph + text label always present) and avoid new glyph-rendering risk.
- The AI-feed priority badge keeps its icon+capsule form (colors remapped to the
  palette) rather than becoming a bordered `PixelBadge`.

## Verification
- `bash ./script/build_and_run.sh --verify` → exit 0 (app builds, installs,
  launches).
- `swift test` (Xcode toolchain) → 43 passing. Note: the default Command Line
  Tools toolchain lacks swift-testing; run with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

---

# Follow-up — provider slots + real Trends chart (2026-07-20)

Two additions on top of the restyle above. Task A is tokens-only (no UI change);
Task B replaces the Trends empty state with a real, ccusage-backed chart.

## Screenshot
- `trends-pixel.png` — Dashboard 趋势 tab, default 14-day Tokens view, stacked
  daily bars (real ccusage `daily --by-agent` history, 7/8–7/20). Captured via
  `screencapture -l <windowID>` against the running installed app, launched with
  the new `--open-section trends` dev flag.

## Task A — Provider color slots (reserved, no UI change)
- `Views/Theme/DashboardTheme.swift`: added `indigo #2F5FD0` (dim `#24479C`),
  `magenta #D95FB8` (dim `#A2478A`), `olive #7DA342` (dim `#5D7A31`), plus
  ordered arrays `providerSlots = [violet, cyan, indigo, magenta, olive]` and
  index-aligned `providerSlotsDim`. Doc comment states the load-bearing rules:
  next-free-slot-in-order assignment, color follows the entity permanently
  (never re-assigned on subset changes), semantic green/amber/red never used as
  a provider color, and provider color must always be paired with glyph + label.
  Values match `design/palette.md` §Provider Slots exactly; no existing values
  altered.

## Task B — Real daily usage trend chart
Data path (mirrors the existing ccusage integration in `CCUsageService`/`UsageStore`):
- `Models/UsageModels.swift`: new `DailyUsageHistory` (Codable) with per-day
  `Day` entries carrying the fixed Claude/Codex token+cost split.
- `Services/CCUsageService.swift`: new `fetchHistory(days:)` shelling out to
  `npx --yes ccusage@latest daily --json --by-agent --since <start>` (same
  invocation style as `fetch()`, widened `--since` window), plus a testable
  static `parseHistory(_:now:)` that keys the Claude/Codex split off the agent id
  (absent provider ⇒ 0, never fabricated) and returns days oldest-first.
- `Services/DailyHistoryCache.swift`: new best-effort on-disk cache
  (`daily-history-cache.json`), same pattern as `QuotaCache`, so the chart paints
  from cache on launch and survives a transient ccusage failure.
- `Stores/UsageStore.swift`: new `@Published history`; loaded from cache in
  `init`, refreshed alongside the existing `daily` fetch in the same
  `shouldRefreshCCUsage` block (same 5-min cadence). Kept the today `fetch()`
  untouched to avoid regressing Overview numbers.
- `Support/UsageInsights.swift`: added optional `history` (defaulted, so all
  existing call sites and tests compile unchanged); `DashboardView` passes
  `store.history` through.

Chart component (`Views/Dashboard/UsageTrendChart.swift`, new):
- `UsageTrendCard` owns the range/metric state; `UsageTrendChart` draws the plot;
  `BarColumn`, `TrendLegend`, `TrendTooltip`, `PixelSegmentedControl` are the
  supporting pieces.
- Stacked bars, fixed order Claude (violet, `providerSlots[0]`) at baseline /
  Codex (cyan, `providerSlots[1]`) above. Thin bars (12/10/7 pt by range), 2 pt
  top-only rounding on the stack's data-end (`UnevenRoundedRectangle`), 2 pt
  canvas gaps between segments and between bars, no zero-height artifacts.
- Toggles implemented: range 7 天 / 14 天 (default) / 30 天; metric Tokens /
  成本 — single y-axis, never dual. Both via `PixelSegmentedControl` (violet
  selected fill + ink text).
- Recessive axes: 4 faint border-token gridlines, y ticks textMute SF Mono via a
  new compact `compactAxisTokens` (e.g. `1.0B` / `750M`) and `$4.5`, x labels
  textDim SF Mono `M/d` thinned to every 2nd (14) / 5th (30). No vertical grid or
  axis lines. All text uses text tokens only — never series color.
- Required 2-series legend (glyph + name + color chip). Hover via
  `onContinuousHover` brightens the hovered bar (dims the others, matching the
  existing `RingChart` idiom) and shows a pixel-card tooltip (date, Claude,
  Codex, total; mono digits). Per-bar `accessibilityLabel`
  "M月d日 Claude X · Codex Y · 共 Z"; container `accessibilityElement(children:.contain)`.
- Never uses semantic green/amber/red. The built `DottedSparkline` is now wired
  in as a small neutral (textDim, non-series) total-trend line above the bars —
  resolves the prior "sparkline unused" deviation.
- `Views/Dashboard/TrendsSection.swift`: shows the card when ≥2 days of real
  history exist, otherwise keeps an honest "趋势数据按日累积中" empty state
  ("accumulates by day"). Roadmap trimmed of the two now-shipped items.

Copy: the stale `section.trends.subtitle` parenthetical "(collecting history)"
was trimmed to just "跨天使用趋势" / "Usage over time" across all 17 locales +
the `L10n.swift` fallback, since the section now shows real history.

Dev hook: `App/UsageDockApp.swift` gained `--open-section <rawValue>` (e.g.
`--open-section trends`) — a minimal generalization of the existing
`--open-dashboard` / `--open-popover` launch-preview flags, used to capture the
Trends tab deterministically.

## Tests
- `Tests/UsageDockTests/DailyUsageHistoryTests.swift` (new, 6 tests): per-day
  Claude/Codex split parsing + oldest-first ordering, absent-provider-is-zero,
  unparseable-period rows dropped, `niceCeiling`, `compactAxisTokens`, and
  month/day label helpers.
- Full suite: 51 tests pass (was 45) via the Xcode toolchain.

## Verification
- `bash ./script/build_and_run.sh --verify` → exit 0.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` → 51 pass.
- Real ccusage history exists on this machine (104 days, 2025-12-09 → 2026-07-20,
  both agents daily); the capture shows genuine data, nothing fabricated.

## Notes / deviations
- Hover tooltip is implemented and compiles but was not screenshot-verified: this
  environment mis-maps computer-use clicks/mouse-moves to the Dock, and any
  computer-use screenshot reactivates the app (firing `applicationShouldHandleReopen`
  → resets to Overview). The final capture was taken with `screencapture` only,
  no preceding computer-use screenshot.
- `今日快照` may briefly read "暂无今日本地用量" right after launch while the
  separate today `fetch()` is still resolving (sync spinner active); the chart
  itself is history-backed and fully populated independently.

---

# Follow-up 2 — logos, Codex Radar, copy & UX fixes (2026-07-20)

Five coordinator/user follow-ups. Screenshots recaptured: `dashboard-pixel.png`
(Overview: new logos + Codex radar badge + de-duplicated title),
`trends-pixel.png` (fixed subtitle), `popover-pixel.png` (Codex card radar badge
+ new logos). Captured via `screencapture -l <windowID>` against the running app.

## Fix — Trends subtitle copy
The earlier `trends-pixel.png` still showed "(正在采集历史数据)" because the
capture predated the rebuild. `section.trends.subtitle` is now
"跨天使用趋势 · 本地 ccusage" (and the "· local ccusage" equivalent) across all 17
locales + the `L10n.swift` fallback — it no longer claims history is still being
collected.

## Official provider logos (vector, no bitmaps)
`Views/BrandIcon.swift` rewritten to draw both marks as vectors (shared
`BrandGlyph` geometry so SwiftUI `Canvas` and the AppKit template `NSImage`
render identically), replacing the `claude.png` / `openai.png` template bitmaps:
- **Claude**: 12-blade starburst, tinted the official Anthropic coral
  `DashboardTheme.claudeBrand` (#D97757).
- **Codex**: a terminal-prompt mark (`>` chevron + baseline `_`), tinted
  `codexBrand` (#4B9CFB) — the OpenAI knot no longer appears anywhere.
- The glyph owns its official color (call-site `foregroundStyle` is ignored); the
  accent system is untouched — quota bars stay violet/cyan, selection stays
  violet. Verified in every render site: popover quota headers
  (`PopoverWidgetChrome`), popover cards, dashboard official-quota rows
  (`OverviewSection`), and the Trends legend.
- **Menu bar**: `BrandIcon.image(for:)` returns a template (monochrome) `NSImage`
  drawn from the same vector geometry — the Codex shape is swapped but stays
  monochrome for legibility (`flipped: true` keeps the underscore at the
  baseline). `StatusBarController` is unchanged; it still tints the template to
  the label color. Legible at 14–18pt (menu bar) and ~20pt (cards).
- `DashboardTheme`: added `claudeBrand` / `codexBrand` (glyph-tint only).

## Codex "24h 重置概率" — community data source
The app's only new outbound call. NO Claude equivalent added.
- `Services/CodexRadarService.swift`: GETs `https://codexradar.com/current.json`
  (schema 2.0), 10s timeout, `reloadIgnoringLocalCacheData`. Testable static
  `parse` maps `prediction.{probability_24h,probability_48h,updated_at}`,
  `window_open`, and `window.{status,title,opened_at,closed_at}`; throws
  `missingPrediction` when `probability_24h` is absent so the caller fails quiet.
  `CodexRadarPrediction` exposes `probability24hPercentText` and `isStale()`
  (>48h).
- `Services/CodexRadarCache.swift`: best-effort disk cache (last good payload +
  fetch timestamp), same pattern as `QuotaCache`.
- `Stores/UsageStore.swift`: `@Published codexRadar` + `codexRadarEnabled`
  (UserDefaults `codexRadarEnabled`, default ON). Refresh runs independently
  (spawned task, not blocked behind the ~30s Claude probe) on a 10-min cadence
  (`lastRadarRefresh`); **fail-quiet** — a network/parse failure keeps the last
  good cached value and never adds an error banner; the element hides only when
  there is no data at all or the source is disabled. Fires a local notification
  once per window-open transition (deduped on `window.opened_at` via
  `FeedNotificationService`'s new generic `notify(identifier:…)`; UserDefaults
  `codexRadarNotifiedOpenedAt`). Disabling makes no codexradar.com calls and
  clears `codexRadar`.
- `Views/Components/CodexRadarBadge.swift`: inline pixel element next to the
  Codex quota — "24h 重置概率 14%" (mono digits, cyan; textDim label), or a cyan
  "赠送重置窗口开放中" confirm line when `window_open`. Informational tones only,
  never semantic green/amber/red. `.help(...)` reveals the required attribution:
  "社区预测,非官方数据 · 预测的是厂商赠送/补偿性重置 · 数据来自 Codex 雷达
  codexradar.com · 更新于 <相对时间>", appending "(数据较旧)" when >48h. Wired
  into the popover Codex card (`PopoverQuotaWidget`, Codex only) and the dashboard
  Codex official-quota row (`OverviewSection`).
- `Views/Dashboard/DataSourcesSection.swift`: new Codex 雷达 row with attribution
  ("社区预测 · codexradar.com · 只读取公开 JSON,不上传任何数据"), the last-updated
  time, and the 启用 Codex 雷达 toggle (default ON, persisted). Privacy list now
  notes this is the only outbound request.
- `UsageInsights` gained `codexRadar` (defaulted) for the dashboard row.
- Runtime confirmed: codexradar.com reachable (HTTP 200); the app wrote
  `codex-radar-cache.json` and the badge renders "14%" with the "(数据较旧)"
  hover path active (the live `updated_at` is ~7 days old).

## Pin/collapse friction removed
Collapsing a pinned popover widget now collapses **and** auto-unpins in one
action — no blocking "先关闭锁定" prompt.
- `Stores/PopoverLayoutStore.swift`: `toggleExpanded` now collapses a pinned
  widget by releasing the pin (durable, `save()`) and collapsing.
- `Views/Popover/PopoverWidgetChrome.swift`: deleted the `showsPinnedCollapseHint`
  state, the warning `Label`, the variable-height frame, and the `onChange`;
  the expansion button/context-menu item call `onToggleExpanded` directly.
- `widget.locked_hint` / `widget.locked_accessibility` removed from all 17
  locales, `L10n.swift`, and the LocalizationTests `requiredKeys`.
- Pinning a collapsed widget still expands+pins (unchanged natural model).

## Dashboard title de-duplication
The window/toolbar showed "TokenRemain" a second time above the content.
- `Support/DashboardWindowController.swift`: `titleVisibility = .hidden` (kept
  `window.title = "TokenRemain"` for Mission Control / the window switcher /
  accessibility), re-asserted in `show()` after SwiftUI configures its toolbar.
- `Views/Dashboard/DashboardView.swift`: removed `.navigationTitle`; added a
  `HideToolbarTitle` modifier applying `.toolbar(removing: .title)` on macOS 15+
  (the user runs macOS 26), falling back to the hidden `titleVisibility` pre-15.
- Verified: the titlebar shows only the sidebar-toggle button (clean, no leftover
  spacing); the window's title property is still "TokenRemain" (CGWindowList
  name); the popover preview window title is unaffected.

## Tests
- `Tests/UsageDockTests/CodexRadarServiceTests.swift` (new, 6): full-payload
  parse, open-window opened_at capture, >48h staleness, missing-prediction /
  missing-probability / malformed-JSON all throw (the fail-quiet trigger).
- `Tests/UsageDockTests/PopoverLayoutStoreTests.swift`: added
  "Collapsing a pinned widget unpins it in one action" (durable across a fresh
  store).
- `Tests/UsageDockTests/LocalizationTests.swift`: dropped the two removed keys
  from `requiredKeys`.
- Full suite: 58 tests pass (was 51) via the Xcode toolchain.

## Verification
- `bash ./script/build_and_run.sh --verify` → exit 0.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` → 58 pass.

## Deviations / notes
- The Claude starburst is a faithful 12-blade geometric approximation of the
  Anthropic mark (drawn vector, no bitmap), not a pixel-exact trace of the
  official artwork.
- Pin/collapse: could not click-verify in-app (this environment mis-maps
  computer-use clicks to the Dock), but the warning path is provably gone
  (strings + UI + state removed) and the new behavior is unit-tested.
- Notifications are best-effort: if the user has not granted notification
  authorization the window-open alert silently no-ops (same as the feed path).

---

# Follow-up 3 — Codex Radar removed (2026-07-20)

User decision: the community "24h 重置概率" prediction (from Follow-up 2 above) is
not trustworthy enough to surface, so the entire Codex Radar integration was
deleted. The feature was **added then removed** — this section supersedes the
"Codex \"24h 重置概率\" — community data source" subsection above; the app makes
**no** outbound calls to codexradar.com anymore and there is no remaining
`radar` / `CodexRadar` reference anywhere in `Sources/` or `Tests/`.

## Deleted files
- `Sources/UsageDock/Services/CodexRadarService.swift` (fetch + parse + model).
- `Sources/UsageDock/Services/CodexRadarCache.swift` (disk cache).
- `Sources/UsageDock/Views/Components/CodexRadarBadge.swift` (inline badge).
- `Tests/UsageDockTests/CodexRadarServiceTests.swift` (the 6 radar tests).

## Wiring removed
- `Stores/UsageStore.swift`: dropped `@Published codexRadar` /
  `codexRadarEnabled`, the cache/service/notifier lets, both UserDefaults keys
  (`codexRadarEnabled`, `codexRadarNotifiedOpenedAt`), the `lastRadarRefresh`
  cadence field, the ~10-min `refreshCodexRadar` task, the window-open
  local-notification path (`notifyIfRadarWindowOpened`, deduped on
  `window.opened_at`), and the `setCodexRadarEnabled` toggle API.
- `Support/UsageInsights.swift`: removed the `codexRadar` stored property and
  init parameter.
- `Services/FeedNotificationService.swift`: removed the generic
  `notify(identifier:title:subtitle:body:url:)` method (its only caller was the
  radar window-open alert); the feed's `notify(post:)` path is untouched.

## UI removed
- `Views/Popover/PopoverQuotaWidget.swift`: dropped the `codexRadar` param and
  the badge under the Codex quota row.
- `Views/Dashboard/OverviewSection.swift`: dropped the `codexRadar` param on
  `OfficialQuotaRow` and the badge under the Codex official-quota row.
- `Views/Dashboard/DataSourcesSection.swift`: removed the entire `Codex 雷达`
  data-source row + `启用 Codex 雷达` toggle (`CodexRadarSourceRow` struct), and
  the codexradar.com privacy-copy line; the `store` dependency (only used by
  that row) was dropped from the view and its `DashboardView` call site.
- `Views/UsageMenuView.swift` / `Views/Dashboard/DashboardView.swift`: stopped
  passing `store.codexRadar` into `PopoverQuotaWidget` / `UsageInsights`.

## Localization
- No radar strings existed in the `.lproj` files or `L10n.swift` — the badge and
  row used inline zh-Hans literals, so there was nothing to remove from the 17
  locales or the `LocalizationTests` `requiredKeys` list.

## Persisted data
- Removed the orphaned on-disk cache
  `~/Library/Caches/com.jamesli.usagedock/codex-radar-cache.json` (the filename
  `CodexRadarCache` wrote) so no stale radar payload survives the feature.

## Verification
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` → clean.
- `DEVELOPER_DIR=… swift test` → **53 tests in 9 suites pass** (was 58; −6 radar,
  and the earlier "58" also counted a since-diverged local baseline — no
  failures either way).
- `bash ./script/build_and_run.sh --verify` → exit 0 (app launches, stays up).
- `grep -rn 'radar\|Radar\|重置概率\|codexradar\|CodexRadar' Sources/ Tests/` →
  zero hits.
- Screenshots recaptured via `screencapture -l <windowID>` against the running
  app: `popover-pixel.png` (Codex card now shows only "7天窗口 · 剩余 9%", no
  probability badge) and `dashboard-pixel.png` (官方额度 Codex row shows only
  "7天窗口 · 9%" + reset time, no probability badge). Both confirm the badge is
  gone from both Codex surfaces.
