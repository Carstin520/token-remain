# TokenRemain release readiness

Status date: 2026-07-25

This document separates repository work from Apple-controlled release proof.
The selected product is a paid-upfront iPhone App Store download plus a full,
unsandboxed Developer ID Mac download.

## Evidence status

| Item | Current status | What would advance it |
|---|---|---|
| Distribution model | Code and docs verified | No further product decision |
| macOS local feature set | Swift tests and unsandboxed runtime audit passed | Final signed build smoke test |
| iOS / watchOS | Current HEAD `10754b6` Release archive and Apple Distribution export passed for all four executable bundles | App Store Connect processing and TestFlight device validation |
| Privacy manifests | Present and plist-valid in all four exported executable bundles | Validate App Store Connect's processed privacy report |
| StoreKit configuration | Not applicable | The app is paid upfront; there is no IAP product |
| StoreKit Sandbox purchase | Not applicable | Paid storefront checkout is outside the app and is not simulated by TestFlight |
| Developer ID package | v1.1.4 build 6 is G2-signed with Production CloudKit/APNs entitlements and Sparkle; its App and signed DMG are notarized, stapled, and Gatekeeper-accepted | Publish the exact DMG, ZIP, and signed appcast; then download them through the public customer URLs and byte-verify the results |
| CloudKit Production | The reviewed `TRCurrentSnapshot` schema is deployed. A Production private-zone `RecordSave` from the installed Developer ID app succeeded at 2026-07-24 06:39:44 UTC (1 record, 7,026 bytes) | Complete the same-account Production receive test with the App Store/TestFlight iPhone build |
| APNs Production | The public macOS build carries `aps-environment=production`; the APNs token credential and broadcast Worker have passed production authentication checks | Regenerate APNs-enabled iOS distribution profiles and verify delivery through TestFlight |
| Foreground freshness | Timing instrumentation and simulator paths pass | Collect real Mac + iPhone samples and meet p50/p95/max gates |
| App Store Connect | App record, pricing, storefronts, metadata, content rights, age rating, privacy draft, review notes, and manual release are configured as recorded below | Supply public URLs/contact/legal details, publish privacy, upload/process a build, and complete account compliance |
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
- App Store distribution profiles exist for the iPhone, iPhone Widget, Watch
  app, and Watch Widget identifiers; all four embed the current Apple
  Distribution certificate, disable `get-task-allow`, and authorize the shared
  App Group;
- Apple-issued Developer ID profile
  `TokenRemain macOS Developer ID Production APNs` exists for
  `com.jamesli.usagedock`, authorizes CloudKit Production and
  `84397AQ22Y.*` Keychain groups plus APNs Production, embeds the G2
  certificate, applies to all devices, and expires on 2044-07-18;
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

After the automatic-sync and bounded-process updates, HEAD `10754b6` was also
rebuilt as a separate, non-notarized Developer ID candidate at
`dist-release/head-10754b6/TokenRemain-1.0.0-1-macOS.zip`, with SHA-256
`0f6d694a4a4a82b776e4876109638b0aa4051d6dc928d0ed0196dc4452b095a5`.
Strict signature validation passed. The bundle is arm64, uses Hardened Runtime
and a secure timestamp, carries CloudKit `Production`, and contains only the
exact sync Keychain group. This newer candidate is local signing evidence, not
notarization or customer-download proof.

Commit `f223643` was rebuilt after enabling Push Notifications for
`com.jamesli.usagedock`. Apple accepted App submission
`8c94259f-e14a-4124-8732-955f588a842e` and DMG submission
`e89e99f3-db8e-4c10-a5ca-26240e2d2404`. Both artifacts were stapled and
accepted by Gatekeeper as `Notarized Developer ID`. The final arm64 DMG is
published as GitHub Release asset `TokenRemain.dmg`, is 10,403,721 bytes, and
has SHA-256
`92832512abb02ef1daf7b93394872cf56c438b0b375cd13d096b29f162e4bb9f`.
A fresh HTTPS download of that public asset matched the byte count and digest.

