# TokenRemain — Apple platform build

A locally buildable iPhone + Apple Watch implementation of the confirmed "TokenRemain"
concept. Everything in this subtree is self-contained: `apple/project.yml` is the only
project file, and `TokenRemain.xcodeproj` is generated and git-ignored.

**Honest by construction.** The iPhone never reads Claude/Codex credentials. It renders an
explicit empty state, clearly-labelled deterministic demo data, or an authenticated `.macSync`
snapshot pulled from the user's CloudKit Private Database. The shared AES-256 key lives in a
dedicated synchronizable Keychain access group; provider credentials remain Mac-only. Widgets
and Watch targets receive only the already-validated App Group / WatchConnectivity snapshot and
do not link CloudKit or the sync-key module.

## Requirements

- Xcode 26.5 (iOS 26.5 + watchOS 26.5 SDKs)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Deployment minimums: iOS 18.0, watchOS 11.0

If Xcode is not the active developer directory, prefix commands with
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Commands

All commands run from `apple/`.

```bash
# 1 — generate the Xcode project from project.yml
xcodegen generate

# 2 — build the iPhone app (also builds + embeds the widget extension,
#     the watch app, and the watch widget extension)
xcodebuild -project TokenRemain.xcodeproj -scheme TokenRemain \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# 3 — build the watch app and complications against the watchOS SDK
xcodebuild -project TokenRemain.xcodeproj -scheme TokenRemainWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' build

# 4 — unit tests (presentation, storage, protocol, encryption and replay suites)
xcodebuild test -project TokenRemain.xcodeproj -scheme TokenRemainKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# …or the fast loop, with no simulator:
(cd Packages/TokenRemainKit && swift test)

# 5 — UI tests (10 cases, incl. Live Activity lifecycle and
#     performAccessibilityAudit on every tab)
xcodebuild test -project TokenRemain.xcodeproj -scheme TokenRemainUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Running it by hand

```bash
xcrun simctl install booted \
  "$(xcodebuild -project TokenRemain.xcodeproj -scheme TokenRemain \
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
      -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/TokenRemain.app"

# honest empty state
xcrun simctl launch booted com.jamesli.tokenremain -tr-origin-none

# the confirmed design fixture (46% / LOW / 可持续到重置)
xcrun simctl launch booted com.jamesli.tokenremain -tr-demo concept
```

### Launch arguments (test + screenshot hooks)

| Argument | Effect |
|---|---|
| `-tr-origin-none` | force the not-connected origin, ignoring persisted state |
| `-tr-demo <scenario>` | force demo mode with `concept`, `deficitPace`, `critical`, or `freshReset` |
| `-tr-route <tab>` | open on `overview`, `limits`, `trends`, or `settings` |
| `-tr-force-legacy-chrome` | render the pre-iOS-26 flat chrome instead of Liquid Glass |

## Layout

```
apple/
  project.yml                  XcodeGen spec — the only project file
  Packages/TokenRemainKit/     shared SPM package: models, insights, pace, risk,
                               formatting, theme, pixel components, snapshot store,
                               history, demo composer, intents, Live Activity contract
  App/                         iPhone app (AppModel, router, four tabs, watch sync,
                               branded 1024 px non-alpha App Icon)
  Widgets/                     iOS widget extension: 6 widget kinds, ControlWidget,
                               Live Activity + all Dynamic Island regions
  WatchApp/                    watchOS glance (view-only) + WatchConnectivity receiver
  WatchWidgets/                watchOS complications + Smart Stack card
  UITests/                     XCUITest suite
  SupportFiles/                least-privilege per-target App Group / CloudKit entitlements
  Screenshots/                 captured simulator evidence (git-ignored)
```

## Design system

Three chromatic accents only — **Robot Violet `#8357F5`** (the robot, Claude, primary
accents), **Robot Indigo `#4D5FE8`** (system actions), **Robot Cyan `#00CDE8`** (Codex,
countdowns, confirmations) — over neutral near-black navy, graphite, cool gray and soft
off-white. There is no orange, green, yellow or red anywhere: risk is expressed by accent
*plus* an always-present text label and glyph, so it never depends on hue alone. A unit
test asserts both the WCAG contrast ratios and that every chromatic token sits inside the
violet–cyan hue arc.

See [IMPLEMENTATION-REPORT.md](IMPLEMENTATION-REPORT.md) for exactly what is implemented,
what was verified, and the honest limitations.
