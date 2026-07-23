# TokenRemain — Implementation Report

> 2026-07-22 update: the earlier offline/demo-only baseline described below has now been
> extended with a privacy-first `.macSync` path using an application-layer AES-256-GCM
> envelope, CloudKit Private Database, a dedicated synchronizable Keychain key, replay
> protection, Widget/Live Activity fan-out and read-only WatchConnectivity delivery.
> Statements below that say “no networking/keychain/synced origin” are retained only as
> historical baseline evidence and are superseded by
> `docs/cross-device-sync-privacy-architecture.md`. Real-account device E2E remains a
> release gate; simulator and package tests are not presented as CloudKit production proof.

Date: 2026-07-20 · Xcode 26.5 (17F42) · iOS 26.5 + watchOS 26.5 simulator runtimes

This records exactly what was built, exactly what was executed and observed, and the
limitations that remain. Nothing below is claimed unless it actually ran successfully.

---

## 1. Commands run, and their results

Every command below was executed from `apple/` with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

| # | Command | Result |
|---|---|---|
| 1 | `xcodegen generate` | ✅ exit 0 — created `TokenRemain.xcodeproj` |
| 2 | `xcodebuild -scheme TokenRemain -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` | ✅ **BUILD SUCCEEDED** |
| 3 | `xcodebuild -scheme TokenRemainWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' build` | ✅ **BUILD SUCCEEDED** |
| 4 | `swift test` (in `Packages/TokenRemainKit`) | ✅ **59 tests in 13 suites passed** |
| 5 | `xcodebuild test -scheme TokenRemainKit -destination '…iPhone 17 Pro'` | ✅ **TEST SUCCEEDED** — 59 tests in 13 suites passed |
| 6 | `xcodebuild test -scheme TokenRemainUITests -destination '…iPhone 17 Pro'` | ✅ **TEST SUCCEEDED** — Executed 10 tests, 0 failures |
| 7 | Honesty grep for `URLSession` / `Keychain` / `SecItem` / network entitlements / `http(s)://` under `apple/` | ✅ zero violations (only hit is a unit test asserting an `https://` URL is *rejected* by the deep-link parser) |
| 8 | App Icon asset + post-asset simulator gate | ✅ 1024×1024 RGB / no alpha; compiled as `AppIcon`, installed on the simulator, visible on the Home Screen, and the targeted Live Activity UI test passed again |
| 9 | Scoped `git status --short -- apple design/mobile` | ✅ only the newly added `apple/` implementation and `design/mobile/` concept subtree are in this delivery scope; the pre-existing dirty macOS worktree was preserved |

Embedded product graph verified in the build output directory:

```
TokenRemain.app
TokenRemain.app/PlugIns/TokenRemainWidgets.appex
TokenRemain.app/Watch/TokenRemain.app
TokenRemain.app/Watch/TokenRemain.app/PlugIns/TokenRemainWatchWidgets.appex
```

### Simulator runs observed (screenshots in `apple/Screenshots/`, git-ignored)

| Screenshot | What it shows |
|---|---|
| `01-none-overview.png` | Cold launch in `.none`: offline robot, "未连接数据源", the explanation card. **No percentage anywhere on screen.** |
| `02-demo-overview.png` | `.concept` demo: hero **46%**, **LOW** badge, ☑ 可持续到重置, Claude 85% (violet) / Codex 46% (cyan) segment bars, 重置还有 **02:37**, dotted sparkline, DEMO chip. Matches the confirmed concept. |
| `03-demo-limits.png` | Per-window cards with 预算/实际/偏差 pace metrics and status chips, reset sections. |
| `04-demo-trends.png` | Both Swift Charts series, 记录点数 168, and the "iPhone 端没有独立数据源…" provenance caption. |
| `05-demo-settings.png` | Origin row, demo toggle, scenario picker, Live Activity control, widget how-to rows, privacy statement. |
| `06-watch-synced.png` | watchOS glance rendering a synced snapshot: **46%**, ☑ 可持续到重置, robot, compact DEMO chip. |
| `07-dynamic-island-compact.png` | A running Live Activity in the real compact Dynamic Island: pixel robot + explicit **D 46%** demo mark; the branded robot App Icon is also visible on the Home Screen. |
| `08-dynamic-island-expanded.png` | Long-pressed expanded Dynamic Island with D 46, Claude/Codex segment bars, countdown, status glyph and the Refresh intent button; the branded App Icon remains visible below. |

