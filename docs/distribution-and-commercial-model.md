# TokenRemain distribution and commercial model

Status: **Product decision approved for implementation**

Decision date: 2026-07-23

## Chosen model

TokenRemain uses two independent distribution channels:

- **iPhone:** a paid-upfront App Store app. One purchase includes the iPhone
  app, its Home/Lock Screen widgets, Live Activity, and the bundled Apple Watch
  app.
- **Mac:** a full-featured website download signed with Developer ID,
  notarized, and stapled. The Mac app is not sandboxed and keeps every local
  provider, dashboard, menu bar, history/trend, prediction, feed,
  customization, and local-notification feature available without a purchase
  gate.

The iPhone App Store download is the commercial gate for the Apple companion
experience. The Mac may publish the user's encrypted allowlisted snapshot when
sync is enabled; only a user who has installed the paid iPhone app can consume
that snapshot in the companion UI.

## Explicitly out of scope

This model does **not** use:

- a StoreKit in-app purchase;
- the proposed `tokenremain.pro.sync.lifetime` product;
- an in-app paywall or Restore Purchases button;
- a TokenRemain account or Sign in with Apple;
- Universal Purchase between the website Mac app and the iPhone app;
- a Boolean entitlement copied through UserDefaults, App Group, or CloudKit;
- a macOS Bundle ID migration.

The Bundle IDs remain:

- macOS: `com.jamesli.usagedock`
- iOS: `com.jamesli.tokenremain`

Because the macOS identifier does not change, its UserDefaults, caches,
Keychain access, launch-at-login registration, and existing installations do
not need the previously considered `com.jamesli.tokenremain` migration.

## Purchase, reinstall, and refund behavior

- App Store purchase, family access if enabled, and re-download are handled by
  the App Store. There is no separate TokenRemain restore flow.
- TestFlight proves the release build and external-service behavior; it does
  not prove a paid storefront checkout.
- Version 1 does not make `AppTransaction` a launch-time gate. A strict online
  check could deny a legitimate purchaser while offline or when App Store
  authentication is temporarily unavailable, while duplicating the App
  Store's install gate.
- Consequently, refund or purchase revocation does not remotely disable an
  already installed copy. The user can no longer newly download it through the
  refunded purchase, subject to App Store behavior, but TokenRemain makes no
  stronger claim.
- Revoking companion access must never delete provider credentials or local
  Mac data. This remains true if the commercial model changes later.

## Signing and release boundary

The production Mac package must:

1. keep App Sandbox disabled;
2. use the `com.jamesli.usagedock` identifier;
3. be signed with a Developer ID Application certificate, Hardened Runtime,
   and a timestamp;
4. embed an Apple-issued Developer ID provisioning profile that authorizes
   the production CloudKit container and shared synchronizable Keychain group;
5. be submitted to Apple's notarization service and have the successful ticket
   stapled before website publication.

The existing App Store Sandbox candidate remains an isolated audit artifact.
It is not a release target and must not replace the website build.

## App Store Connect gate

No external App Store state has been changed by this repository decision.
Before the paid iPhone app can be submitted, the Account Holder must complete
or confirm all of the following in App Store Connect:

1. accept the current Paid Apps Agreement and finish banking/tax setup;
2. choose the final base price;
3. choose storefront availability;
4. decide whether Family Sharing is offered, if App Store Connect makes it
   available for this app;
5. attach the signed release build and complete the normal privacy, export
   compliance, age-rating, and review metadata.

Price, storefronts, and Family Sharing are intentionally undecided here. No
Product ID needs to be created.

## Rollback and future changes

- **Before first App Store release:** the iPhone record can still be changed to
  free plus a non-consumable IAP, but that is a new product decision and must
  restore the entitlement/paywall test plan before implementation.
- **After paid release:** changing to free plus IAP requires an explicit policy
  for existing paid customers. They must not be charged again. That migration
  is not inferred or implemented by this decision.
- The Mac App Store candidate can be revisited later as a separate reduced
  edition, but it cannot silently replace the full website edition.
