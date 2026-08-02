# TokenRemain for Windows

This directory contains the independent Windows desktop adapter. It keeps the
existing TokenRemain dashboard language while replacing macOS-only APIs with a
small Electron shell.

## Scope of this branch

- Reads the existing Claude Code and Codex CLI credential files on the PC.
- Calls the same official quota endpoints used by the macOS app.
- Never refreshes, rewrites, copies, or syncs provider credentials.
- Exchanges only normalized quota snapshots with a paired Mac on the LAN.
- Protects every snapshot with AES-256-GCM and stores the paired-device key with
  Windows `safeStorage` (DPAPI-backed on normal Windows installations).
- Does not use CloudKit and does not interact with the iPhone app.

## Development

Requires Node.js 22.12 or newer for development. End users do not need Node.js;
the packaged app includes its runtime.

```powershell
npm install
npm test
npm run start
```

Build Windows installers with `npm run dist:win`. A package assembled on macOS
still requires a real Windows smoke test before it is considered release-ready.

## Pairing

1. Open **Devices** in TokenRemain on the Mac and start a one-time pairing
   session.
2. In the Windows app, open **Devices** and enter the Mac LAN address plus the
   one-time code.
3. Both sides derive a unique device key. The one-time code is not stored.

LAN transport is currently HTTP because the quota body is already
application-layer encrypted and authenticated. Network observers can still see
connection timing and the two random source IDs; they cannot read quota values.