The v1.1.0 build 2 candidate was built from commit `3deacee`. Apple accepted
App submission `121769e2-c1d0-4c66-b380-70395c27b672` and the final signed DMG
submission `aff4cd7b-54c2-402a-bbef-0b0de61d50cd`. Both artifacts are stapled
and accepted by Gatekeeper as `Notarized Developer ID`. Before publication,
the 10,403,808-byte `TokenRemain.dmg` has SHA-256
`ff04f571dc5fbb2f1e73a7eaade60e1a729a4658f2d0902e47b5f8f67a3bc7b9`;
the 9,843,148-byte stapled ZIP has SHA-256
`e7de05d5a1a97bff63935e983873b0ef05b5dd010f785ea0c19661ec25f76589`.

The v1.1.1 build 3 candidate adds the production-only Sparkle 2.9.4 updater.
Apple accepted App submission `9aa6f6ce-058a-4a07-9db2-3fd7c54457a5` and
signed DMG submission `06cf4bb6-6af9-454c-a746-32c7b60e93e8`. The updater
framework and helpers are re-signed individually with the G2 Developer ID
identity, the appcast and update archive carry Sparkle EdDSA signatures, and
both the App and DMG are stapled and Gatekeeper-accepted. Before publication,
the 11,476,373-byte `TokenRemain.dmg` has SHA-256
`935e5d745530cdb55a31fb1ebfa87aac50952b5690bf3cc63ddfcc510cbb85c9`;
the 10,909,988-byte ZIP has SHA-256
`8251f154b74d54f6e2fc5a53bd0067e2fa12a0b6564d981111dec75b5c2f1bd1`;
and the signed `appcast.xml` has SHA-256
`9a50b0f2549e430112b24f66c324f50c1d203a644130fd68ad2257c1111f4b1d`.

The v1.1.2 build 4 candidate isolates slow provider and ccusage work from the
minute-level quota refresh path. Apple accepted App submission
`363eb532-6676-4b4d-bdb0-36cd147536b9` and signed DMG submission
`7bf1539c-27a6-4b32-84c8-b206d188edbc`. Both the App and DMG are stapled and
Gatekeeper-accepted. Before publication, the 11,486,035-byte
`TokenRemain.dmg` has SHA-256
`1c867ddce19991dc22fe6796e62ee4ab78dcee80e40d358a8153de9790e11a4b`;
the 10,915,604-byte ZIP has SHA-256
`086a774a44459751dfbb2bae33bc22dc6bf91d48056ed6c8cc604b7c148ea669`;
and the signed `appcast.xml` has SHA-256
`910a3a3e708f93659d1554c5e55baa05cfc969bbe144b8474a18b9a6cecc6c79`.

The v1.1.4 build 6 candidate adds consistent popular-post ranking across Mac,
iPhone, and broadcast delivery; simplifies iPhone sync diagnostics; improves
reset and snapshot freshness labels; and prevents background Keychain prompts.
Apple accepted App submission `02ec5422-7cf4-4049-bbbe-f47009562aef` and
signed DMG submission `c1f06886-4123-4de5-a24e-c9c3b866605e`. Both the App
and DMG are stapled and Gatekeeper-accepted. Before publication, the
15,084,359-byte `TokenRemain.dmg` has SHA-256
`32a55a469d962e4fb7c628a7931347f8257f44902853aa7959d9973548764bdc`;
the 12,666,104-byte ZIP has SHA-256
`c29c52f48aeb123e60ade37c3791c46e4747837cbc0b91a32b5aea2095429394`;
and the signed `appcast.xml` has SHA-256
`550e8767211b9bfbf79beaa81aa692560d76763dff3fdafe5283fa78a6285a17`.

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

## App Store distribution export

The four Apple-issued App Store profiles were installed and validated on
2026-07-23:

- `TokenRemain iOS App Store` →
  `com.jamesli.tokenremain`;
- `TokenRemain Widgets App Store` →
  `com.jamesli.tokenremain.widgets`;
- `TokenRemain Watch Main App Store` →
  `com.jamesli.tokenremain.watchkitapp`;
- `TokenRemain Watch App Store` →
  `com.jamesli.tokenremain.watchkitapp.widgets`.

The last profile's display name is historical; its signed application
identifier proves that it belongs to the Watch Widget extension.

