# TokenRemain for Windows

This directory contains the independent Windows desktop adapter. It keeps the
existing TokenRemain dashboard language while replacing macOS-only APIs with a
small Electron shell.

## Scope of this branch

- Reads the existing Claude Code and Codex CLI credential files on the PC.
- Calls the same official quota endpoints used by the macOS app.
- Bundles the official native `ccusage` helper for the target Windows
  architecture and reads supported coding-agent logs locally for daily token
  and estimated-cost history. No separate Node.js or ccusage install is needed.
- Runs `ccusage` offline with an app-owned pricing configuration. Every six
  hours the app conditionally downloads and validates the complete public
  LiteLLM pricing table; it never sends an observed model name, token count,
  project, path, prompt, or session to the pricing source.
- Keeps the last validated public table and falls back to ccusage's embedded
  price snapshot whenever the network is unavailable.
- Never refreshes, rewrites, copies, or syncs provider credentials.
- Optionally exchanges normalized quota snapshots and daily aggregates with a
  paired Mac on the LAN. Mac pairing is not required for Windows daily usage.
- Preserves every provider in the Mac snapshot and exposes Overview, Limits,
  Trends, Devices, Data Sources, and Settings with honest Windows data states.
- Supports persistent full-card reordering in Limits: direct mouse drag,
  long-press touch/pen drag, and `Alt` + arrow keys for keyboard users.
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

Build a native-architecture Windows installer with `npm run dist:win`, or force
x64 with `npm run dist:win:x64`. A package assembled on macOS still requires a
real Windows smoke test before it is considered release-ready.

## Optional Mac pairing

1. Open **Devices** in TokenRemain on the Mac and start a one-time pairing
   session.
2. In the Windows app, open **Devices** and enter the Mac LAN address plus the
   one-time code.
3. Both sides derive a unique device key. The one-time code is not stored.

LAN transport is currently HTTP because the quota body is already
application-layer encrypted and authenticated. Network observers can still see
connection timing and the two random source IDs; they cannot read quota values.
