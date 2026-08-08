<div align="center">

<img src="site/assets/mascot.gif" width="140" alt="TokenRemain mascot animation: remaining quota draining from 100% to 0%, expression changing along the way" />

# TokenRemain

**Your AI quota, always in the Mac menu bar**

Remaining quota, reset countdowns and today's cost for Claude Code, Codex, Cursor, Windsurf, Grok, GLM<br/>and **21+** AI coding tools — all in one place. Credentials stay on your machine: never refreshed, never uploaded.

![macOS](https://img.shields.io/badge/macOS-14%2B_Sonoma-000?logo=apple&logoColor=white)
![Universal](https://img.shields.io/badge/Universal-Apple_Silicon_%2B_Intel-7C5CFF)
![Notarized](https://img.shields.io/badge/Apple-Notarized-34C759?logo=apple&logoColor=white)
![Latest](https://img.shields.io/badge/latest-v1.2.11-22D3EE)
![License](https://img.shields.io/badge/license-Apache--2.0-8A94A6)

### [⬇️ Download TokenRemain.dmg](https://tokenremain.com)

<sub>`v1.2.11` · build 26 · Universal (Apple Silicon + Intel) · macOS 14+</sub>

[Website](https://tokenremain.com) · [Privacy Policy](https://tokenremain.com/privacy) · [Support](https://tokenremain.com/support) · [Report an issue](https://github.com/Carstin520/token-remain/issues) · [Changelog](CHANGELOG.md)

[简体中文](README.md) · **English**

</div>

---

## ✨ What it does

- 🧭 **One unified quota panel** — Claude/Codex official 5-hour · 7-day windows, Cursor's monthly billing cycle, Grok's weekly pool, GLM session/weekly windows — side by side with reset countdowns.
- ⏱️ **Pace prediction** — Real window progress decides whether your current pace lasts until reset, with an ETA when it won't.
- 💰 **Today's cost** — ccusage counts tokens from 15+ coding agents locally, estimated at official API list prices (not your subscription bill); usage details are never uploaded.
- 🔐 **Optional encrypted sync** — When enabled, only an encrypted display snapshot enters your own private iCloud database, viewable on iPhone / Apple Watch.
- 📡 **AI Feed** — A curated server-side feed of official posts from Anthropic, OpenAI and more; major updates trigger a local notification.
- ⚡ **Tiny footprint** — Background CPU down 95%, attributed power down 77%, with data freshness unchanged ([method & boundaries](docs/performance-v1.2.3.md)).
- 🎨 **Native feel** — Liquid Glass on macOS 26; menu-bar capsules, a floating window across Spaces, refresh every 1–30 minutes or manually.

## 📸 Screenshots

<table>
  <tr>
    <td align="center" width="62%">
      <img src="site/assets/dashboard.jpg" alt="Dashboard overview" /><br/>
      <sub><b>Dashboard · Overview</b></sub>
    </td>
    <td align="center" width="38%">
      <img src="site/assets/popover.png" alt="Menu bar popover" /><br/>
      <sub><b>Menu bar popover</b></sub>
    </td>
  </tr>
</table>

<table>
  <tr>
    <td align="center" width="50%">
      <img src="site/assets/dash-limits.jpg" alt="Dashboard limits page" /><br/>
      <sub><b>Dashboard · Limits & pace prediction</b></sub>
    </td>
    <td align="center" width="50%">
      <img src="site/assets/dash-trends.jpg" alt="Dashboard trends page" /><br/>
      <sub><b>Dashboard · Trends</b></sub>
    </td>
  </tr>
</table>

<div align="center">
  <img src="site/assets/menubar.png" width="234" alt="Close-up of the menu bar capsule: Claude 89%, Codex 91%" /><br/>
  <sub><b>Menu bar capsule</b> — choose which apps and percentages stay pinned</sub>
</div>

### iPhone · Apple Watch (encrypted-sync companion)

<table>
  <tr>
    <td align="center" width="27%">
      <img src="site/assets/phone-overview.jpg" alt="iPhone overview page" /><br/>
      <sub><b>Overview</b> — up to 16 Macs</sub>
    </td>
    <td align="center" width="27%">
      <img src="site/assets/phone-trends.jpg" alt="iPhone trends page" /><br/>
      <sub><b>Trends</b></sub>
    </td>
    <td align="center" width="27%">
      <img src="site/assets/phone-aifeed.jpg" alt="iPhone AI Feed page" /><br/>
      <sub><b>AI Feed</b></sub>
    </td>
    <td align="center" width="19%">
      <img src="site/assets/watch-overview.png" alt="Apple Watch overview" /><br/>
      <img src="site/assets/watch-feed.png" alt="Apple Watch AI Feed" /><br/>
      <sub><b>Apple Watch</b></sub>
    </td>
  </tr>
</table>

<table>
  <tr>
    <td align="center" width="34%">
      <img src="site/assets/widget-s.png" alt="Small iPhone Home Screen widget" /><br/>
      <sub><b>Small widget</b></sub>
    </td>
    <td align="center" width="66%">
      <img src="site/assets/widget-m.png" alt="Medium iPhone Home Screen widget" /><br/>
      <sub><b>Medium widget</b> — the tightest window right on the Home Screen</sub>
    </td>
  </tr>
</table>

> Data is always published one-way and encrypted by the Mac; the mobile client is maintained separately, outside this repository's open-source scope.

## 🔌 Supported services

Most services **connect automatically the moment you're signed in**: TokenRemain only reads credentials that already live on your machine. Claude/Codex work with the official desktop apps — no CLI required.

### Native providers (11)

| Service | Connection | Notes |
| :-- | :-- | :-- |
| <img src="site/assets/providers/claude-code.svg" width="16" alt="" /> **Claude Code** | 🟢 Auto | 5-hour / 7-day windows; third-party `ANTHROPIC_BASE_URL` attributed to its real API |
| <img src="site/assets/providers/codex.svg" width="16" alt="" /> **Codex** | 🟢 Auto | 5-hour / 7-day windows; custom `base_url` attributed to its real API |
| <img src="site/assets/providers/cursor.svg" width="16" alt="" /> **Cursor** | 🟢 Auto | Monthly billing-cycle quota with reset countdown |
| <img src="site/assets/providers/grok.svg" width="16" alt="" /> **Grok** (xAI) | 🟢 Auto | Weekly pool remaining |
| <img src="site/assets/providers/copilot.svg" width="16" alt="" /> **GitHub Copilot** | 🟢 Auto | Monthly credits |
| <img src="site/assets/providers/devin.svg" width="16" alt="" /> **Devin** | 🟢 Auto | Daily / weekly quotas |
| <img src="site/assets/providers/windsurf.png" width="16" alt="" /> **Windsurf** | 🟢 Auto | Daily / weekly quotas |
| <img src="site/assets/providers/antigravity.svg" width="16" alt="" /> **Antigravity** | 🟢 Auto | Quota pools |
| <img src="site/assets/providers/opencode.svg" width="16" alt="" /> **OpenCode** | 🟢 Auto | Local plan estimate; third-party providers attributed to their real API |
| <img src="site/assets/providers/zai.svg" width="16" alt="" /> **Z.ai** (GLM Coding Plan) | 🔑 API key | Session / weekly windows plus MCP monthly pool |
| <img src="site/assets/providers/openrouter.svg" width="16" alt="" /> **OpenRouter** | 🔑 API key | Key limits, credits and account balance |

> 🟢 **Auto** = connected as soon as the tool is signed in · 🔑 **API key** = paste a key once, stored only in the macOS Keychain

### token-monitor compatibility layer (10)

| Service | Connection | | Service | Connection |
| :-- | :-- | :-- | :-- | :-- |
| <img src="site/assets/providers/deepseek.svg" width="16" alt="" /> **DeepSeek** | API key | | <img src="site/assets/providers/qoder.svg" width="16" alt="" /> **Qoder** | Cookie |
| <img src="site/assets/providers/kimi.svg" width="16" alt="" /> **Kimi** | API key / cookie | | <img src="site/assets/providers/kiro.svg" width="16" alt="" /> **Kiro** | `kiro-cli /usage` parsing |
| <img src="site/assets/providers/minimax.svg" width="16" alt="" /> **MiniMax** | API key | | <img src="site/assets/providers/volcengine.svg" width="16" alt="" /> **Volcengine** | AK:SK signing |
| <img src="site/assets/providers/mimo.svg" width="16" alt="" /> **MiMo Code** | Cookie | | <img src="site/assets/providers/ollama.svg" width="16" alt="" /> **Ollama** | Session cookie |
| <img src="site/assets/providers/zai.svg" width="16" alt="" /> **GLM Team** | API key + org + project | | **Third-party APIs** | New API / custom balance endpoint |

### Local token and cost sources

The bundled ccusage collector dynamically discovers 15+ local agents (Claude Code, Codex, Gemini, Goose, …), each togglable on the Data Sources page; Trae contributes only timestamps, model names and token counts from a folder you select. Hosted models use official list-price estimates; local models like Ollama stay at zero cost.

## 🔒 Data and privacy

> Privacy isn't a promise — it's the architecture. Every line below is verifiable in the source.

```
Credentials already on your machine ──read-only──▶ Official provider APIs ──▶ Rendered & cached locally
```

- **Read-only credentials, never refreshed** — Reads the tokens your tools already maintain, never writes back, never fights them for refresh tokens; background reads never trigger a system prompt.
- **Manual keys live in the Keychain** — Pasted API keys are stored only in the macOS Keychain, never in source, build artifacts or logs.
- **No account, no telemetry, no credential relay** — Quota queries go straight to official APIs; the website keeps only daily snapshots of one anonymous download total.
- **Price updates never upload usage** — At most one bodyless GET per day fetches the public LiteLLM price table, carrying no local data.
- **Cache and stats stay local** — Only with sync enabled does an encrypted display snapshot enter your own private iCloud database.

Details in the [privacy policy](https://tokenremain.com/privacy). Costs are API list-price estimates, not your subscription bill.

## 📡 AI Feed

`broadcast/` (Cloudflare Workers + D1 + Queues) curates original and quote posts from official X accounts in two tiers, serves `GET /v1/ai-feed` publicly, and sends one APNs digest per day in each device's time zone. Device registration uses only a random install ID; X / APNs secrets live exclusively in Worker Secrets. Full contract in [`docs/curated-feed-contract.md`](docs/curated-feed-contract.md) and [`broadcast/README.md`](broadcast/README.md).

## 🚀 Running locally

```bash
bash ./script/build_and_run.sh --verify
```

Installs to `~/Applications/UsageDock.app`. This public repository contains only the macOS desktop client and its service, website and release support; mobile client source is maintained separately.

| Path | Contents |
| :-- | :-- |
| `Sources/UsageDock/` · `Package.swift` | SwiftPM menu bar app |
| `Packages/TokenRemainSyncKit/` | Minimal encrypted-sync protocol package |
| `broadcast/` | Cloudflare Workers backend (AI Feed + download counter) |
| `site/` | Marketing site, privacy policy and support pages |
| `docs/` | Release, privacy and architecture documents |
| `design/` | Brand, palette and UI sources |
| `script/` | Build, packaging and verification scripts |

## 📈 Downloads over time

<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://api.tokenremain.com/v1/downloads/chart.svg?theme=dark&amp;lang=en" />
  <source media="(prefers-color-scheme: light)" srcset="https://api.tokenremain.com/v1/downloads/chart.svg?theme=light&amp;lang=en" />
  <img src="https://api.tokenremain.com/v1/downloads/chart.svg?theme=dark&amp;lang=en" width="920" alt="Cumulative website download chart, rendered from daily snapshots of the anonymous aggregate counter" />
</picture>

<sub>The total starts from the 163 historical `TokenRemain.dmg` downloads (as of 2026-08-07, [breakdown](docs/download-baseline.md)); the anonymous website route increments it immediately and an hourly monotonic reconciliation catches fixed-name GitHub DMG requests; no personal data involved.</sub>

</div>

## 📄 License

Source code and source documentation are available under the [Apache License 2.0](LICENSE); the TokenRemain name, logos, icons, robot character and original design assets are not included — see the [brand and asset licensing terms](ASSET-LICENSE.md).

---

<div align="center">
<sub>

TokenRemain is an independent app, not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, Anysphere, xAI, GitHub, Zhipu AI, or any other provider; service names and marks appear only to identify the services you can choose to connect.

Publisher and support contact: Dongheng Li · jamescarstin520@gmail.com · © 2026

</sub>
</div>
