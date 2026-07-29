# TokenRemain Mac App Store Sandbox compatibility

Status: **Phase 1 complete; option B approved**

Audit date: 2026-07-23

Source baseline: `7e59c209a59750b4d2549614c0b113f651636bad`

Audit branch: `codex/storekit-sync-release`

Current website-edition note (2026-07-29): the shipping unsandboxed build now
also discovers Claude.app and ChatGPT.app/Codex.app, reads the official apps'
existing Keychain credentials, and exposes a user-initiated read-only Keychain
authorization button. The Claude CLI is an optional PTY fallback, not a
requirement. These changes do not alter the historical Sandbox audit results
below and have not been claimed as Mac App Store acceptance evidence.

## What was tested

`script/build_app_store_candidate.sh` builds one SwiftPM product and stages two
separate, ignored app bundles without replacing `/Users/jamesli/Applications/TokenRemain.app`:

- an Apple Development-signed, unsandboxed provider-audit baseline;
- an Apple Development-signed Mac App Store candidate with
  `com.apple.security.app-sandbox`, outbound network access, user-selected
  read-only files, and app-scoped bookmarks.

The candidate intentionally has no temporary home/absolute-path exception.
The machine has no macOS provisioning profile, so CloudKit, App Group, shared
Keychain, Mac App Distribution signing, and App Store receipt behavior are **not**
claimed by this audit. Those remain release gates.

The audit calls the production fetch implementation for every provider. Its
JSON output is limited to provider name, success/failure type, captured time,
and quota-window duration. It does not emit credentials, account identifiers,
payloads, file contents, or paths.

