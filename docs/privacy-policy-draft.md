# TokenRemain Privacy Policy — release draft

> Publication blockers: replace the effective date, publisher name, support
> email, and public URL before using this text. Legal review may be appropriate
> for the selected storefronts. This draft describes the current code and is
> not a claim that an App Store privacy form has already been submitted.

Effective date: `[DATE]`

Publisher: `[LEGAL NAME]`

Contact: `[SUPPORT EMAIL]`

## Summary

TokenRemain is a local-first quota viewer. The Mac app reads selected AI coding
tools and provider services on the Mac. The iPhone, widgets, Live Activity, and
Apple Watch display a privacy-filtered snapshot that the user may choose to
sync through their own iCloud account. TokenRemain does not require a
TokenRemain account, does not use advertising, and does not track users across
apps or websites.

## Data processed on the Mac

Depending on the providers the user enables, the Mac app may read local
configuration files, local databases, command-line output, localhost services,
or credentials already stored by those tools. It may also send authenticated
requests directly to the selected provider's service to retrieve quota or
usage information. Provider credentials can include access tokens, API keys,
cookies, or account sessions.

These credentials remain on the Mac. TokenRemain does not upload them to
iCloud or to a TokenRemain-operated server, does not refresh third-party OAuth
tokens on behalf of the provider tool, and does not upload prompts, projects,
conversations, or request-level history.

The Mac stores settings, quota cache, aggregate history, and optional feed data
locally so the product can render dashboards, trends, alerts, and offline
states. Users can stop tracking a provider or remove its TokenRemain-managed
secret from the app.

## Apple-device sync

Sync is optional and uses the user's CloudKit Private Database. Before upload,
the Mac reduces data to an allowlisted snapshot and encrypts it with
AES-256-GCM. The encryption key is stored in a dedicated synchronizable iCloud
Keychain access group available only to the TokenRemain Mac and iPhone main
apps.

The default snapshot may contain:

- stable provider identifiers;
- quota-window percentages, reset dates, capture times, and availability
  states;
- sanitized provider subscription-tier labels used only for display;
- source/version/sequence metadata used to reject replay and wrong-source
  updates;
- if separately enabled, up to 30 days of aggregate Claude and Codex token and
  estimated-cost history;
- up to three selected public feed posts with display text and public links.

It never contains provider credentials, API keys, cookies, account names,
email addresses, prompts, project names or paths, conversations, or individual
request records. CloudKit notification payloads indicate only that a record may
have changed; they do not carry quota details.

The iPhone validates and decrypts a snapshot before writing a reduced display
snapshot to the App Group used by widgets and Live Activity. Apple Watch data
is delivered from the iPhone through WatchConnectivity. These extensions do
not receive CloudKit or sync-key access.

## Freshness diagnostics

The iPhone privately stores up to 240 synchronization timing observations to
measure foreground freshness. An observation contains a stable provider slug
and four timestamps: provider capture, Mac upload, phone receipt, and phone
render. It contains no quota value, credential, account identifier, or content,
and is not uploaded to CloudKit, an App Group, or a TokenRemain server.

## Notifications

Sync does not require notification permission. The Mac asks for local
notification permission only when the user enables an alerting feature.
CloudKit silent notifications are system delivery hints and do not display
provider data in a notification banner.

## Purchases

The iPhone app is purchased and downloaded through the App Store. TokenRemain
does not receive payment-card details. App Store purchase and re-download
records are handled by Apple under Apple's terms and privacy policy. The app
contains no subscription, advertising SDK, or in-app purchase product.

## Analytics, tracking, and third-party SDKs

TokenRemain does not include a developer-operated analytics or advertising
SDK, does not sell user data, and does not combine TokenRemain data with data
from other companies for advertising. Apple may provide aggregated App Store
and opt-in diagnostic reports to developers under Apple's privacy terms.

Provider requests are governed by the privacy policy of the provider selected
by the user. The Mac app sends only what is required to authenticate and obtain
that provider's quota response.

## Retention and deletion

Local caches and settings remain until the user removes them or the operating
system clears eligible cache data. Cloud sync keeps the current encrypted
snapshot and limited operational metadata in the app's private CloudKit zone.
The user can disconnect sync and delete TokenRemain's private CloudKit zone and
dedicated sync key without deleting provider credentials or Mac-local quota
history.

If iCloud Keychain encrypted data is reset, prior synchronized records may no
longer be decryptable. The Mac-local data remains the source of truth and can
produce a new snapshot after the user reconnects.

## Security

TokenRemain uses platform code signing, Keychain storage, CloudKit Private
Database controls, application-layer authenticated encryption, schema and
range validation, expiry checks, and source/sequence replay protection. No
system can eliminate every risk, particularly on an unlocked or compromised
device.

## Children's privacy and international use

TokenRemain is not directed to children and does not knowingly request contact,
location, health, or advertising-identifier data. Users are responsible for
complying with provider terms and applicable laws in their region.

## Changes and contact

Material changes will be reflected by updating this policy and its effective
date. Questions or deletion assistance can be sent to `[SUPPORT EMAIL]`.
