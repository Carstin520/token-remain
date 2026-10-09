# October 2026 requirements: design and acceptance

## Scope and baseline

The supplied requirements document mixes existing functionality, historical issues, proposals and four actionable requests. This change implements the four requests below. Main had advanced from the document's `c30f66f` to `d488b60`; PR #60 was already merged. Development uses an isolated worktree and preserves the user's original checkout and uncommitted changes.

The user selected full macOS implementation, Windows compatibility validation and an optional manually pasted Claude web Cookie. Commit, push and batched PR creation are authorized. Merging, publishing, deployment, mobile changes and issue replies are outside this delivery. Historical contributor PRs, Windows release, browser credential import and speculative backlog remain separate work.

## Design and batches

| Batch | Requirement and implementation | Acceptance evidence |
| --- | --- | --- |
| 1 / #62 | Original generic robot glyph for third-party API sources, shared SwiftUI/AppKit rendering | Seven rendering tests; light/dark and 1x/2x image inspection |
| 2 / #63 | Code defaults plus bounded Cowork discovery and user-selected log roots; bundled ccusage remains offline and deduplicates records. Optional local-only Claude sessionKey selects the default web account; isolated CLI accounts remain separate | Synthetic real-helper integration retains 2,020 unknown-price tokens and deduplicates shared records. HTTP, organization selection, credential revision, timeout, cancellation and late-result fixtures |
| 3 / #64 | Trends model analysis with input/output/cache read/cache write rates, tokens and reference costs. Existing ccusage total is retained and reconciled with a signed Other / unsplit amount | Old/new cache decoding, split aggregation, unknown versus zero price and residual tests; 480/760-point native renders |
| 4 | Independent Grok Bot provider using read-only Cursor auth; personal, no-grant, organization-managed, trial and unknown states. Only server-provided reset times; no invented On-demand dollar amount | Parser/request/cancellation/timeout/retry and old-reader cache fixtures; successful opt-in read-only live request, with no raw account data retained |

Price analysis reuses the cached LiteLLM table and existing matching rules; it starts no network request. It reports the table timestamp and matched model key. Historical/tiered/fast/custom pricing differences remain visible in the residual. Older cache records retain their unsplit cache-token label. Agents without per-model local history cannot provide a per-model breakdown; no data is fabricated.

Manual Claude web configuration replaces the default quota source explicitly, avoiding automatic fallback to a potentially different account. Only the sessionKey and optional organization UUID are stored in the app-owned, non-synchronizable Keychain after successful validation. Multiple eligible organizations require an explicit UUID. No browser storage is imported. Ordinary desktop/web/mobile chats do not provide local token logs; desktop login is not represented as a guarantee of Code OAuth renewal.

Grok Bot uses a distinct provider ID and does not reuse the Cursor or Grok CLI pool. Local quota/history caches place its data in additional top-level fields so older applications can still decode known providers. Existing mobile allowlists exclude it; the mobile wire schema is unchanged.

## Waiting and layout boundaries

DB-001: Cowork discovery has depth/entry limits and a five-second total budget; the helper retains its 30-second subprocess budget. Claude web requests have a 30-second total budget, 15-second request timeout and 25-second URLSession resource timeout. Grok Bot has a 25-second total budget including credential discovery and a 15-second request timeout. These are independent operation-specific choices, with no automatic retries.

Cancellation reaches the request/subprocess; operation identity and cancellation are checked before saving validated credentials or publishing results. Failed refreshes retain the previous timestamped quota; authoritative Grok Bot no-grant/organization states invalidate an obsolete personal percentage. Timeout does not imply expired credentials. Claude 403 challenges differ from expired sessions. Existing credential editor retry/cancel behavior is retained, including an error for invalid Cookie input with a supplied organization.

DB-002: Price cards use intrinsic height and four visible columns inside the existing page scroll. No nested scroll or extra disclosure state is introduced. Native acceptance creates only its own fixture window, uses long model labels and unknown prices, verifies exactly one NSScrollView, sends an AppKit wheel event, checks movement and resizes from 480 to 760 points. It never constructs UsageStore or accesses real configuration, credentials or history.

## Verification and limits

- macOS: full suite reports 698 Swift Testing tests across 102 suites and 16 XCTest tests with no failures. Three opt-in Keychain probes remain skipped. The live Grok and native-window tests are opt-in and were run separately successfully.
- SyncKit: 47 tests passed; shared wire format unchanged.
- Windows: 295 tests and production build passed. Generated translations come from macOS strings. Prior batch CI also passed native packaging/smoke tests on Windows x64 and ARM64.
- Keychain read contract and whitespace checks passed.
- An existing Alibaba cancellation test had a scheduling race in remote CI. The cancellation assertion now waits for transport entry with a bounded deadline and has its own timeout budget; the independent short-timeout assertion remains unchanged.
- Final review corrected the new Claude Traditional Chinese text and surfaced invalid form input through the existing store validator.

Real claude.ai Cookie login and full dashboard mouse/form workflows are not accepted by fixtures. Native UI control timed out twice; isolated AppKit scrolling/rendering provides narrower evidence. No production app was stopped, replaced or installed. API billing equivalence is not claimed. Grok Bot and claude.ai use undocumented endpoints and can change.

Reproduce fixture checks from the repository root with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel`. Native acceptance additionally sets `TOKENREMAIN_NATIVE_ACCEPTANCE=1` and filters `NativeRequirementsAcceptanceTests`. The separately authorized live probe requires `TOKENREMAIN_GROKBOT_READONLY_PROBE=1`; leave it disabled in routine tests. Windows uses `npm --prefix windows run check` with Node >=22.12.

The task used bounded 90-minute work batches and a 45-minute CI waiting budget per batch. Repeated unchanged failures are limited to three attempts. Task-owned temporary evidence includes detailed logs and fixture screenshots; no credentials or raw service responses are committed.
