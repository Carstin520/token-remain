# Security Policy

TokenRemain reads AI coding tools' credentials on your Mac, so security reports get priority.

## Supported versions

Only the [latest release](https://github.com/Carstin520/token-remain/releases/latest) receives security fixes. Please confirm the issue on it before reporting.

## Reporting a vulnerability

**Do not open a public issue.** Email **jamescarstin520@gmail.com** with the subject `[TokenRemain security]` and include:

- the TokenRemain and macOS versions;
- what an attacker can do, and under which conditions;
- steps or a proof of concept to reproduce it.

Never include real tokens, API keys, cookies or unredacted responses — replace them with placeholders.

You'll get an acknowledgment as soon as possible, and updates as the report is investigated. Please allow a reasonable time for a fix before any public disclosure; with your permission, you'll be credited in the release notes.

## In scope

- Reading, storing or transmitting provider credentials: OAuth tokens, pasted API keys and cookies, and Keychain access and prompts.
- Encryption, redaction or replay protection in iCloud sync (`Packages/TokenRemainSyncKit/`, `Sources/UsageDock/Sync/`).
- The local-network direct sync listener (TCP 47831) and its pairing.
- Update integrity: Sparkle appcast signing and release artifacts.
- The `broadcast/` Worker (`api.tokenremain.com`): device registration, the AI Feed and download counts.
- Any network request that carries local usage data or identifiers beyond what the [README's privacy section](README.en.md#privacy) describes.

## Out of scope

- Vulnerabilities in the AI providers' own services or APIs — report those to the provider.
- Attacks that require an already compromised macOS user account or administrator access.
- The iPhone and Apple Watch apps' source, which isn't in this repository. Reports about the apps' behavior are still welcome by email.

---

# 安全策略(中文)

TokenRemain 会读取本机 AI 编码工具的凭证,安全问题优先处理。

- **支持版本**:只有[最新版本](https://github.com/Carstin520/token-remain/releases/latest)提供安全修复,报告前请先在最新版上确认。
- **如何报告**:**不要公开提交 issue。** 请发邮件至 **jamescarstin520@gmail.com**,标题注明 `[TokenRemain security]`,写明版本、影响与利用条件、复现步骤。附件中的 token、API Key、Cookie 或未脱敏响应一律替换为占位符。
- **处理流程**:收到后会尽快确认,并在调查过程中同步进展;修复发布前请勿公开细节。经你同意,会在更新记录中致谢。
- **范围**:与上方英文版相同,包括凭证读取与存储、iCloud 同步加密、局域网直连同步监听、更新签名、`broadcast/` Worker,以及任何超出 README 隐私一节描述的联网行为。服务商自身的 API 漏洞、需要已被攻陷的 macOS 账户才能利用的问题不在范围内。
