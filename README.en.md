<div align="center">

<img src="site/assets/mascot.gif" width="150" alt="TokenRemain mascot animation: remaining quota draining from 100% to 0%, expression changing along the way" />

# TokenRemain

**Your AI quota, always in the Mac menu bar**

Remaining quota, reset countdowns and today's cost for Claude Code, Codex, Cursor, Grok, GLM and **18+** AI coding tools — all in one place. Credentials stay on your machine: never refreshed, never uploaded.

![macOS](https://img.shields.io/badge/macOS-14%2B_Sonoma-000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-7C5CFF)
![Companion](https://img.shields.io/badge/iPhone_·_Widgets_·_Watch-1F2933?logo=apple&logoColor=white)
![Notarized](https://img.shields.io/badge/Apple-Notarized-34C759?logo=apple&logoColor=white)
![Version](https://img.shields.io/badge/version-1.0.0-22D3EE)

[Website / Download](https://tokenremain.jamescarstin520.chatgpt.site) · [Privacy Policy](https://tokenremain.jamescarstin520.chatgpt.site/privacy.html) · [Support](https://tokenremain.jamescarstin520.chatgpt.site/support.html) · [Report an issue](https://github.com/Carstin520/token-remain/issues)

[简体中文](README.md) · **English**

</div>

---

> **TokenRemain** is the public product name; `UsageDock` is the internal codename in this repo (the download is `TokenRemain.dmg`).
> The app is menu-bar only and shows no Dock icon. Every percentage and progress bar represents **remaining** quota.

## ✨ What it does

- 🧭 **One unified quota panel** — Claude Code / Codex official 5-hour · 7-day windows with reset countdowns, Cursor's monthly billing cycle, Grok's weekly pool, GLM session/weekly windows — all side by side.
- ⏱️ **Pace prediction** — Real window progress plus official reset times decide whether your current pace lasts until reset, with an ETA when it won't.
- 💰 **Today's cost** — ccusage counts today's Claude Code / Codex tokens and estimated API list-price cost, computed locally (not your subscription bill).
- 📱 **Across Apple devices** — The Mac is the only source of real data. With sync enabled, an allowlisted encrypted snapshot travels through *your own* private iCloud database to iPhone / Home Screen widgets / Watch.
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

### iPhone and Home Screen widgets

<table>
  <tr>
    <td align="center" width="25%">
      <img src="site/assets/phone-overview.jpg" alt="iPhone overview" /><br/>
      <sub><b>iPhone · Overview</b><br/>encrypted snapshot from your Mac</sub>
    </td>
    <td align="center" width="25%">
      <img src="site/assets/phone-trends.jpg" alt="iPhone trends" /><br/>
      <sub><b>iPhone · Trends</b><br/>30 days of real history</sub>
    </td>
    <td align="center" width="50%">
      <img src="site/assets/widget-m.png" alt="Medium widget" /><br/>
      <img src="site/assets/widget-s.png" width="150" alt="Small widget" /><br/>
      <sub><b>Home Screen widgets</b> — lowest remaining, per-provider bars and a reset countdown</sub>
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

The multiplatform project — TokenRemain's Mac / iPhone / Watch apps and the Home Screen widgets — lives in `apple/TokenRemain.xcodeproj`; just open it in Xcode. Production builds default to `https://tokenremain-broadcast.jamescarstin520.workers.dev`, overridable with `TOKENREMAIN_BROADCAST_BASE_URL`.

## 📁 Repository layout

| Path | Contents |
| :-- | :-- |
| `Sources/UsageDock/` · `Package.swift` | SwiftPM menu bar app (internal codename UsageDock) |
| `apple/` | Xcode multiplatform project: TokenRemain Mac / iPhone / Watch apps and widgets |
| `broadcast/` | Cloudflare Workers AI Feed backend (D1 + Queues + APNs) |
| `site/` | Marketing site, privacy policy and support pages |
| `docs/` | Release, privacy and architecture documents |
| `design/` | Brand, palette (`design/palette.md`) and UI sources |
| `script/` | Build, packaging and verification scripts |

## 📦 Current release

- **Platform** — macOS 14 Sonoma or later, Apple Silicon (arm64) only; no Intel build yet.
- **Distribution** — The public DMG is Developer ID signed and Apple notarized, currently distributed outside the Mac App Store. An iPhone App Store product will be announced only after development and release validation are complete.
- **Cost figures** — Costs are API list-price estimates, not your subscription bill. When a credential expires, data pauses and the app explains how to restore it.

---

<div align="center">
<sub>

TokenRemain is an independent app, not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, Anysphere, xAI, GitHub, Zhipu AI, or any other provider; service names and marks appear only to identify the services you can choose to connect.

Publisher and support contact: Dongheng Li · jamescarstin520@gmail.com · © 2026

</sub>
</div>