A Release archive built all four targets successfully. Xcode then exported the
archive with manual App Store Connect distribution settings, the installed
Apple Distribution certificate, CloudKit `Production`, and the four exact
profiles above. The iOS app and its Widget are explicitly iPhone-only, matching
the selected product scope and eliminating the invalid iPad orientation
assumption. The exported IPA passed deep signature validation. Its signed
entitlements prove:

- the main iPhone app has production APNs, CloudKit `Production`,
  `iCloud.com.jamesli.tokenremain`, the shared App Group, and only the exact
  `84397AQ22Y.com.jamesli.tokenremain.sync` sync Keychain group;
- the iPhone Widget, Watch app, and Watch Widget have the shared App Group but
  no APNs, CloudKit, or Keychain entitlement;
- all four bundles disable `get-task-allow`, use Team `84397AQ22Y`, and include
  a plist-valid `PrivacyInfo.xcprivacy`.

The local export is
`dist-release/ios/1.0-1/AppStore/TokenRemain.ipa`, with SHA-256
`6eeafcd5227152bebcff371d3ac2af5752c964f1e1bb964511b857e433b7454e`.
This proves local Archive and App Store distribution export only. It has
**not** been uploaded to or processed by App Store Connect, installed through
TestFlight, or tested against the paid storefront.

HEAD `10754b6` was subsequently archived and exported into the separate path
`dist-release/ios/head-10754b6/AppStore/TokenRemain.ipa`, with SHA-256
`0ab83d33d6da16599aaeaf572ae930e8518e4d12f7634ac4e910028641a3841b`.
The same four-bundle signature, profile, privacy-manifest, APNs, CloudKit,
App Group, Keychain, and `get-task-allow` checks passed. This is the current
local App Store export; it has not been uploaded or processed by App Store
Connect.

For repeatable profile preflight, Archive, export, and product-level entitlement
verification, use:

```bash
export TOKENREMAIN_APPLE_DISTRIBUTION_IDENTITY='B31821150459350B621C377ED9469A567AAE3098'
export TOKENREMAIN_IOS_PROFILE=/absolute/path/TokenRemain_iOS_App_Store.mobileprovision
export TOKENREMAIN_WIDGETS_PROFILE=/absolute/path/TokenRemain_Widgets_App_Store.mobileprovision
export TOKENREMAIN_WATCH_PROFILE=/absolute/path/TokenRemain_Watch_Main_App_Store.mobileprovision
export TOKENREMAIN_WATCH_WIDGETS_PROFILE=/absolute/path/TokenRemain_Watch_App_Store.mobileprovision

./script/package_app_store_release.sh all
```

The script does not upload the IPA. Upload remains a separately authorized App
Store Connect action.

## CloudKit Development to Production

Deployment is an explicit external action and has not been performed by this
branch.

### 2026-07-23 schema preflight

Before any deployment, CloudKit Console showed that Production contained only
the system `Users` record type. The Development-to-Production preview proposed
creating `TRCurrentSnapshot` with these application fields:

- `encryptedEnvelope` as `ENCRYPTED BYTES`;
- `envelopeVersion` as `INT64`;
- `generatedAt` as `TIMESTAMP`;
- `keyID`, `sequence`, and `sourceInstanceID` as `STRING`.

This matches the fixed-ID, private-database codec. No credential, account,
email, prompt, project, conversation, request-level, path, token, or API-key
field appeared in the preview.

CloudKit's initially inferred public-database grants for
`TRCurrentSnapshot` were removed from `_world`, `_icloud`, and `_creator`.
All 13 automatically inferred query/search/sort indexes were also removed
because the shipping code fetches the single `current-v1` record by ID and
performs no `CKQuery`.

After Apple restored console access, each application field was rechecked in
Development and showed `None` under Single Field Indexes. The default roles
were also rechecked: `_world` and `_creator` contained only the system `Users`
type, while `_icloud` had no assigned record types.

The final deployment preview compared Production version
`0567a9b0-8688-11f1-bcb8-87342b1e7c53` with Development version
`c83e5900-869e-11f1-a5b0-cbb8b212d0c7`. It proposed:

- `Record Types (1)`: create `TRCurrentSnapshot`;
- `Indexes (0)`;
- `Security Roles (0)`.

