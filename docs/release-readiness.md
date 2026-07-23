# TokenRemain release readiness

Status date: 2026-07-23

This document separates repository work from Apple-controlled release proof.
The selected product is a paid-upfront iPhone App Store download plus a full,
unsandboxed Developer ID Mac download.

## Evidence status

| Item | Current status | What would advance it |
|---|---|---|
| Distribution model | Code and docs verified | No further product decision |
| macOS local feature set | Swift tests and unsandboxed runtime audit passed | Final signed build smoke test |
| iOS / watchOS | Simulator build and tests passed | Distribution-signed device archive and TestFlight |
| Privacy manifests | Added to every executable bundle source | Validate the exported App Store archive privacy report |
| StoreKit configuration | Not applicable | The app is paid upfront; there is no IAP product |
| StoreKit Sandbox purchase | Not applicable | Paid storefront checkout is outside the app and is not simulated by TestFlight |
| Developer ID package | G2-signed arm64 Production candidate notarized, stapled, and Gatekeeper-accepted | Download through the customer HTTPS path and complete the Mac acceptance matrix |
| CloudKit Production | Release entitlements are configured in code | Deploy schema, then test Production with release builds |
| APNs Production | Release build setting is configured in code | Verify the distribution-signed entitlement and silent push on TestFlight |
| Foreground freshness | Timing instrumentation and simulator paths pass | Collect real Mac + iPhone samples and meet p50/p95/max gates |
| App Store Connect | No mutation performed | Complete the account and app-record actions below |
| Review approval | Not submitted | Submit only after every blocking row below passes |

Historical Development-device evidence in the sync architecture document is
useful engineering evidence, but it does not replace a fresh Production,
TestFlight, paid-storefront, or notarized-release acceptance run.

## Local credential preflight

Observed on the release workstation on 2026-07-23:

- one valid `Apple Development` identity;
- one preferred G2 `Developer ID Application: Dongheng Li (84397AQ22Y)`
  identity, with its private key available locally and certificate expiry on
  2031-07-24;
- one legacy G1 Developer ID identity with the same common name and certificate
  expiry on 2027-02-01; it is retained but must not sign release artifacts;
- one valid `Apple Distribution: Dongheng Li (84397AQ22Y)` identity, with its
  private key available locally and certificate expiry on 2027-07-23;
- development provisioning profiles exist for the iPhone, iPhone Widget,
  Watch app, and Watch Widget identifiers;
- Apple-issued Developer ID profile
  `TokenRemain macOS Developer ID Production` exists for
  `com.jamesli.usagedock`, authorizes CloudKit Production and
  `84397AQ22Y.*` Keychain groups, embeds the G2 certificate, applies to all
  devices, and expires on 2044-07-18;
- no App Store distribution profiles were found;
- the `tokenremain-notary` notarytool credential profile is stored in the
  login Keychain; its secret is not stored in this repository.

A G2 Developer ID-signed candidate was built on 2026-07-23 with Hardened
Runtime, a secure timestamp, the Production CloudKit container, and the exact
`84397AQ22Y.com.jamesli.tokenremain.sync` Keychain group. Its signature and
embedded profile passed strict local verification. Apple notarization submission
`18a55f70-b6da-4494-a4b3-1ce47d44d92f` was accepted with status code `0`,
summary `Ready for distribution`, and no issues. The ticket was stapled and
validated, and Gatekeeper accepted the app with source
`Notarized Developer ID`.

The final stapled arm64 ZIP is
`dist-release/1.0.0-1/TokenRemain-1.0.0-1-macOS.zip`, with SHA-256
`bc4662ab8fb870dff1532517f8f3363f5eb3771a9de5f9e34df4ab58d8febb2f`.
This is local packaging and Apple notarization evidence. It has **not** yet been
downloaded through the customer HTTPS path, smoke-tested as a clean customer
install, uploaded to App Store Connect, or installed through TestFlight. Intel
or Universal Binary support has not been claimed or verified.

## Developer ID Mac release

### Apple account prerequisites

1. Create or install a `Developer ID Application` certificate for Team
   `84397AQ22Y`.
2. Confirm the macOS App ID `com.jamesli.usagedock` has iCloud/CloudKit access
   to `iCloud.com.jamesli.tokenremain` and the Keychain group
   `84397AQ22Y.com.jamesli.tokenremain.sync`.
3. Generate and download the Apple-issued Developer ID provisioning profile
   for that App ID and capability set.
4. Store notarytool credentials in Keychain under a chosen profile name; never
   put the app-specific password or API private key in this repository.

### Build and notarize

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export USAGEDOCK_SYNC_PROVISIONING_PROFILE=/absolute/path/TokenRemain.provisionprofile
export USAGEDOCK_SYNC_SIGNING_IDENTITY='0F00E922CD02FB10B8EA41E03CCA65B38BC5DB5B'
export TOKENREMAIN_NOTARYTOOL_PROFILE='tokenremain-notary'