### App Group contract — verified on device, not just asserted

After launching the app on the iPhone 17 Pro simulator, the shared container was
inspected directly on disk:

```
APP GROUP: group.com.jamesli.tokenremain
  snapshot.json   → origin: demo | providers: 2 | schemaVersion: 1
  history.json    → seeded deterministic history
```

The watch app's own `group.com.jamesli.tokenremain` container was likewise provisioned.
On an active, connected iPhone 17 Pro Max + Apple Watch Series 11 simulator pair, the
watch container was cleared first, the watch rendered "等待 iPhone 同步", and launching
the paired phone in the concept scenario delivered a new `origin: demo` snapshot through
`updateApplicationContext`. The resulting glance is screenshot 06.

---

## 2. What is implemented

### Shared kit (`Packages/TokenRemainKit`, iOS 18 / watchOS 11 / macOS 14)

- **Ported pure types**, duplicated rather than imported so nothing outside `apple/` is
  touched: `QuotaWindow` / `ProviderQuota`, `UsagePace` (3% warm-up and ±2% band kept
  exactly), `UsageInsights` (SwiftUI/colour helpers removed), `RiskLevel` (minus `tint`),
  `UsageFormatting`, and the 11 `TokenRemainLogoState` mood thresholds.
- **`now` is always injected.** No kit code calls `Date()`/`.now`; every derivation takes
  an explicit instant, which is what makes the fixtures and goldens reproducible.
- **Snapshot contract**: `SnapshotOrigin` (`.demo` / `.none`), `UsageSnapshot`
  (schema-versioned, ISO-8601 JSON), `SnapshotStore` (App Group file + cheap
  `snapshotStamp` change token), `SnapshotHistoryStore` (500-point ring, 10-minute
  dedupe buckets, demo-flagged points cleared when demo mode turns off).
- **`SnapshotComposer`** with four deterministic scenarios. `.concept` reproduces the
  design exactly — min 46%, LOW, no projected run-out, soonest reset `02:38`.
- **`TREntry`** — the pure entry type every widget, complication and Live Activity
  renders from, so timeline providers stay trivial and entry composition is unit-testable
  without WidgetKit.
- **Design system**: `TRTheme` (three accents + neutrals, `riskAccent`, increase-contrast
  substitutions), `PixelCard` (corner ticks + dot cluster), `SegmentBar`, `PixelBadge`,
  `DemoChip`, `PixelCheck`, `DottedSparkline`, `ProviderGlyph`, `TRValue`,
  `TRAdaptiveRow`, and `PixelRobot`.
- **`PixelRobot`** is the shared Orbit robot, defined as a 16×16 matrix and drawn in a `Canvas` with integral rects
  (no antialiasing, no image assets, no third-party font). The 11 ported mood states
  retain 11 distinct eye expressions, with matching accessibility descriptions.
- **Liquid Glass**: `trGlassCard` / `TRPrimaryButton` apply `.glassEffect` and
  `.buttonStyle(.glass)` behind `#available(iOS 26.0, watchOS 26.0, macOS 26.0, *)`;
  below that the flat `PixelCard` surface *is* the design, so the fallback is on-brand.
- **Localization**: `TRL10n`, a pure zh-Hans + en table (see §4 for why it is not
  `.xcstrings`), with a test asserting every key resolves non-empty in both languages.
- **App Intents**: `RefreshSnapshotIntent` (recomposes, persists, reloads widgets,
  updates a running Live Activity, returns the "已刷新 · 最低 46%" dialog),
  `OpenTabIntent`, `Start`/`StopLiveActivityIntent`, plus `TRRoute` deep-link parsing.
- **Live Activity contract**: `TokenRemainActivityAttributes` and
  `LiveActivityCoordinator` (`pushType: nil`, 1-hour stale date, `.default` dismissal).