The schema diff contained only the six system metadata fields and the six
application fields listed above. It contained no index attributes and no
`GRANT` clause for `TRCurrentSnapshot`; the existing `Users` definition was
unchanged. The preview was cancelled. Production was not changed and the
Deploy button was never used.

1. Obtain explicit owner confirmation for the reviewed Production deployment.
2. Deploy the exact reviewed schema to Production in CloudKit Console.
3. Verify the Production schema is accessible to distribution-signed iPhone and
   Developer ID Mac builds using the same iCloud account.
4. Exercise deletion, missing key, corrupt ciphertext, replay, stale data, and
   main-Mac takeover before release.
5. Record the deployment date and schema version in the release evidence.

## Current HEAD local verification

The following checks passed on `10754b6` with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- root Swift package: 150 tests in 31 suites;
- `apple/Packages/TokenRemainKit`: 94 tests in 19 suites;
- release-configuration and automatic-sync contract scripts;
- existing notarized Developer ID artifact validation and Gatekeeper
  assessment;
- `xcodegen generate`;
- iOS Simulator build;
- watchOS Simulator build;
- current-HEAD Apple Distribution archive/export verification;
- current-HEAD Developer ID signing, Hardened Runtime, timestamp, Production
  CloudKit, and Keychain entitlement verification.

These results are code, simulator, local export, and local signing evidence.
They are not CloudKit Production deployment, current-HEAD notarization,
App Store Connect processing, TestFlight installation, paid-storefront
checkout, or App Review approval.

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

The signed-in App Store Connect session established the following state on
2026-07-23:

- App Store Apple ID `6793884338`, SKU `tokenremain-ios-2026`, version `1.0`,
  and bundle ID `com.jamesli.tokenremain`;
- a paid-upfront price schedule across all 175 storefronts; the owner confirmed
  United States `US$3.99` as the base price;
- all 175 storefronts selected, including China mainland, which currently
  reports `Available on App Release` rather than an ICP error;
- primary category `Developer Tools`, secondary category `Productivity`, and
  content rights declared for the selected third-party provider/X content;
- English subtitle `AI quota, always in view` and Simplified Chinese subtitle
  `AI 编码额度，随时掌握` saved;
- current age questionnaire result: `13+` in 171 storefronts, `16+` in two
  storefronts, and `15+` in Korea;
- English promotional text, description, and keywords saved;
- Simplified Chinese promotional text, description, and keywords saved;
- review notes saved, `Sign-in required` disabled, and
  `Manually release this version` selected;
- App Privacy is currently saved as `Data Not Collected` but not published.
  It must be re-evaluated before submission because optional public-feed
  notifications now register an APNs device token and operational locale/time
  zone with the broadcast service. The app still contains no ads or behavioral
  analytics SDK.
- public product, support, and privacy-policy pages deployed at
  `https://tokenremain.com`, with English and
  Simplified Chinese URLs saved in App Store Connect; the public Mac button
  resolves through an aggregate-only D1 counter to the notarized GitHub Release
  DMG.
- copyright `2026 Dongheng Li` and App Review contact Dongheng Li,
  `+1 2177786869`, `jamescarstin520@gmail.com` saved.

These remaining actions still require owner input, an explicit external action,
or stronger release evidence:

1. Verify the current Paid Apps Agreement, banking, tax, education/business
   distribution, and Family Sharing state.
2. Complete Digital Services Act trader/non-trader identity verification.
3. Publish the App Privacy response only after its public policy URL is entered
   and the processed build is rechecked for SDK/privacy changes.
4. Complete the App Store export-compliance determination for CryptoKit
   AES-256-GCM, then set the matching Info.plist key and rebuild.
5. Upload the distribution archive, wait for processing, and resolve all
   entitlement, export-compliance, or privacy-manifest warnings.
6. Capture and upload the final iPhone and Apple Watch screenshots.
7. Run internal and external TestFlight on a real iPhone and paired Watch.
8. Deploy and verify the CloudKit Production schema only after explicit owner
   approval.
9. Attach the final build and evidence to the prepared version, then stop for
    owner confirmation before `Add for Review`.

The listing source remains in `docs/app-store-metadata-draft.md`. The status
above records actual App Store Connect state; it is not evidence of build
processing, TestFlight validation, paid-storefront checkout, or review
approval.
