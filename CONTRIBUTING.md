# Contributing to TokenRemain

Thanks for helping! Issues and pull requests are welcome in English or Chinese (中文 issue / PR 同样欢迎).

- **Bug or idea?** [Open an issue](https://github.com/Carstin520/token-remain/issues) with your TokenRemain version, macOS version, the affected provider, the exact visible message, and steps to reproduce.
- **Security problem?** Don't open a public issue — follow [SECURITY.md](SECURITY.md).
- **Never paste secrets.** Tokens, API keys, cookies, auth files and unredacted API responses must not appear in issues, screenshots, fixtures or commits.

## Development setup

You need macOS 14+, full Xcode (Command Line Tools alone lack XCTest) and an Apple Development signing certificate in your Keychain — signing into Xcode with a free Apple ID creates one. The stable signature lets macOS remember Keychain approvals across rebuilds.

```bash
bash ./script/build_and_run.sh
```

This builds and installs a separate **TokenRemain Dev.app** (bundle ID `com.jamesli.usagedock.dev`) into `~/Applications` — override the location with `USAGEDOCK_INSTALL_DIR`. It never replaces an installed release copy. `UsageDock` is the project's internal code name.

| Mode | What it does |
| :-- | :-- |
| *(none)* | Build, install and open the Dev app |
| `--verify` | Same, then confirm the process stays running |
| `--logs` | Open the app and stream its process logs |
| `--debug` | Launch the installed app under `lldb` |

Note that every mode stops the running Dev app, rebuilds and reinstalls it.

## Tests

| Area | Command |
| :-- | :-- |
| macOS app | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` |
| Sync protocol | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/TokenRemainSyncKit` |
| Broadcast worker | `cd broadcast && npm ci && npm run typecheck && npm test` |
| Windows adapter | `cd windows && npm ci && npm test` |

Contract scripts in `script/verify_*.sh` enforce product guarantees (for example, `verify_keychain_read_contract.sh` fails if code reads the Keychain outside the controlled entry point). Read a script before running it: `verify_release_configuration.sh` updates the bundled ccusage, and release scripts touch signing and packaging.

## Repository layout

| Path | Contents |
| :-- | :-- |
| `Sources/UsageDock/`, `Package.swift` | SwiftPM menu bar app (SwiftUI + AppKit) |
| `Tests/UsageDockTests/` | macOS app tests |
| `Packages/TokenRemainSyncKit/` | Encrypted cross-device sync protocol |
| `broadcast/` | Cloudflare Workers backend for AI Feed and download counts ([README](broadcast/README.md)) |
| `windows/` | Electron-based Windows adapter, in development ([README](windows/README.md)) |
| `site/` | Website, privacy policy and support pages |
| `script/` | Build, packaging and contract-verification scripts |
| `docs/` | Versioning, privacy, feed contract and performance notes |
| `design/` | Brand, palette and UI sources |

The iPhone and Apple Watch clients are maintained separately and are not in this repository.

## Ground rules for changes

These protect users' credentials and data; PRs that break them won't be merged. Maintainers and coding agents follow the fuller version in [AGENTS.md](AGENTS.md).

1. **Third-party credentials are read-only.** Never refresh, rewrite, migrate or delete another tool's tokens, and never trigger a sign-in automatically. Keychain reads go through `Sources/UsageDock/Support/KeychainRead.swift`; background reads must stay non-interactive.
2. **Sync stays private and compatible.** Only allowlisted, redacted fields cross `MobileSnapshotRedactor`. Changing a wire format, cache or preference format needs a migration plan for already-shipped clients.
3. **Behavior contracts don't change silently.** Quota percentages and units, pools, account ownership, error categories, cache freshness and refresh intervals are product semantics — a refactor or performance change must keep them identical unless changing them is the stated goal.
4. **No telemetry, no analytics SDKs, no new network destinations** without a matching update to the README's privacy section and the privacy policy.
5. **Keep the diff focused.** No repo-wide reformatting, dependency upgrades or drive-by cleanups. Don't delete regression tests or loosen assertions to make a change pass.
6. **Localize every user-facing string** in all `Sources/UsageDock/Localization/*.lproj` files. Windows locales are generated from the macOS `.strings` files — regenerate them instead of editing the output.

## Pull requests

- Branch from `main` and open the PR against `main`.
- Use [Conventional Commits](https://www.conventionalcommits.org/) with a scope, as in the existing history: `fix(claude): …`, `feat(windows): …`, `docs(readme): …`.
- Describe what changed, why, and how you verified it (the tests you ran and, for UI changes, before/after screenshots with personal data removed).
- Add user-visible changes to [CHANGELOG.md](CHANGELOG.md) under an `Unreleased` heading at the top (create it if it isn't there).

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE). The TokenRemain name, logos and original design assets remain excluded, as described in [ASSET-LICENSE.md](ASSET-LICENSE.md).
