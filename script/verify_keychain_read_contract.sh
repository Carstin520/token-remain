#!/usr/bin/env bash
set -euo pipefail

# 后台额度刷新绝不允许召唤钥匙串授权框。
#
# 这条契约靠代码审查守不住:每个 provider 的凭证发现都想"顺手读一下钥匙串",
# 而裸 SecItemCopyMatching 在未授权时会**阻塞到用户点击**,把刷新任务连同
# 降级链一起吊死。所以读取入口必须收敛到 KeychainRead 一处,由它统一关掉
# legacy 钥匙串的交互开关。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

READER="Sources/UsageDock/Support/KeychainRead.swift"

fail() {
  echo "keychain read contract verification failed: $*" >&2
  exit 1
}

# 1. 允许直接调用 SecItemCopyMatching 的文件白名单。
#    - KeychainRead.swift:统一的只读入口
#    - SynchronizableSyncKeyStore.swift:走 data-protection keychain + app 自己的
#      access group(kSecAttrSynchronizable),查询形态与 legacy 条目不同,不能
#      套用 KeychainRead;它自己处理 interactionNotAllowed。
ALLOWED=(
  "Sources/UsageDock/Support/KeychainRead.swift"
  "Packages/TokenRemainSyncKit/Sources/TokenRemainSyncKit/SynchronizableSyncKeyStore.swift"
)
# 扫描范围包含桌面同步包：同一个进程里的裸读取不会因为换了 target 就安全。
while IFS= read -r offender; do
  [[ -z "$offender" ]] && continue
  for allowed in "${ALLOWED[@]}"; do
    [[ "$offender" == "$allowed" ]] && continue 2
  done
  fail "$offender calls SecItemCopyMatching directly; route it through KeychainRead instead"
done < <(/usr/bin/grep -rl --include='*.swift' 'SecItemCopyMatching' Sources Packages || true)

# 2. 禁止交互必须用 SecKeychainSetUserInteractionAllowed。
#    kSecUseAuthenticationContext / kSecUseAuthenticationUIFail 对 legacy
#    (file-based)钥匙串的 ACL 授权框实测无效,不能作为唯一手段。
/usr/bin/grep -Fq 'SecKeychainSetUserInteractionAllowed' "$READER" \
  || fail "$READER no longer calls SecKeychainSetUserInteractionAllowed; the ACL prompt will come back"
# 关掉之后必须还原,否则整个进程后续都读不到需要授权的条目。
/usr/bin/grep -Fq 'setLegacyInteractionAllowed(false)' "$READER" \
  || fail "$READER no longer disables legacy keychain UI before reading"
/usr/bin/grep -Fq 'setLegacyInteractionAllowed(true)' "$READER" \
  || fail "$READER never restores legacy keychain UI; the whole process would stay silent"

# 3. Interaction 不能有默认值 —— 每个调用点必须显式表态,漏写是编译错误。
if /usr/bin/grep -Eq 'interaction: *Interaction *=' "$READER"; then
  fail "$READER gives Interaction a default value; a missing call-site intent must not silently allow prompts"
fi

# 4. 自动刷新链路上的 provider 只能用 .disallowed。
for service in \
  Sources/UsageDock/Services/ClaudeOAuthUsageService.swift \
  Sources/UsageDock/Services/AntigravityUsageService.swift \
  Sources/UsageDock/Services/CopilotUsageService.swift \
  Sources/UsageDock/Services/CursorUsageService.swift; do
  /usr/bin/grep -Fq 'KeychainRead.genericPassword' "$service" \
    || fail "$service no longer reads through KeychainRead"
done

# 5. `.allowed` 只允许在数据源页的明确用户授权入口中构造。
#    该方法只由 Button 动作调用;后台刷新、凭据发现和变量转发仍不能
#    生成交互读取。注释里的 `.allowed` 先用 awk 剔除,避免误报。
ALLOWED_LITERALS="$(/usr/bin/grep -rn --include='*.swift' '\.allowed\b' Sources Packages \
  | /usr/bin/grep -v 'Support/KeychainRead.swift' \
  | /usr/bin/awk -F'//' '$1 ~ /\.allowed/ { print }' || true)"
INTERACTIVE_ENTRY="Sources/UsageDock/Stores/UsageStore.swift"
INTERACTIVE_METHOD="$(/usr/bin/awk '
  /func authorizeProviderCredentials\(/ { in_method = 1 }
  in_method && /private func refreshKeyProvider\(/ { exit }
  in_method { print }
' "$INTERACTIVE_ENTRY")"
ALLOWED_LITERAL_COUNT="$(printf '%s\n' "$ALLOWED_LITERALS" \
  | /usr/bin/sed '/^[[:space:]]*$/d' \
  | /usr/bin/wc -l \
  | /usr/bin/tr -d '[:space:]')"
METHOD_ALLOWED_COUNT="$(printf '%s\n' "$INTERACTIVE_METHOD" \
  | /usr/bin/awk -F'//' '$1 ~ /\.allowed/ { count++ } END { print count + 0 }')"
if [[ "$ALLOWED_LITERAL_COUNT" != "2" \
  || "$METHOD_ALLOWED_COUNT" != "2" \
  || "$(printf '%s\n' "$ALLOWED_LITERALS" | /usr/bin/cut -d: -f1 | /usr/bin/sort -u)" != "$INTERACTIVE_ENTRY" ]]; then
  echo "$ALLOWED_LITERALS" >&2
  fail "Interaction.allowed must appear exactly twice inside UsageStore.authorizeProviderCredentials"
fi
/usr/bin/grep -Fq 'await store.authorizeProviderCredentials(provider)' \
  Sources/UsageDock/Views/Dashboard/DataSourcesSection.swift \
  || fail "the interactive Keychain read is no longer initiated by the explicit Data Sources action"

# 6. 变量转发的那一处必须默认 .disallowed,否则第 5 条就被架空了。
/usr/bin/grep -Eq 'keychainInteraction: *KeychainRead\.Interaction *= *\.disallowed' \
  Sources/UsageDock/Services/ClaudeOAuthUsageService.swift \
  || fail "ClaudeCredentialsReader.load no longer defaults to a non-interactive keychain read"

echo "keychain read contract verified: background reads stay silent; explicit Data Sources authorization is isolated"