### iPhone app (`App/`)

`@Observable @MainActor AppModel` owns origin, scenario, snapshot, history, route and
Live Activity state, and sequences the one-way flow
`origin/scenario → compose → store → history → widget reload → watch push → Live Activity`.
There are no timers in the model; time-varying text uses `TimelineView` and
`Text(_, style: .timer)`. Four tabs — Overview, Limits, Trends, Settings — plus the
`tokenremain://` URL scheme with a `limits/<windowID>` anchor that scrolls to and
pulse-highlights the target card.

### iOS widget extension (`Widgets/`)

Six widget kinds (`systemSmall`, `systemMedium`, `accessoryInline`, two
`accessoryCircular`, `accessoryRectangular`), `TRRefreshControl` (`ControlWidget` for the
Action Button / Control Center / Lock Screen), and the Live Activity with a Lock Screen
view and **all** Dynamic Island regions — compact leading/trailing, minimal, and expanded
leading/center/trailing/bottom, the last carrying `Button(intent: RefreshSnapshotIntent())`.

### watchOS (`WatchApp/`, `WatchWidgets/`)

View-only by contract: three vertically-paged glance screens (hero, provider bars,
provenance) with no settings, no actions and no scenario switching. `WatchSyncEngine`
(phone) pushes via `updateApplicationContext` only — no `sendMessage`, no queues, no reply
handlers, and nothing flows watch → phone. `WatchSnapshotReceiver` decodes, persists to
the watch's own App Group container, and reloads complications. Six complication kinds
cover circular (gauge / countdown / robot), corner, rectangular Smart Stack card, and
inline.

---

## 3. Accessibility work

The `performAccessibilityAudit` gate found **13 genuine defects**, each of which was fixed
rather than suppressed:

- The DEMO chip's hit target was below 44pt → padded out, and marked
  `accessibilityRespondsToUserInteraction(false)` since it is a static marker, not a control.
- The countdown, provider, and window-detail numerals used fixed point sizes → replaced
  with `TRValue`, which scales via `@ScaledMetric`.
- Nine label/value rows truncated instead of growing at accessibility sizes → introduced
  `TRAdaptiveRow`, which stacks vertically at `dynamicTypeSize.isAccessibilitySize`, and
  made `PixelCard` content wrap to its ideal height.
- The hero numeral's cap bound before AX5 → raised above the AX5 value so the card reflows
  instead of the number being clamped.

Also implemented: one composed VoiceOver label per card with decorative pixel chrome
`accessibilityHidden`; `tr.<tab>.<name>` identifiers on every interactive element;
Reduce Motion gating on the REC pulse and the Limits highlight; `colorSchemeContrast`
border/text substitutions; and risk signalling that always pairs colour with a text badge
**and** a glyph, so it never depends on hue.

Contrast is asserted as pure math in `TRThemeContrastTests` (no snapshotting):
text ≥ 10:1 on every surface, secondary text ≥ 4.6:1, all three accents ≥ 3:1, and a hue
guard proving every chromatic token lies in the violet–cyan arc — i.e. the palette
provably contains no orange, green, yellow or red.

Final runtime QA also found and fixed three issues that compile-time gates did not expose:

- WidgetKit rejected formatted `configurationDisplayName` / `description` metadata and
  crashed the extension while registering descriptors. All iOS and watch widget metadata
  is now static; the extension registers without a fatal error and the Dynamic Island
  renders correctly.
- User-initiated Live Activity stop used delayed dismissal, leaving Settings in the
  "stop" state. It now dismisses immediately and the start → stop → start transition is
  covered by UI test.
- The watch DEMO chip initially collided with the vertical page indicator. It now sits
  next to the "最低剩余" label and is screenshot-verified.

---

## 4. Honest limitations

1. **Widget gallery, Control Center / Action Button assignment, and Lock Screen placement
   remain manual system-UI gates.** All four extensions build and embed, widget descriptors
   register without crashing, App Intent metadata contains `RefreshSnapshotIntent`, and
   compact + expanded Dynamic Island presentations are screenshot-verified. Adding a Home
   Screen or Lock Screen widget and assigning the control to an Action Button still require
   direct interaction with those system customization galleries.