Commands used:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/build_app_store_candidate.sh audit
codesign -dvvv --entitlements :- "dist-app-store-candidate/TokenRemain App Store Candidate.app"
```

Evidence:

- The macOS suite passed 144 tests.
- Both staged bundles passed `codesign --verify --deep --strict`.
- The signed candidate contained all four candidate entitlements and no
  temporary path exception.
- macOS `secinitd` reported `AppSandbox request successful` for the candidate.

## Compatibility matrix

“Needs folder authorization” means the current automatic path was denied by
Sandbox and the source could be redesigned around an explicit `NSOpenPanel`
grant plus a security-scoped bookmark. That grant flow has not been implemented
or user-verified yet.

| Provider / capability | Current code path | Unsandboxed runtime | Sandbox runtime | Classification | App Review risk |
|---|---|---|---|---|---|
| Claude | `ClaudeCredentialsReader`: Claude config, then cross-app Keychain; explicit read authorization; optional `ClaudeCLIUsageProbe` fallback | Success, 5-hour window | Success, 5-hour window | Complete on this already-authorized Mac; website edition now has an explicit Keychain authorization path | **High**: cross-app Keychain access and optional CLI fallback remain unsuitable as fresh Sandbox proof |
| Codex | `CodexAuthReader`: compatible `auth.json`, then `Codex Auth` Keychain; local session JSONL fallback | Success, 7-day window | Failed as “not logged in” | Website edition supports explicit Keychain authorization; Sandbox behavior was not re-audited | **High**: hidden config/session and cross-app Keychain access; historical Sandbox failure remains |
| Cursor | `CursorAuthReader`: Cursor `state.vscdb`, then cross-app Keychain | Success, current billing window | Failed as “not logged in” | **Needs one-time folder authorization or OAuth/API path** | **High**: another app's database/Keychain item; current automatic path does not survive Sandbox |
| Copilot | `CopilotTokenReader`: editor/gh config, then gh Keychain; GitHub API | Credential and API worked; account exposes no personal quota | Same account-level “no personal quota” result | Complete on this already-authorized Mac | **Medium-high**: fresh-install access to another app's Keychain item is not proven |
| Devin | `DevinAuthReader`: credentials TOML or Devin `state.vscdb` through `sqlite3` | Not installed/logged in | Same unavailable result | **Needs folder authorization or API key** | **High**: another app's database plus external helper |
| Windsurf | `WindsurfAuthReader`: Windsurf `state.vscdb` through `sqlite3` | Not installed/logged in on the 2026-07-29 development Mac; parser and auth fixtures pass | Not re-audited | **Needs folder authorization or a provider-owned OAuth/API path** | **High**: another app's database plus external helper; no Sandbox runtime claim |
| Grok | `GrokAuthReader`: `~/.grok/auth.json`; remote API | Not logged in | Same unavailable result | **Needs folder authorization or OAuth/API key** | **Medium-high**: hidden credential file |
| OpenRouter | Environment/config file, then TokenRemain Keychain; remote API | API key not configured | Same unavailable result | **Needs API key**; own-Keychain storage is Sandbox-compatible | **Low-medium** |
| Antigravity | Preferred `AntigravityLocalUsageProbe`: process discovery + loopback RPC; fallback cross-app Keychain + remote API | Existing token was readable but stale; local app/server was not running | Same stale-token result | Preferred automatic loopback path is **not proven**; needs a supported OAuth/API-key path for release confidence | **High**: process inspection, localhost service discovery, and another app's Keychain item |
| OpenCode | Enumerates local `opencode*.db`, invokes `sqlite3 -readonly` | Local data directory found; no usage rows | Reported not installed | **Needs one-time folder authorization** | **High**: external databases/helper; automatic detection is lost |
| Z.ai | Environment/config file, then TokenRemain Keychain; remote API | API key not configured | Same unavailable result | **Needs API key**; own-Keychain storage is Sandbox-compatible | **Low-medium** |
| DeepSeek | `ProviderSecretStore` own Keychain; remote API | API key not configured | Same unavailable result | **Needs API key** | **Low-medium** |
| Kimi | `ProviderSecretStore` own Keychain; remote API | API key/Cookie not configured | Same unavailable result | **Needs API key or Cookie** | **Medium**: Cookie handling needs explicit privacy disclosure |
| MiniMax | `ProviderSecretStore` own Keychain; remote API | API key not configured | Same unavailable result | **Needs API key** | **Low-medium** |
| MiMo | `ProviderSecretStore` own Keychain; remote API | Cookie not configured | Same unavailable result | **Needs Cookie** | **Medium**: session Cookie handling needs explicit privacy disclosure |
| Qoder | `ProviderSecretStore` own Keychain; remote API | Cookie not configured | Same unavailable result | **Needs Cookie** | **Medium**: session Cookie handling needs explicit privacy disclosure |
| Kiro | Finds and launches `kiro-cli` | CLI not installed | Same unavailable result | **Sandbox-unavailable until separately proven**; likely requires a redesigned API path | **High**: arbitrary external CLI execution and inherited Sandbox limits |
| Volcengine | `ProviderSecretStore` own Keychain; signed remote API request | AK/SK not configured | Same unavailable result | **Needs API key pair** | **Low-medium** |
| Ollama | `ProviderSecretStore` own Keychain; authenticated settings request | Cookie not configured | Same unavailable result | **Needs Cookie** | **Medium**: session Cookie handling needs explicit privacy disclosure |
| Local history/trends (`ccusage`) | `CCUsageService`: bundled native ccusage helper in offline mode | Success in the website edition | Historical Sandbox helper process failed; not re-audited after native vendoring | **Sandbox-unavailable until re-audited with explicit log access** | **High**: a child helper still needs access to other apps' local logs |
| Trae Agent trajectories | `TraeAgentUsageService`: user-selected local JSON folders; allowlisted model/time/token decoding only | Parser and folder-store fixtures pass; Trae Agent is not installed on the development Mac | Not audited | **Explicit folder selection is already part of the UI, but a security-scoped bookmark would be required for a Sandbox build** | **Medium-high**: current website build persists paths, not Sandbox bookmarks; no Sandbox runtime claim |

## Decision-gate conclusion

The current full automatic experience cannot be shipped unchanged through the
Mac App Store. The runtime comparison proves regressions for Codex, Cursor,
OpenCode, and local history/trends. Antigravity's preferred process/loopback path
also remains unproven because Antigravity was installed but not running during
the audit. Claude and Copilot worked only on an already-authorized development
Mac; that is not fresh-install or App Review proof.

The runtime evidence triggered the planned product decision gate. The available
directions were:

- **A — Mac App Store only:** accept provider changes to OAuth/API key and
  explicit folder authorization, and replace shell/CLI-dependent history.
- **B — Private companion + Developer ID macOS download:** retain the current full
  automatic local integration on macOS; notarization replaces Mac App Store
  distribution.
- **C — Two macOS editions:** maintain a sandboxed Mac App Store edition with a
  reduced/redesigned provider set and a notarized website edition with the full
  local integration.

**Selected direction: B.** The shipping Mac app is the unsandboxed,
Developer ID-signed and notarized website edition. The Sandbox candidate remains
an isolated compatibility artifact and is not a release target. Consequently,
Codex, Cursor, OpenCode, local history/trends, and the other local integrations
keep their existing automatic paths in the website build; they are not being
redesigned around Sandbox folder grants for version 1.

No Provider credential was uploaded, no server architecture was introduced,
and the existing installed full app was not replaced.
