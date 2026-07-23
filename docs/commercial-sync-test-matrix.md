# TokenRemain commercial and sync acceptance matrix

Status date: 2026-07-23

Evidence labels:

- **Automated:** a named repository test or verifier directly exercises the state.
- **Simulator:** the Apple target was built or run without production signing.
- **Manual required:** the state depends on the App Store, a real iCloud account,
  production signing, system scheduling, or physical devices.
- **Not applicable:** removed by the approved paid-upfront App Store model.

Passing an automated row does not promote its manual counterpart to complete.

| Required state | Repository evidence | Remaining release evidence |
|---|---|---|
| Fresh install, not purchased | `verify_distribution_model.sh` proves there is no in-app entitlement or paywall | **Manual required:** paid App Store storefront blocks installation until checkout; TestFlight cannot prove this |
| Purchased, first connection | `MobileSyncClientTests.updateThenDuplicate` and honest empty-state copy | **Manual required:** production purchase followed by same-iCloud Mac connection |
| Purchased user reinstalls | No app-local purchase flag can be lost or restored | **Manual required:** re-download from Purchased history, then reconnect iCloud sync |
| Restore Purchases | **Not applicable:** no IAP and no `AppStore.sync()` | Verify no Restore control appears in release UI |
| Purchase pending / Ask to Buy | **Not applicable inside the binary:** App Store owns checkout | **Manual required:** storefront/Ask to Buy behavior before installation |
| Purchase cancelled | **Not applicable inside the binary:** app is not installed by that checkout | **Manual required:** storefront cancellation |
| Refund / revocation | Distribution policy explicitly makes no remote runtime lock | **Manual required:** verify App Store re-download behavior; installed copy and Mac-local data must not be deleted |
| iCloud not signed in | `MobileSyncClientTests.unavailableICloudAccounts` covers `.noAccount` | **Manual required:** signed distribution build shows actionable state and no fictional data |
| iCloud restricted / temporarily unavailable / unknown | `MobileSyncClientTests.unavailableICloudAccounts` | **Manual required:** device/account-policy smoke test where practical |
| Two devices use different iCloud accounts | `MobileSyncClientTests.keyFailure` fails closed without minting a receiver key | **Manual required:** different-account devices wait for the correct key/snapshot |
| App Store purchase account differs from iCloud account | No code couples App Store identity to iCloud identity | **Manual required:** buy with account A, sync private CloudKit with iCloud account B |
| Mac offline | Hard expiry and honest empty presentation are automated in `SnapshotOriginCompatibilityTests` | **Manual required:** observe stale warning and 24-hour value removal |
| iPhone offline | `MobileSyncClientTests.cloudFailuresAreRedacted` covers network failure | **Manual required:** preserve last verified snapshot, then recover after reconnect |
| CloudKit has no snapshot / remote deletion | `MobileSyncClientTests.remoteDeletionResetsReplayState` | **Manual required:** Production-zone deletion clears every mobile surface |
| Sync key missing | `MobileSyncClientTests.keyFailure` | **Manual required:** iCloud Keychain propagation delay and recovery |
| AES authentication/decryption fails | Wrong-key branch in `MobileSyncClientTests.keyFailure`; protocol AES tests cover tampering | **Manual required:** old verified values remain without leaking raw errors |
| Old sequence / replay | `MobileSyncClientTests.olderSequenceIsRejected` and shared `SyncReplayGuard` tests | **Manual required:** injected Production replay cannot roll back the UI |
| Switch primary Mac | `sourceChangeConfirmation` and `sourceChangeConfirmationRejectsReplacement` | **Manual required:** authenticated second Mac requires exact user confirmation |
| Provider data stale | `macSyncHardExpiry` shared tests and timestamp-preserving adapter | **Manual required:** UI shows provider capture time, not only iCloud fetch time |
| iPhone foreground p50/p95/max | `SyncLatencyMetrics` and `MobileSyncLatencyStoreTests` validate chronology, privacy, and nearest-rank math | **Manual required:** real same-iCloud Mac/iPhone samples meet 60/120/180 seconds |
| Widget/Live Activity/Watch never invent data | empty snapshot, hard-expiry, Widget entry, App Group and Watch fan-out tests | **Manual required:** physical Widget, Live Activity, and paired Watch observation |
| Mac local features remain free | Paid-upfront verifier rejects StoreKit/IAP implementation across Mac and Apple targets | **Manual required:** final notarized Mac smoke test covers every local provider and feature |
| Notification permission is not a sync prerequisite | `AIFeedTests.notificationPermissionIsUserInitiated` proves fresh-install reminders default off | **Manual required:** permission prompt appears only after the user turns reminders on |

## Release evidence record

Attach the following without secrets or quota contents:

1. App Store Connect build-processing result and entitlement warnings.
2. TestFlight version/build and device/OS matrix.
3. Developer ID `codesign`, `stapler`, and Gatekeeper verification output.
4. CloudKit Production schema version/deployment date.
5. Foreground latency aggregate with sample count and p50/p95/max only.
6. Pass/fail notes for each manual row above, including the tester and date.
