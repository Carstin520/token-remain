<div align="center">

<img src="site/assets/mascot.gif" width="150" alt="TokenRemain mascot animation: remaining quota draining from 100% to 0%, expression changing along the way" />

# TokenRemain

**Your AI quota, always in the Mac menu bar**

Remaining quota, reset countdowns and today's cost for Claude Code, Codex, Cursor, Grok, GLM and **18+** AI coding tools — all in one place. Credentials stay on your machine: never refreshed, never uploaded.

![macOS](https://img.shields.io/badge/macOS-14%2B_Sonoma-000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-7C5CFF)
![Notarized](https://img.shields.io/badge/Apple-Notarized-34C759?logo=apple&logoColor=white)
![Latest](https://img.shields.io/badge/latest-v1.1.9-22D3EE)

**Latest version `v1.1.9`** (build 11, Apple notarized and stapled)

[Website / Download](https://tokenremain.com) · [Privacy Policy](https://tokenremain.com/privacy) · [Support](https://tokenremain.com/support) · [Report an issue](https://github.com/Carstin520/token-remain/issues)

[简体中文](README.md) · **English**

</div>

---

> **TokenRemain** is the public product name; `UsageDock` is the internal codename in this repo (the download is `TokenRemain.dmg`).
> The app is menu-bar only and shows no Dock icon. Every percentage and progress bar represents **remaining** quota.

## ✨ What it does

- 🧭 **One unified quota panel** — Claude Code / Codex official 5-hour · 7-day windows with reset countdowns, Cursor's monthly billing cycle, Grok's weekly pool, GLM session/weekly windows — all side by side.
- ⏱️ **Pace prediction** — Real window progress plus official reset times decide whether your current pace lasts until reset, with an ETA when it won't.
- 💰 **Today's cost** — ccusage counts today's Claude Code / Codex tokens and estimated API list-price cost, computed locally (not your subscription bill).
- 🔐 **Optional encrypted sync publisher** — The Mac remains the only source of real data. When enabled, it writes only an allowlisted, encrypted display snapshot to your own private iCloud database.
- 📡 **AI Feed** — A curated server-side feed of public posts from Anthropic, OpenAI and other official accounts; major updates trigger a local notification.
- 🪟 **Always in reach** — Pick which apps appear in the menu bar, keep a floating window on top across Spaces, refresh every 1/5/15/30 minutes or manually.
- 🎨 **Native feel** — macOS 26 uses system Liquid Glass and the native sidebar; macOS 14/15 falls back to the dark card style.

## 📸 Real screenshots

> Every image below is a live screenshot of the latest build.

### macOS

<table>
  <tr>
    <td align="center" width="62%">
      <img src="site/assets/dashboard.jpg" alt="Dashboard overview" /><br/>
      <sub><b>Dashboard · Overview</b> — today's usage and cost split by provider, with official quota progress and risk hints on the right</sub>
    </td>
    <td align="center" width="38%">
      <img src="site/assets/popover.png" alt="Menu bar popover" /><br/>
      <sub><b>Menu bar popover</b> — the tightest window, today's cost and the AI feed at a glance</sub>
    </td>
  </tr>
</table>

## 🔌 Supported services

Most services **connect automatically the moment you're signed in**: TokenRemain only reads credentials that already live on your machine — no extra login, no token refreshing. Every card says where its data comes from, and services that aren't connected show setup hints.

### Native providers (10)

| Service | Connection | Notes |
| :-- | :-- | :-- |
| **Claude Code** | 🟢 Auto | Official 5-hour / 7-day windows with reset countdowns; direct `oauth/usage` queries, degrading to a PTY probe when credentials misbehave |
| **Codex** | 🟢 Auto | Live 5-hour / 7-day windows for the main account; direct server queries with local snapshot fallback, plus a burn-ahead ETA when you're running hot |
| **Cursor** | 🟢 Auto | Monthly billing-cycle quota and reset countdown; read-only queries of `state.vscdb` |
| **Grok** (xAI) | 🟢 Auto | Weekly pool remaining; reads the Grok CLI's existing credentials |
| **GitHub Copilot** | 🟢 Auto | Monthly credits; reads your local GitHub sign-in |
| **Devin** | 🟢 Auto | Daily / weekly quotas |
| **Antigravity** | 🟢 Auto | Quota pools; reads the local sign-in state |
| **OpenCode** | 💾 Local only | Go plan usage, estimated from a local database scan — fully offline |
| **Z.ai** (GLM Coding Plan) | 🔑 API key | Coding Plan session / weekly windows; the key lives only in your Keychain |
| **OpenRouter** | 🔑 API key | Prepaid credit balance |

> 🟢 **Auto** = connected as soon as the tool is signed in · 🔑 **API key** = paste a key once (stored in the Keychain) · 💾 **Local only** = scans local files, never goes online

### token-monitor compatibility layer (8)

| Service | Connection | | Service | Connection |
| :-- | :-- | :-- | :-- | :-- |
| **DeepSeek** | API key | | **Qoder** | Cookie |
| **Kimi** | API key / kimi-auth cookie | | **Kiro** | `kiro-cli /usage` parsing |
| **MiniMax** | API key | | **Volcengine** | AK:SK signing |
| **MiMo Code** | Cookie | | **Ollama** | Session cookie |

## 🔒 Data and privacy

> Privacy isn't a promise — it's the architecture. Every line below is verifiable in the source.

```
Credentials already on your machine ──read-only──▶ Official provider APIs ──▶ Rendered & cached locally
```

- **Read-only credentials, never refreshed** — Reads the access tokens your tools already maintain (Claude Code via direct `oauth/usage`, preferring `~/.claude/.credentials.json` with a Keychain fallback; Codex from `~/.codex/auth.json`; Cursor read-only from `state.vscdb`; Grok from `~/.grok/auth.json`). **Refresh tokens are never touched and nothing is written back**, so there's no fighting Claude Code or Cursor for their sessions and no third-party renewal throttling. When a credential is missing or expired the app degrades automatically (an isolated PTY `/usage` probe for Claude, session rate-limit snapshots for Codex) and returns to direct queries on the next round.
- **Manual keys live in the Keychain** — API keys you add by hand (Z.ai, OpenRouter…) are stored only in the macOS Keychain, never in source, build artifacts or logs. Z.ai also accepts the `ZAI_API_KEY` environment variable or `~/.config/zai/key.json`.
- **No credential relay** — Quota queries go straight to each provider's official API. The AI feed, the push service and the anonymous download counter **never receive** provider credentials.
- **No behavioral tracking** — No telemetry, ads, cookies or analytics SDK. The website keeps only one anonymous aggregate Mac download count.
- **No account required** — You never sign up for TokenRemain; being signed in to your local tools is enough.
- **Cache and stats stay local** — Mac caches and cost statistics stay on the machine (`~/Library/Caches/com.jamesli.usagedock/`). Only when you enable sync does an allowlisted, encrypted display snapshot enter your own private iCloud database.

## 📡 AI Feed

`broadcast/` is a Cloudflare Workers + D1 + Queues backend. The first tier collects original posts from `AnthropicAI`, `OpenAI`, `claudeai`, `sama`, `karpathy` and `btibor91` every ten minutes (at most 30 per day). The second tier runs hourly and picks original posts from `Kimi_Moonshot`, `AIatMeta`, `GoogleDeepMind`, `xai`, `MistralAI`, `deepseek_ai`, `OpenRouterAI`, `perplexity_ai`, `simonw`, `emollick`, `ArtificialAnlys` and `elonmusk`, ranked by engagement, account influence and recency (at most 20 per day). Both tiers exclude replies, reposts and quote posts, and first-tier accounts never re-enter the second tier.

The service exposes `GET /v1/ai-feed` publicly and sends one APNs digest per day in each device's time zone. Users need no account and never see an X API configuration entry point; device registration uses only a random install ID, a device-generated revocation secret and an APNs device token. X credentials, APNs private keys and admin tokens live exclusively in Cloudflare Worker Secrets and are never written into the client or the source. Full contract in [`docs/curated-feed-contract.md`](docs/curated-feed-contract.md) and [`broadcast/README.md`](broadcast/README.md).

## 🚀 Running locally

The menu bar app (internal codename UsageDock):

```bash
bash ./script/build_and_run.sh --verify
```

It installs to `~/Applications/UsageDock.app`. "Launch at login" uses the native macOS login-items API (off by default, toggleable from the menu).

This public repository contains only the TokenRemain macOS desktop client and its required service, website, and release support. Mobile client source is maintained separately and is outside this repository's open-source scope.

## 📁 Repository layout

| Path | Contents |
| :-- | :-- |
| `Sources/UsageDock/` · `Package.swift` | SwiftPM menu bar app (internal codename UsageDock) |
| `Packages/TokenRemainSyncKit/` | Minimal encrypted-sync protocol used by the desktop client |
| `broadcast/` | Cloudflare Workers AI Feed backend (D1 + Queues + APNs) |
| `site/` | Marketing site, privacy policy and support pages |
| `docs/` | Release, privacy and architecture documents |
| `design/` | Brand, palette (`design/palette.md`) and UI sources |
| `script/` | Build, packaging and verification scripts |

## 📄 License

Unless otherwise noted, source code and source documentation in this
repository are available under the [Apache License 2.0](LICENSE). The
TokenRemain name, logos, app icons, robot character, screenshots and original
design assets are not included in that grant; read the
[brand and asset licensing terms](ASSET-LICENSE.md) before copying or
redistributing them. Third-party components and provider marks remain subject
to their respective terms.

## 📦 Current release

- **Version** — `v1.1.9` (build 11). Both the app and the DMG are Apple notarized, stapled and Gatekeeper-accepted.
- **Platform** — macOS 14 Sonoma or later, Apple Silicon (arm64) only; no Intel build yet.
- **Distribution** — The public DMG is Developer ID signed and Apple notarized, currently distributed outside the Mac App Store.
- **Cost figures** — Costs are API list-price estimates, not your subscription bill. When a credential expires, data pauses and the app explains how to restore it.

---

<div align="center">
<sub>

TokenRemain is an independent app, not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, Anysphere, xAI, GitHub, Zhipu AI, or any other provider; service names and marks appear only to identify the services you can choose to connect.

Publisher and support contact: Dongheng Li · jamescarstin520@gmail.com · © 2026

</sub>
</div>