./script/package_developer_id_release.sh notarize
```

The script refuses a non-Production CloudKit environment, a missing Developer
ID identity, `get-task-allow`, App Sandbox, a wrong CloudKit container, or a
wrong sync Keychain group. It submits a ZIP with `notarytool`, waits for the
Apple result, staples the app, validates the ticket, runs Gatekeeper assessment,
and recreates the final ZIP around the stapled app.

### Mac acceptance

- Download the final ZIP through the same HTTPS path customers will use.
- Confirm Gatekeeper opens it without Developer Mode or certificate trust.
- Confirm `codesign --verify --deep --strict` and `spctl --assess` pass.
- Confirm all local providers still auto-refresh, including Claude, Codex,
  Cursor, Antigravity, and OpenCode.
- Confirm local dashboard, menu bar, history, trends, prediction, feed,
  customization, notifications, and launch at login remain free.
- Enable sync and confirm the Production private zone receives only the
  allowlisted encrypted record.

## CloudKit Development to Production

Deployment is an explicit external action and has not been performed by this
branch.

1. Export or record the Development schema for container
   `iCloud.com.jamesli.tokenremain`.
2. Verify the custom zone, record type, field types, encrypted field status,
   and required query indexes match the code contract.
3. Confirm no credential, account, email, prompt, project, conversation,
   request-level, path, token, or API-key field exists.
4. Deploy the schema to Production in CloudKit Console.
5. Verify the Production schema is queryable by distribution-signed iPhone and
   Developer ID Mac builds using the same iCloud account.
6. Exercise deletion, missing key, corrupt ciphertext, replay, stale data, and
   main-Mac takeover before release.
7. Record the deployment date and schema version in the release evidence.

## iOS, extensions, Watch, and APNs

Before upload, archive the Release configuration and inspect every embedded
target:

- iPhone main app: Production CloudKit, production APNs, App Group, and the
  synchronizable sync-key access group;
- Widget and Live Activity extension: App Group only, with no CloudKit or sync
  Keychain entitlement;
- Watch app and Watch widget: App Group only; snapshots arrive through the
  containing app / WatchConnectivity path;
- no target contains `get-task-allow` in the distribution archive;
- every executable bundle contains a valid `PrivacyInfo.xcprivacy`.

CloudKit subscription pushes remain change hints only. They must not contain
quota values, provider details, costs, or credentials, and notification
authorization is not a prerequisite for sync.

### Encryption export compliance

The iPhone app deliberately uses CryptoKit AES-256-GCM in addition to Apple
CloudKit/TLS protection. Do not answer “the app uses no encryption.” Before the
first upload, use App Store Connect's App Encryption Documentation questionnaire
to determine the applicable exemption and any storefront-specific paperwork.
Apple's current reference says encryption limited to the Apple operating system
does not require documentation, but the Account Holder remains responsible for
the submitted determination. Only after App Store Connect confirms the result
should `ITSAppUsesNonExemptEncryption` (and, if provided by Apple,
`ITSEncryptionExportComplianceCode`) be fixed in the Release Info.plist.

This branch intentionally leaves those keys unset so it cannot silently claim
an unconfirmed legal exemption.

## Paid-upfront commercial state matrix

The App Store is the install gate; the app contains no IAP entitlement state.

| Original IAP scenario | Paid-upfront behavior to verify |
|---|---|
| Fresh install, not purchased | Customer completes App Store checkout before installation; TestFlight bypasses this storefront proof |
| Purchased, first connection | App opens without a paywall and can connect to the Mac snapshot |
| Purchased user reinstalls | Re-download is handled by the App Store |
| Restore Purchases | Not applicable; there is no Restore button or `AppStore.sync()` |
| Pending / Ask to Buy | Checkout remains in the App Store; the production app is not installed until Apple completes it |
| Purchase cancelled | App is not installed through that checkout |
| Refund / revocation | Version 1 does not remotely lock an already installed copy; no Mac local data is removed |

The remaining sync and failure scenarios still require real-device coverage:
iCloud signed out, different iCloud accounts, App Store account different from
iCloud account, either device offline, no CloudKit snapshot, missing sync key,
AES failure, replay, main-Mac switch, stale provider data, and honest empty
Widget/Watch rendering.

The evidence mapping for every required commercial and sync state is maintained
in `docs/commercial-sync-test-matrix.md`.

## Foreground latency acceptance

Use the in-app timing store on a real iPhone while the Mac is online and the
iPhone app remains active. Collect enough observations to avoid a one-sample
claim and export the aggregate release evidence without quota values or user
content.

- p50 no more than 60 seconds;
- p95 no more than 120 seconds;
- maximum accepted observation no more than 180 seconds.

Do not apply this SLA to a locked/suspended phone, WidgetKit background refresh,
a force-quit app, low-power restrictions, missing network, or provider failure.

## App Store Connect blocking actions

These require the Account Holder, Admin, App Manager, or a signed-in Xcode
session and are intentionally not automated here:

1. Accept the current Paid Apps Agreement and complete banking and tax status.
2. Confirm the App Store record uses `com.jamesli.tokenremain`.
3. Choose the base country/region, final price, storefronts, tax category,
   education/business availability, and Family Sharing policy if offered.
4. Publish a public privacy-policy URL and enter the App Privacy answers.
5. Complete age rating, category, copyright, support URL, marketing URL,
   export compliance, third-party content-rights confirmation, and release method.
6. Create/upload the distribution archive, wait for processing, and resolve all
   entitlement or privacy-manifest warnings.
7. Run internal and external TestFlight on real iPhone and paired Watch.
8. Attach the final screenshots and review notes, then submit for review.

Draft listing copy is available in `docs/app-store-metadata-draft.md`; it is not
an App Store Connect mutation or owner approval.
