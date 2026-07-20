# Token Remain — Apple-Platform Implementation Specification

**Audience:** Claude Opus 4.8 coding agent.
**Repo:** `/Users/jamesli/Developer/Desktop_Projects/UsageDock-project`
**Visual target (confirmed):** `design/mobile/token-remain-apple-system-concept-2026-07-20.png`
**Hard constraint:** All new files live under `apple/`. Do **not** modify `Sources/`, `Tests/`, `Package.swift`, `Resources/`, `Config/`, `script/`, `docs/`, `design/`, `README.md`, or anything else outside `apple/`. The worktree is heavily dirty and user-owned — never run repo-wide formatters, `git add -A`, `git checkout`, or `git clean`.

---

## 0. Context

UsageDock today is a macOS menu-bar app that reads **local** Claude Code / Codex quota state (Claude via a PTY-driven `/usage`, Codex via `~/.codex` session files, ccusage via `npx`). None of those sources exist on iPhone or Apple Watch, and macOS CLI credentials must never travel to mobile. The confirmed mobile concept ("Token Remain") is a pixel-tech, low-contrast three-color robot design spanning iPhone app, Dynamic Island Live Activity, Home Screen widgets, Lock Screen widgets, an Action Button control, and watchOS glance + complications.

The mission: build a **real, locally buildable** Apple-platform implementation of that system that is **honest about data provenance** — every surface either renders clearly-labeled deterministic demo data or an explicit "no data source connected" state. The architecture leaves a clean seam for a future real sync source (e.g. the curated-feed server or a Mac companion push), but ships none.

---

## 1. Product behavior & honest data boundaries

### 1.1 Data provenance model

Every snapshot carries an origin. This is the product's core honesty mechanism.

```swift
enum SnapshotOrigin: String, Codable, Sendable {
    case demo      // deterministic fixture, user-enabled
    case none      // no source connected — surfaces render honest empty states
    // future (NOT implemented): case synced
}
```

Rules, enforced in UI and copy:

1. **No fabricated live data.** The iPhone has no Claude/Codex source. On first launch the app is in `origin == .none`: Overview shows the robot in `offline` mood, "未连接数据源" headline, and a card explaining exactly what a real source would require (a Mac companion sync or a server — neither ships). No percentages are shown in `.none`.
2. **Demo Mode is explicit and labeled everywhere.** When the user enables Demo Mode in Settings, every surface that renders demo numbers shows a persistent `DEMO` pixel chip (app screens: chip in the nav header; widgets/Live Activity/watch: a 4×4-pixel `D̸` glyph + "演示" in the corner, accessibilityLabel "演示数据"). Demo Mode is the only way the widgets, Live Activity, and watch show numbers.
3. **No credentials on mobile.** No keychain items for Claude/Codex/X, no network entitlement usage, no URLSession calls. The app is fully offline.
4. **Estimates stay estimates.** Pace projection copy mirrors macOS: "按当前节奏预计…" phrasing; never present projections as facts.
5. **Staleness is visible.** Every surface renders `generatedAt` freshness ("刚刚 / n 分钟前") using the ported `UsageFormatting.freshnessDescription`. Watch adds "来自 iPhone" provenance.

### 1.2 What the product does

- Shows **remaining** quota (all percentages are remaining, matching macOS convention) for Claude (5h + 7d windows) and Codex (7d window), the **minimum remaining** as the hero number, a risk badge (LOW/MEDIUM/HIGH via ported `RiskLevel` thresholds: `<10 → high`, `<30 → medium`, projected run-out → medium), pace status per window (on-track / reserve / deficit via ported `UsagePace`), reset countdowns, and a trend of snapshots **actually observed on-device**.
- Lets the user start/stop a **Live Activity**, add **widgets** (Home + Lock Screen), install a **Control** (Action Button / Control Center / Lock Screen), run **App Shortcuts**, and view everything read-only on **Apple Watch**.

---

## 2. iPhone information architecture — four tabs

Tab bar matches design panel 1: **Overview · Limits · Trends · Settings** (概览 · 额度 · 趋势 · 设置). SF Symbols: `circle.inset.filled`, `square.split.2x1`, `chart.line.uptrend.xyaxis`, `gearshape`.

### 2.1 Overview (概览)

Top-to-bottom, per the design:

1. **Header:** "Overview" large title; beneath it the pixel robot mini-glyph + "Token Remain" wordmark (monospaced). `DEMO` chip when demo.
2. **Risk hero card:** left column — "当前额度风险" caption, risk badge (`LOW` in large pixel caps), "最低剩余" caption, giant min-remaining value ("46%", monospaced, ~64pt), pace line with pixel checkbox ("☑ 可持续到重置" when every window's pace `willLastUntilReset`, else "⚠ 预计 <duration> 后用尽" from the earliest `paceAssessment`). Right column — the large pixel robot (mood from remaining %). Top-right: source status line ("全部数据源正常" in demo / "未连接数据源" otherwise).
3. **Provider cards** (one per provider): provider pixel glyph (Claude sunburst ✳ violet, Codex knot cyan), name, remaining % right-aligned; a **14-segment block progress bar** showing remaining; footer "7 天窗口 · 周五 13:00 重置" (window name via `UsageFormatting.windowName`, reset via `resetDescription`). Claude card shows its scarcer window's bar with a secondary line for the other window.
4. **Two half-width cards:** "重置还有 02:38 · 周五 13:00" countdown card (soonest reset, live-updating via `TimelineView(.periodic)` at 1s only while foregrounded; the `REC` pixel dot pulses when a Live Activity is running) and "7 天趋势" sparkline card (dotted pixel sparkline of observed min-remaining history; honest empty state "暂无本机历史" when <2 points).
5. **CTA row:** "查看最紧张窗口 ›" — navigates to Limits, scrolled/highlighted to `constrainingWindow`.
6. In `.none` origin, cards 2–5 collapse into the empty-state card described in §1.1.

### 2.2 Limits (额度)

One detail card per `UsageInsights.Window` (ordering: provider, then primary→secondary):

- Window title ("Claude · 5 小时窗口"), remaining % hero, 14-segment bar.
- Pace section: expected vs actual used %, delta, status chip (按预算 / 有盈余 / 超预算), projected run-out line when `estimatedRunOutAt != nil`.
- Reset section: `resetDescription`, absolute time, "官方重置时间" caption; "重置时间未知" when `resetsAt == nil` (Claude fresh-reset case — keep this honest state).
- Deep-link anchor: `tokenremain://limits/<windowID>` scrolls to and pulse-highlights the card.

### 2.3 Trends (趋势)

Renders **only history the phone has actually recorded** (`SnapshotHistoryStore`, §6.3): a per-day min-remaining line chart (Swift Charts, pixel-dot point style) over the last 7 days, plus a per-provider remaining chart, plus "记录点数 / 最早记录" metadata. Demo mode seeds a deterministic 7-day series (labeled DEMO). In `.none` with no history: empty state explaining "iPhone 端没有独立数据源，趋势只记录本机看到过的快照。"

### 2.4 Settings (设置)

- **数据源** group: origin status row; **Demo Mode toggle**; **scenario picker** (§6.2) visible when demo is on.
- **实时活动** group: Start/Stop Live Activity button + current state; system Live Activity permission hint if denied.
- **小组件** group: static how-to rows for Home/Lock Screen widgets and the Action Button control (no fake toggles — widgets are user-added in system UI).
- **Apple Watch** group: last-sync status from WatchConnectivity (`isPaired`, `isWatchAppInstalled`, last `applicationContext` push time).
- **关于** group: version, privacy statement ("Token Remain 不联网、不存储任何凭证"), link-free.

Localization: zh-Hans primary + en, via a small `String(localized:)` catalog in the kit (mirror macOS L10n keys where copy matches; do not import the macOS `L10n.swift`).

---

## 3. Visual system — low-contrast three-color robot palette & pixel-tech components

### 3.1 Palette (`TRTheme`)

Three chromatic roles on an ink ground; dark-only appearance (app sets `.preferredColorScheme(.dark)`; widgets render dark tints in both system appearances).

| Token | Hex | Role |
|---|---|---|
| `ink` | `#070B12` | canvas |
| `surface` | `#0D1420` | cards |
| `surface2` | `#141D2C` | insets/chips |
| `border` | `#223044` | 1px card borders, pixel corner ticks |
| `track` | `#1B2536` | empty bar segments |
| `violet` | `#8F7BF2` | Color 1 — robot, Claude, primary accents, LOW badge |
| `violetDim` | `#5B4FB0` | violet at rest (segment mid-tone) |
| `cyan` | `#3ECFE0` | Color 2 — Codex, countdowns, confirmations |
| `cyanDim` | `#2B8FA0` | cyan at rest |
| `text` | `#E9EDF5` | Color 3 — primary text/values |
| `textDim` | `#8B97AB` | secondary text |
| `textMute` | `#55617A` | captions, disabled |

Risk/status is expressed **within the three colors**: LOW = violet badge, MEDIUM = cyan badge + `!` pixel glyph, HIGH = text-white badge on violet field + `‼` glyph, plus always a text label — never a red/green-only signal. Provider identity: Claude = violet, Codex = cyan (this intentionally diverges from macOS orange/blue; the mobile design is the confirmed target).

### 3.2 Pixel-tech component kit (`TRComponents` in the shared package)

- **`PixelCard`**: `surface` fill, 1px `border` stroke, 8pt radius, 4 corner "tick" marks (3×1px L-shapes) and a 2×2 dot cluster in one corner — drawn in a `Canvas` overlay, `accessibilityHidden(true)`.
- **`SegmentBar`**: 14 segments (3pt gap, 6pt tall, 2pt radius). Filled = accent, empty = `track`. Value = *remaining*. Widget accessory variants use 10 segments.
- **`PixelBadge`**: uppercase monospaced caption in a bordered chip (`LOW`, `DEMO`, `REC`, `IEC`-style meta tags from the design).
- **`PixelCheck`**: 5×5 pixel checkbox glyph (checked/warn variants).
- **`DottedSparkline`**: Canvas-drawn dot-per-sample sparkline.
- **`PixelRobot`**: the robot drawn as a code-defined pixel matrix (`[[PalettePixel]]`, violet body / cyan eye-glow variants), scalable from 12pt (Dynamic Island minimal) to 96pt (Overview hero), antialiasing off (`.interpolation(.none)`-equivalent via integral `Canvas` rects). **Moods:** port the exact `TokenRemainLogoState.resolve` thresholds (96/86/76/66/56/46/36/26/16/0.5) but collapse to **5 drawn faces** — excited (star eyes), calm (flat glow eyes, the design's face), neutral (dash eyes), worried (slant eyes + sweat pixel), offline (X eyes) — with the 11 accessibility descriptions preserved (translated from `TokenRemainLogo.swift`).
- **Typography:** system SF; all numerals `.monospaced()` with `.monospacedDigit()`; hero values `fontWeight(.semibold)`. No third-party pixel font (avoids licensing + widget font loading); the pixel feel comes from chrome, not glyphs.

### 3.3 Liquid Glass (iOS 26) with fallback

- Wrap in `TRSurface` helpers: on iOS 26+, the tab bar is system Liquid Glass automatically; apply `.glassEffect(.regular, in: …)` to the risk hero card and the floating CTA, and `.buttonStyle(.glass)` for primary buttons. Guard with `if #available(iOS 26.0, *)`.
- Fallback (< iOS 26): `PixelCard` flat surfaces exactly as specced — the design image itself is the fallback look, so both paths are on-brand.
- Widgets/Live Activity: never apply glass manually; rely on system-provided rendering, use `containerBackground(for: .widget)` with `ink`.

---

## 4. Accessibility

- **Contrast:** `text` on `surface` ≈ 13:1; `textDim` on `surface` ≥ 4.6:1. All value-bearing text must use `text`/`textDim` only; `textMute` and decorative pixel chrome only for non-essential ornament. Verify with a unit test computing WCAG ratios of the token pairs (pure math, no snapshotting).
- **VoiceOver:** every card is one accessibility element with a composed label, e.g. risk hero → "当前额度风险低，最低剩余 46%，可持续到重置，演示数据"; SegmentBar hidden behind the parent label; robot uses the ported 11 descriptions. Widgets/Live Activity views get explicit `accessibilityLabel`s (island regions included).
- **Dynamic Type:** all app text uses text styles; hero number caps at `.accessibility2` via `@ScaledMetric`; cards reflow vertically at accessibility sizes (test at AX5).
- **Reduce Motion:** pulse/REC animations gated on `accessibilityReduceMotion`.
- **Increase Contrast:** when `colorSchemeContrast == .increased`, swap `textDim → text`, `border → #3A4A66`.
- **Differentiate Without Color:** already satisfied structurally (badges always carry text + glyph); assert in UI tests via accessibility identifiers (`tr.overview.riskBadge`, etc. — prefix every interactive element `tr.<tab>.<name>`).

---

## 5. State model

`@Observable @MainActor final class AppModel` (iOS app target) owns:

```swift
var origin: SnapshotOrigin            // persisted in app-group defaults
var demoScenario: DemoScenario        // persisted
var snapshot: UsageSnapshot?          // current, derived from origin+scenario
var insights: UsageInsights?          // computed from snapshot
var liveActivityState: LiveActivityState   // .inactive / .active(id) / .denied
var history: [SnapshotHistoryPoint]   // from SnapshotHistoryStore
```

Flow: `origin/demoScenario` change → `SnapshotComposer.compose(origin:scenario:now:)` → write via `SnapshotStore` (App Group, §6) → append to history → `WidgetCenter.shared.reloadAllTimelines()` → push `applicationContext` to watch → update Live Activity if active. All derivation is pure and `now`-injected; the model only orchestrates. No timers in the model — time-varying text uses SwiftUI `TimelineView`/`Text(timerInterval:)`.

---

## 6. Deterministic fixtures, demo scenarios, snapshot contract

### 6.1 Shared snapshot contract (`TokenRemainKit`)

The single serialization contract for App Group, WatchConnectivity, history, and previews:

```swift
struct UsageSnapshot: Codable, Sendable, Equatable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let origin: SnapshotOrigin
    let generatedAt: Date
    let providers: [ProviderQuota]     // ported struct, unchanged shape
    let dailyTokens: [AgentTokens]?    // {id, tokens, estimatedCost} — demo only
}
```

- Stored as JSON (ISO-8601 dates) at `AppGroup.containerURL/snapshot.json` plus a lightweight `snapshotStamp` (double, epoch of generatedAt) in `UserDefaults(suiteName:)` so widgets can cheaply detect change. `SnapshotStore.write/read` with schema-version gate: unknown version ⇒ treat as `.none`.
- **Ported pure types** (copy into kit; source of truth listed for the coding agent): `QuotaWindow`/`ProviderQuota` from `Sources/UsageDock/Models/UsageModels.swift`, `UsagePace` (`Support/UsagePace.swift` — keep the 3% warm-up and ±2% band exactly), `UsageInsights` minus SwiftUI/color helpers (`Support/UsageInsights.swift`), `RiskLevel` minus `tint` (`Support/RiskLevel.swift`; tint mapping moves to `TRTheme.riskAccent`), `UsageFormatting` (`Support/UsageFormatting.swift`) with `L10n` calls replaced by `String(localized:)`. Do not `import` or symlink the macOS sources — duplication is deliberate to honor the no-touch constraint.

### 6.2 Demo scenarios (`DemoScenario`)

Deterministic generator: `SnapshotComposer.demo(scenario:now:)` builds windows as **fixed offsets from `now`** so countdowns look live yet the data is reproducible for any injected `now`. Scenarios (picker in Settings):

| Case | Claude 5h / 7d remaining | Codex 7d | Character |
|---|---|---|---|
| `.concept` *(default)* | 92% / **85%** | **46%** | Matches the design image (min 46%, LOW, 可持续到重置; resets at now+2h38m / Fri-style +3d, +4d) |
| `.deficitPace` | 78% / 62% | 31% | Codex deficit; projected run-out at now+9h |
| `.critical` | 8% / 55% | 12% | HIGH risk; run-out now+42m |
| `.freshReset` | 100% (resetsAt nil) / 97% | 88% | Exercises unknown-reset honesty |

Previews & tests always pass a **fixed** `now` (`Date(timeIntervalSinceReferenceDate: 790_000_000)`); runtime uses `.now`. Never call `Date()`/`Date.now` inside kit logic — always a parameter (existing repo pattern; keep it).

### 6.3 History

`SnapshotHistoryStore` (kit): ring buffer (max 500 points, `{generatedAt, minRemainingPercent, perProviderRemaining}`) in `history.json` in the App Group, appended on every composed snapshot, deduped per 10-minute bucket. Demo-on seeds a deterministic 7×24-point wave series flagged demo; disabling demo **clears demo-flagged points** (honesty: no demo residue presented as real).

---

## 7. App Group contract (iOS app ↔ widgets)

- **Group ID:** `group.com.jamesli.tokenremain` — iOS app, iOS widget extension, watch app, watch widget extension (watch has its own container; same ID).
- Writers: iOS app only (on phone); watch app only (on watch, persisting received context). Widget extensions are read-only.
- Widget `TimelineProvider`s read `SnapshotStore`; timelines: single entry at `.now` + `.after(now+15m)` refresh policy; countdown text uses `Text(timerInterval:)`/`Text(date, style:)` so entries stay sparse. `.none` origin ⇒ placeholder-style "未连接" entry (robot offline, no numbers).

---

## 8. watchOS — view-only + WatchConnectivity boundary

- **Watch app (SwiftUI, watchOS-only target):** exactly the design's Glance — vertically paged: page 1 hero (最低剩余 46%, robot, pace check line), page 2 provider bars + reset line, page 3 provenance ("来自 iPhone · n 分钟前" / "等待 iPhone 同步"). **No settings, no actions, no scenario switching, no Live Activity control** — view-only by contract.
- **Boundary:** `WatchSyncEngine` on iPhone pushes the encoded `UsageSnapshot` via `WCSession.updateApplicationContext` on every snapshot change (context overwrites are ideal for latest-value semantics; no queues, no `sendMessage`, no reply handlers). Watch side: `WatchSnapshotReceiver` decodes, writes to watch App Group `SnapshotStore`, calls `WidgetCenter.reloadAllTimelines()`. The watch **never** composes, projects, or mutates data — it renders the last snapshot + staleness. If never synced: full-screen honest empty state.
- **Complications (watch widget extension, WidgetKit):** `accessoryCircular` (three variants via `intent`-less separate widget kinds to keep it simple: RemainGauge — `Gauge` 46% + mini robot; ResetCountdown — `Text(timerInterval:)` "02:38 重置"; StatusRobot — robot face only), `accessoryCorner` (46% curved label), `accessoryRectangular` (Smart Stack card: robot + 最低剩余 46% + ☑ line + reset line, matching the design's Smart Stack panel), `accessoryInline`.

---

## 9. Live Activity — user-started, all Dynamic Island regions

**Target:** lives in the iOS widget extension (`ActivityConfiguration` beside widgets). `NSSupportsLiveActivities = YES` in the iOS app Info.plist (XcodeGen inline plist).

```swift
struct TokenRemainActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let minRemainingPercent: Double
        let providers: [ProviderLine]   // {name, remainingPercent, accent}
        let soonestReset: Date?
        let willLastUntilReset: Bool
        let isDemo: Bool
    }
    let startedAt: Date
}
```

- **Lifecycle:** user-started only — Settings button or `StartLiveActivityIntent`. `Activity.request(…, pushType: nil)` (local-only; no push server exists — do not claim remote updates). Updated by `LiveActivityCoordinator` whenever the app composes a new snapshot (foreground) and on `RefreshSnapshotIntent` (control/shortcut). `staleDate = now + 1h`: past it the system dims the activity, and the UI renders a "数据未更新" line (honest staleness). Ended by: user button, `StopLiveActivityIntent`, or app-side end with `.default` dismissal when demo mode turns off. If `ActivityAuthorizationInfo().areActivitiesEnabled == false`, Settings shows the denied hint.
- **Lock Screen / banner view:** wide `PixelCard`: robot + 最低剩余 46% left; Claude/Codex mini SegmentBars center; reset countdown right; DEMO chip.
- **Dynamic Island** (all regions, matching design panel 2):
  - `compactLeading`: 12pt robot; `compactTrailing`: "46%" monospaced (violet).
  - `minimal`: robot only.
  - `expanded.leading`: robot + "最低剩余 46%"; `expanded.center`: two provider rows (name, 10-segment bar, %); `expanded.trailing`: "1 天 2 小时后用尽" or "☑ 可持续到重置" + reset time; `expanded.bottom`: `Button(intent: RefreshSnapshotIntent())` "刷新" (glass on iOS 26).

---

## 10. Widgets (iOS widget extension `TokenRemainWidgets`)

One `WidgetBundle`; kinds (match design panels 3–4):

| Kind | Families | Content |
|---|---|---|
| `TRHeroWidget` | `.systemSmall` | Robot, 46% hero, risk badge, DEMO chip |
| `TRProvidersWidget` | `.systemMedium` | Left: Claude/Codex rows with segment bars; right: reset countdown + ☑ pace line (design's medium) |
| `TRInlineWidget` | `.accessoryInline` | robot glyph + "46% 可持续到重置" |
| `TRCircularWidget` | `.accessoryCircular` | `Gauge`(remaining) around robot/46%; `AccessoryWidgetBackground()` |
| `TRResetCircularWidget` | `.accessoryCircular` | countdown ring "02:38 重置" |
| `TRRectangularWidget` | `.accessoryRectangular` | robot + 46% + ☑ line; second variant row 重置还有 02:38 |

All support `containerBackground(for: .widget)`; Lock Screen families rely on system vibrant rendering (design's monochrome lock look comes free). No configuration intents (static widgets) — smallest coherent set.

### 10.1 ControlWidget (Action Button / Control Center / Lock Screen)

`TRRefreshControl: ControlWidget` (iOS 18+) → `ControlWidgetButton` running `RefreshSnapshotIntent`, symbol `arrow.clockwise`, title "刷新额度". `RefreshSnapshotIntent` (in kit, `openAppWhenRun = false`): recomposes the snapshot at current `now` (demo: same scenario, fresh offsets), writes App Group, reloads widgets, updates Live Activity, returns `ProvidesDialog` — "已刷新 · 最低 46%" (design panel 5's confirmation state), or "未连接数据源" in `.none`. Assign to Action Button via Settings → Action Button → Controls.

### 10.2 App Shortcuts & deep links

- `AppShortcutsProvider` phrases (zh+en): "刷新 Token Remain 额度" → `RefreshSnapshotIntent`; "查看 Token Remain" → `OpenTabIntent(.overview)`; "开始/停止 Token Remain 实时活动" → `Start/StopLiveActivityIntent`.
- URL scheme `tokenremain://` with routes `overview | limits | limits/<windowID> | trends | settings`; widgets use `.widgetURL`, `OpenTabIntent` opens via `openAppWhenRun = true` + router in `AppModel`.

---

## 11. Project structure, XcodeGen graph, identities

```
apple/
  project.yml                     # XcodeGen spec (only project file; .xcodeproj is generated, git-ignored via apple/.gitignore)
  .gitignore                      # *.xcodeproj, DerivedData, xcuserdata
  README.md                       # build/run/test commands for this subtree only
  Packages/TokenRemainKit/        # local SPM package (models, insights, formatting, theme, components, fixtures, stores, intents)
    Package.swift                 # platforms: iOS 18, watchOS 11
    Sources/TokenRemainKit/...
    Tests/TokenRemainKitTests/...
  App/                            # iOS app target sources (AppModel, tabs, router, LiveActivityCoordinator, WatchSyncEngine)
  Widgets/                        # iOS widget extension (bundle, widgets, live activity views, control)
  WatchApp/                       # watchOS app sources (glance pages, WatchSnapshotReceiver)
  WatchWidgets/                   # watchOS widget extension (complications)
  UITests/                        # iOS UI tests
  SupportFiles/                   # entitlements files per target
```

**project.yml essentials:**

- `options: { deploymentTarget: { iOS: "18.0", watchOS: "11.0" } }`, Swift 6 language mode, `GENERATE_INFOPLIST_FILE: YES` with inline `info` blocks (Live Activities key, URL scheme, `WKCompanionAppBundleIdentifier` handled automatically by watch app template settings).
- Targets & bundle IDs:
  - `TokenRemain` (iOS app) — `com.jamesli.tokenremain`; depends on kit, embeds `TokenRemainWidgets`, embeds watch app.
  - `TokenRemainWidgets` (app extension, `com.apple.widgetkit-extension`) — `com.jamesli.tokenremain.widgets`.
  - `TokenRemainWatch` (watchOS app) — `com.jamesli.tokenremain.watchkitapp`; embeds `TokenRemainWatchWidgets`.
  - `TokenRemainWatchWidgets` — `com.jamesli.tokenremain.watchkitapp.widgets`.
  - `TokenRemainUITests`.
- Entitlements (files in `SupportFiles/`): App Groups `group.com.jamesli.tokenremain` on all four product targets. No other capabilities. `CODE_SIGN_IDENTITY: "-"`-style local signing is fine for simulator; do not require a team ID for the acceptance gates (simulator only).
- Rationale for minimums: **iOS 18.0** is the floor for `ControlWidget` (a requested surface); **watchOS 11.0** matches. iOS 26 APIs (Liquid Glass) are availability-gated. Build with Xcode 26.5 / iOS 26.5 / watchOS 26.5 SDKs.

---

## 12. Testing strategy

### 12.1 Unit tests (`TokenRemainKitTests`, Swift Testing)

- **Pace math:** port-parity cases for `UsagePace` (warm-up <3% ⇒ nil, ±2% band, deficit run-out projection, expired/absent reset ⇒ nil).
- **Risk mapping:** threshold edges 9.99/10/29.99/30, projectedRunOut promotion, nil ⇒ unknown.
- **Insights:** windows ordering, `constrainingWindow`, `soonestReset`, min-remaining.
- **Snapshot codec:** round-trip equality; unknown `schemaVersion` ⇒ nil; corrupted JSON ⇒ nil (no crash).
- **Determinism:** `SnapshotComposer.demo(scenario:now:fixedNow)` twice ⇒ identical snapshots; `.concept` yields exactly min 46%, risk `.low`, `willLastUntilReset == true`.
- **History:** dedupe bucket, ring cap, demo-clear removes only demo points.
- **Robot mood:** the 11 threshold cases from `TokenRemainLogoState.resolve` parity.
- **Formatting:** countdown/reset/window-name goldens with injected `now`.
- **Contrast:** WCAG ratio assertions for the §4 token pairs.

### 12.2 UI tests (`TokenRemainUITests`, iPhone simulator)

- Cold launch in `.none` ⇒ empty-state identifier exists, no "%" text anywhere.
- Enable demo (launch arg `-tr-demo concept` for determinism) ⇒ risk badge `LOW`, hero `46%`, DEMO chip visible on Overview; all four tabs reachable; CTA lands on highlighted Limits card.
- Scenario switch to `.critical` ⇒ badge `HIGH`.
- Deep link `tokenremain://trends` routes correctly.
- Accessibility audit via `XCUIApplication.performAccessibilityAudit()` on each tab (iOS 17+ API).

Widget/Live Activity/watch rendering is validated by build + manual simulator gates (below), not XCUITest — WidgetKit isn't XCUITest-drivable; keep providers thin and unit-test their entry composition instead (`TimelineProviderLogicTests` on the kit's entry builder).

### 12.3 Simulator acceptance matrix & completion gates

Matrix (all on Xcode 26.5 SDKs):

| Device | OS | Purpose |
|---|---|---|
| iPhone 17 Pro sim | iOS 26.5 | primary; Liquid Glass path; Dynamic Island |
| iPhone 16 sim (or any iOS 18.x runtime if installed; else same 26.5 device with glass code paths force-disabled via launch arg `-tr-force-legacy-chrome`) | iOS 18.x / fallback mode | pre-26 chrome fallback |
| Apple Watch Series 11 (46mm) sim paired to iPhone 17 Pro | watchOS 26.5 | watch app + complications + WC sync |

**Exact completion gates — all must pass, run from `apple/`:**

1. `xcodegen generate` exits 0; `apple/*.xcodeproj` is git-ignored; `git status` shows **zero** changes outside `apple/`.
2. `xcodebuild -project TokenRemain.xcodeproj -scheme TokenRemain -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` exits 0 (this also builds the widget extension and embedded watch targets).
3. `xcodebuild test` for scheme `TokenRemainKit` (unit tests) exits 0.
4. `xcodebuild test` for scheme `TokenRemainUITests` on iPhone 17 Pro exits 0.
5. App boots on iPhone 17 Pro sim; screenshots captured (`xcrun simctl io booted screenshot`) of: `.none` empty state, and all four tabs in `.concept` demo — hero reads 46% / LOW.
6. Widget gallery (long-press Home → add widget) shows Token Remain with small+medium; Lock Screen gallery shows inline/circular/rectangular; each renders demo data with DEMO mark, and `.none` variants render "未连接" (toggle demo off, `simctl` screenshot again).
7. Control Center gallery lists "刷新额度" control; tapping it produces the "已刷新 · 最低 46%" dialog.
8. Live Activity: start from Settings ⇒ appears on Lock Screen and Dynamic Island (compact + expanded verified by screenshot); Stop ends it; expanded 刷新 button updates `generatedAt` freshness text.
9. Paired watch sim: watch app renders the synced `.concept` snapshot ("来自 iPhone"); watch widget gallery shows circular/corner/rectangular/inline complications rendering demo data; with demo off, watch shows the honest empty state after next sync.
10. `performAccessibilityAudit` passes on all tabs; VoiceOver spot-check labels on risk hero and one widget (simulator Accessibility Inspector).
11. Grep gate for honesty: no `URLSession`, no `Keychain`, no network entitlement anywhere under `apple/`.

---

## 13. Numbered, dependency-ordered coding plan

1. Create `apple/` skeleton: `.gitignore`, `README.md`, `SupportFiles/` entitlements, empty target dirs.
2. Scaffold `Packages/TokenRemainKit` (Package.swift, iOS 18/watchOS 11) and port pure types from the macOS sources listed in §6.1 (models, `UsagePace`, `UsageInsights` sans SwiftUI, `RiskLevel` sans tint, `UsageFormatting` with `String(localized:)`, robot mood thresholds); add the zh-Hans/en string catalog.
3. Add snapshot layer to the kit: `SnapshotOrigin`, `UsageSnapshot`, `SnapshotStore` (App Group JSON + stamp), `SnapshotHistoryStore`, `SnapshotComposer` with the four `DemoScenario`s and fixed-`now` preview fixtures.
4. Write kit unit tests (§12.1) and get them passing via `swift test` inside the package (fast loop before any Xcode project exists).
5. Build the visual kit in the package: `TRTheme` tokens, `PixelCard`, `SegmentBar`, `PixelBadge`, `PixelCheck`, `DottedSparkline`, `PixelRobot` (5 faces × moods), `TRSurface` glass/fallback helpers — each with fixed-`now` `#Preview`s.
6. Author `apple/project.yml` with the five-target graph, bundle IDs, App Group entitlements, inline Info.plists (Live Activities key, `tokenremain://` scheme); run `xcodegen generate`; confirm empty targets build (gate 1–2 skeleton).
7. Implement the iOS app: `AppModel`, router/deep links, Overview tab (§2.1), then Limits, Trends, Settings; wire demo toggle/scenario → compose → store → widget reload; launch-argument hooks (`-tr-demo`, `-tr-force-legacy-chrome`).
8. Implement `TokenRemainWidgets`: timeline entry builder in kit, `TRHeroWidget`, `TRProvidersWidget`, the three accessory kinds, `WidgetBundle`; verify in widget gallery (gate 6).
9. Implement App Intents in kit (`RefreshSnapshotIntent`, `OpenTabIntent`, `Start/StopLiveActivityIntent`), `AppShortcutsProvider`, and `TRRefreshControl` ControlWidget (gate 7).
10. Implement Live Activity: attributes/content state in kit, `LiveActivityCoordinator` in app, Lock Screen view + all Dynamic Island regions in the widget extension, stale/dismiss lifecycle (gate 8).
11. Implement watch: `WatchSyncEngine` (iPhone) + `WatchSnapshotReceiver` (watch), glance pages, `TokenRemainWatchWidgets` complications; verify on paired sims (gate 9).
12. Accessibility pass (§4): labels/identifiers, Dynamic Type reflow, Reduce Motion/Increase Contrast adaptations; add contrast unit test.
13. Write `TokenRemainUITests` (§12.2) and make them pass (gate 4, 10).
14. Run the full acceptance matrix (§12.3), capture screenshots into `apple/README.md`, execute the honesty grep gate, and confirm `git status` cleanliness outside `apple/` (gates 1–11).

## 14. Requirement-to-evidence checklist

| # | Requirement | Where implemented | Evidence (gate) |
|---|---|---|---|
| 1 | Honest data boundaries; no fake live data; no CLI creds on mobile | §1 `SnapshotOrigin`, `.none` empty states, DEMO chips; no networking/keychain | Gates 5, 6, 11 |
| 2 | iPhone IA, four tabs | §2 Overview/Limits/Trends/Settings | Gates 4, 5 |
| 3 | Three-color low-contrast robot palette + pixel components | §3 `TRTheme`, `TRComponents`, `PixelRobot` | Gate 5 screenshots vs design PNG; contrast test (gate 3) |
| 4 | Accessibility | §4 | Gates 3 (contrast test), 10 (audit) |
| 5 | State model + deterministic fixtures | §5, §6.2 fixed-`now` composer | Gate 3 determinism tests |
| 6 | App Group snapshot contract | §6.1, §7 `SnapshotStore` | Gate 3 codec tests; gate 6 widgets render app-written data |
| 7 | watchOS view-only + WC boundary | §8 applicationContext-only sync, render-only watch | Gate 9 |
| 8 | User-started Live Activity, all Island regions, lifecycle | §9 | Gate 8 |
| 9 | Home + Lock Screen widget families | §10 (systemSmall/Medium, inline/circular/rectangular) | Gate 6 |
| 10 | ControlWidget / Action Button intent | §10.1 | Gate 7 |
| 11 | App Shortcuts + deep links | §10.2 | Gate 4 (deep-link UI test); Shortcuts app spot-check |
| 12 | Liquid Glass iOS 26 + fallback | §3.3, `-tr-force-legacy-chrome` | Gate 5 on both matrix rows |
| 13 | XcodeGen graph, bundle IDs, entitlements, targets, layout | §11 | Gates 1–2 |
| 14 | Unit/UI test strategy | §12.1–12.2 | Gates 3–4 |
| 15 | Simulator acceptance matrix + exact gates | §12.3 | Gates 1–11 checklist run |
| 16 | No modification outside `apple/` | Hard constraint header; generated project git-ignored | Gate 1 `git status` check |