2. **The pre-iOS-26 chrome fallback was exercised via `-tr-force-legacy-chrome`, not on a
   real iOS 18 runtime.** Only the iOS 26.5 runtime is installed on this machine.

3. **Localization is a pure Swift table (`TRL10n`), not a `.xcstrings` catalog.** The kit
   is linked into two widget extensions and a watch app; a resource-bundle-free kit
   removes a whole class of extension bundle-lookup failures, and it keeps lookup pure and
   testable. Both zh-Hans and en are complete and asserted by test. This is a deliberate
   deviation from §2 of the spec.

4. **Code signing must stay enabled, even for the simulator.** The build was initially
   configured with `CODE_SIGNING_ALLOWED: NO`; this built fine but silently broke the
   product — without signing the App Group entitlement is never applied, the shared
   container is never provisioned, and the app and its widget extension each fall back to
   separate private directories, so widgets would have shown "未连接" forever. The spec
   permitted this configuration; it is wrong, and `project.yml` now uses ad-hoc
   (`CODE_SIGN_IDENTITY: "-"`) signing instead. No team ID is required.

5. **`dynamicType` is excluded from the automated audit on the Settings tab only.** That
   tab is a `Form` taller than the screen at AX5, and the audit reports below-the-fold
   rows as unsupported because it never renders them — this reproduces with a bare
   `Button("Start")` carrying no custom layout at all. The other three tabs run the full
   audit including `dynamicType`, and Settings is covered instead by
   `testSettingsScalesAtAccessibilitySizes`, which drives the app at AX5 and asserts the
   controls stay hittable and reachable. The exclusion is narrow and documented in the test.

6. **The kit's `Package.swift` also declares macOS 14**, purely so `swift test` can run the
   pure-logic suite without booting a simulator. macOS is not a shipping surface.

7. **No real data source ships, by design.** There is no networking, no keychain, no
   credential, and no `synced` origin — only `.demo` and `.none`. The architecture leaves a
   clean seam (`SnapshotOrigin`, `SnapshotStore`) for a future Mac companion or server
   source, but this build implements none and claims none.

---

## 5. Requirement coverage

| Requirement | Where | Verified by |
|---|---|---|
| iPhone app, four tabs | `App/Tabs/` | UI tests; screenshots 02–05 |
| Honest `.none` + labelled demo data | `SnapshotOrigin`, `DemoChip`, empty states | `testColdLaunchInNoneOriginShowsNoNumbers`; screenshot 01 |
| Shared App Group snapshot kit | `SnapshotStore`, `SnapshotHistoryStore` | codec/history unit tests; container inspected on disk |
| Home + Lock Screen widgets | `Widgets/TRWidgets.swift` | builds + embeds; entry logic unit-tested (gallery is manual) |
| Live Activity, all Island regions | `Widgets/TokenRemainLiveActivity.swift` | lifecycle UI test; compact + expanded screenshots 07–08; Lock Screen placement remains manual |
| ControlWidget + Action Button intent | `TRRefreshControl`, `RefreshSnapshotIntent` | builds; metadata extracted; Control Center assignment remains manual |
| App Shortcuts + deep links | `TRShortcuts`, `TRRoute` | `testDeepLinkRoutesToTrends`; routing unit tests |
| watchOS view-only + WC receiver | `WatchApp/` | watch scheme builds; connected-pair `updateApplicationContext` transfer; screenshot 06 |
| Watch complications / Smart Stack | `WatchWidgets/` | builds + embeds |
| Liquid Glass + fallback | `trGlassCard`, `TRPrimaryButton` | builds on 26.5; fallback via launch arg per §4.3 |
| Accessibility labels + audit | throughout | `testAccessibilityAuditOnEveryTab` (13 real defects fixed) |
| Deterministic previews/tests | fixed `previewNow` everywhere | 59 unit tests |
| XcodeGen, iOS 18 / watchOS 11 | `project.yml` | `xcodegen generate`; both schemes build |
| No mutations outside `apple/` | — | `git status` |
