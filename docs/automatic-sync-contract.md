# Automatic CloudKit Sync Contract

This document is a release invariant for TokenRemain. It prevents the
Mac-to-iPhone path from drifting back to a manual refresh workflow.

## User-visible contract

- A fresh Mac installation enables private sync automatically.
- A fresh iPhone installation selects the Mac sync source automatically.
- A user's explicit Off or Demo choice remains authoritative across launches.
- Neither app requires a pairing code, device selection, or a manual first pull.
- The settings screens show health and recovery actions. “Retry now” is a
  recovery control, not the primary transport.
- If iCloud Drive, the shared Apple Account, or iCloud Keychain is unavailable,
  the app performs a self-check and shows an actionable prompt after the
  condition persists. It resumes automatically after the condition clears.

## Fixed transport path

1. The Mac reads provider usage locally.
2. The Mac redacts the payload, encrypts it with the synchronizable application
   key, and writes the envelope to the app's CloudKit private database.
   Changed provider data is uploaded after a four-second debounce; even when
   content is unchanged, a five-minute heartbeat refreshes snapshot freshness.
3. CloudKit notifies the iPhone of changes. While the iPhone app is visible, an
   immediate pull plus bounded retries and a 45-second reconciliation loop cover
   missed or coalesced notifications.
4. The iPhone retrieves the synchronized key from iCloud Keychain, verifies and
   decrypts the envelope, then updates the app, widget, and Live Activity data.

Provider credentials, local account identifiers, file paths, raw errors, and
request/response bodies never enter the CloudKit payload.

This is CloudKit-mediated synchronization, not a direct peer-to-peer connection.
Two devices signed into the same Apple Account require no app-specific pairing.

## Delivery objective

After the Mac has captured new provider data and both devices are online, the
product objective is visible iPhone updates within 2–3 minutes, with 5 minutes
as the operational alert threshold. This is not a hard background-delivery SLA:
iOS can defer or coalesce CloudKit pushes while the app is suspended, Low Power
Mode is active, or connectivity is unavailable. Foreground reconciliation is
bounded by the retry policy above.

## Change control

`script/verify_automatic_sync_contract.sh` is invoked by the release
configuration verifier. Any change to defaults, foreground reconciliation,
CloudKit account listeners, retry timing, or the manual-first UI prohibition
must update this contract and its tests in the same commit.

Normal local builds install as `TokenRemain Dev.app` with a separate bundle ID
and process name. Only a profile-backed build containing the CloudKit transport
and validated CloudKit/Keychain entitlements may replace the stable
`TokenRemain.app`.
