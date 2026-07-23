# TokenRemain App Store submission draft

This is the canonical submission source. The English and Simplified Chinese
version metadata, public URLs, copyright, review contact, and review notes were
entered in App Store Connect on 2026-07-23. That does not prove build
processing, TestFlight validation, paid storefront behavior, or App Review
approval.

## Review notes

TokenRemain is a paid-upfront companion app for the separately distributed
TokenRemain Mac application. It has no account registration, Sign in with
Apple, subscription, in-app purchase, advertising, or Restore Purchases flow.
The App Store purchase is the installation gate.

The Mac is the only source of provider data. It reads provider state locally,
creates an allowlisted snapshot, encrypts it with AES-256-GCM, and writes it to
the user's CloudKit Private Database. Provider credentials, API keys, cookies,
account/email fields, prompts, projects, conversations, paths, and per-request
records are never synchronized. The iPhone is read-only. Widgets and Live
Activity read only an already validated App Group snapshot; Apple Watch receives
that snapshot through WatchConnectivity.

No login credentials are required for review. To inspect all layouts without a
Mac or provider account, open Settings, enable Demo Mode, and select a scenario.
Demo Mode is visibly labeled and never represents demo values as live data.
Disable Demo Mode to return to the honest not-connected state.

To test real sync, use a Developer ID TokenRemain Mac build configured for the
Production CloudKit container `iCloud.com.jamesli.tokenremain`, sign both devices
into the same iCloud account with iCloud Keychain enabled, enable Apple-device
sync on the Mac, then enable Mac sync in iPhone Settings. A different source Mac
requires explicit confirmation. Missing keys, decryption failure, stale data,
and sequence replay fail closed.

CloudKit silent notifications carry no quota data and notification permission
is not required for sync. The active iPhone app also performs a 45-second
foreground reconciliation. Locked, suspended, force-quit, offline, and
WidgetKit-controlled background states are not represented as fixed-latency
delivery.

## IAP review path

Not applicable. There is no IAP Product ID and no StoreKit paywall. Purchase and
re-download are the standard paid-app App Store flow.

## Encryption and content-rights notes

TokenRemain uses Apple CryptoKit AES-256-GCM to encrypt the private CloudKit
snapshot. The App Store Connect encryption questionnaire must be completed
truthfully before the build is submitted; no repository setting currently
claims an exemption on the Account Holder's behalf.

The optional AI Feed can display selected public X posts and links synchronized
from the user's Mac. Before submission, the publisher must confirm that this use
and the screenshots comply with the X API/content terms and complete App Store
Connect's third-party content-rights declaration. Review screenshots must not
imply endorsement by Anthropic, OpenAI, X, or another provider.

## App Privacy response worksheet

Current code has no developer analytics, ads, tracking, TokenRemain account, or
TokenRemain server receiving snapshots. The encrypted snapshot is stored in the
user's private iCloud database and the developer does not possess the
application-layer key. Under Apple's definition, data is “collected” only when
it is transmitted in a form accessible to the developer or an integrated
third-party partner beyond servicing the request. On that basis, the proposed
answer is **No, the developer does not collect data from this app**.

Before publishing that answer, verify the exported privacy report and confirm
that no new analytics, crash-reporting, support, or backend SDK has been added.
If any such path is added, update both the label and privacy policy before
submission. Apple-operated App Store, CloudKit, and opt-in diagnostics are not
misrepresented as developer-operated services.

Required Reason API declarations:

- main iPhone app: `UserDefaults` reasons `CA92.1` (app-private preferences) and
  `1C8F.1` (same-App-Group snapshot/routing state);
- Widget, Watch app, and Watch widget: `1C8F.1` only;
- tracking is declared false in every executable bundle manifest.

## Screenshot capture list

Use the current App Store Connect device-size slots and capture from a Release
candidate. Avoid status bars or fixture labels that imply a real account when
using demo data.

1. Overview with Claude's shortest 5-hour window and Codex's available 7-day
   window, visibly sourced from Mac sync or visibly labeled demo.
2. Overview customization with reordered cards and a provider expanded in
   place.
3. Limits page showing the multi-provider grid synchronized from the Mac.
4. Trends page with real aggregate bar charts and data-capture timestamp.
5. Widget gallery showing Home and Lock Screen variants.
6. Live Activity / Dynamic Island state with its freshness label.
7. Apple Watch glance and at least one complication / Smart Stack view.
8. Settings showing encrypted private sync, source Mac, freshness metrics, and
   disconnect/delete controls.

For the separately distributed Mac product page, capture:

1. full multi-provider dashboard with the shortest real provider windows;
2. menu bar panel and provider in-place expansion;
3. real daily history/trend bars and risk projection;
4. overview layout customization and drag ordering;
5. Apple-device sync status with capture/upload timing and privacy explanation;
6. data-source settings showing local-only credential handling and optional
   reminders.

Capture a separate clean set for each required iPhone display class and the
localized storefronts selected for launch. Watch screenshots should match the
actual embedded build, not a design mock.

## TestFlight and release-device matrix

- fresh TestFlight install opens without a paywall or login;
- honest empty state when no Mac snapshot exists;
- same-iCloud first connection and subsequent automatic refresh;
- reinstall receives current entitlement implicitly because there is no IAP;
- iCloud signed out and different-iCloud devices show actionable errors;
- App Store purchase account may differ from the iCloud sync account;
- Mac offline, iPhone offline, missing snapshot/key, corrupt AES data, replay,
  stale data, and main-Mac switch all fail closed;
- Widget, Live Activity, and Watch never invent data and respect hard expiry;
- foreground real-device p50/p95/max meet 60/120/180 seconds;
- notification permission is requested only after an alert feature is enabled;
- paid storefront purchase, cancellation, Ask to Buy, re-download, and refund
  behavior are verified separately from TestFlight because TestFlight does not
  prove paid-app checkout.

## App Store Connect state still requiring owner input

- English and Simplified Chinese support, marketing, and privacy-policy URLs
  are saved and return HTTP 200;
- support email `jamescarstin520@gmail.com` is published on the support and
  privacy pages;
- copyright `2026 Dongheng Li` and App Review contact Dongheng Li,
  `+1 2177786869`, `jamescarstin520@gmail.com` are saved;
- English subtitle `AI quota, always in view` and Simplified Chinese subtitle
  `AI 编码额度，随时掌握` are saved;
- primary category `Developer Tools`, secondary category `Productivity`, and
  the confirmed third-party content-rights declaration are saved;
- Paid Apps Agreement, banking, tax, education/business distribution, and
  Family Sharing confirmation;
- Digital Services Act identity/trader status;
- export-compliance determination for CryptoKit AES-256-GCM;
- App Privacy publication after the final processed build and privacy report
  are rechecked;
- screenshots, processed build selection, TestFlight validation, and final
  review submission.

A proposed English and Simplified Chinese listing is in
`docs/app-store-metadata-draft.md`.
