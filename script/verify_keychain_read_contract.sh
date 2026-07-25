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

# 5. 生产代码里不允许出现 `.allowed` 这个字面量。
#    `Interaction` 不是 RawRepresentable,`.allowed` 只能由字面量构造,所以查字面量
#    就等于查"有没有人打开弹窗开关"—— 比只匹配 `interaction: .allowed` 强:后者
#    绕不过变量转发(例如 ClaudeCredentialsReader 就在转发自己的参数)。
#    注释里提到 `.allowed` 是合法的(那里正需要解释这个契约),所以先用 awk 砍掉
#    `//` 之后的部分再判断。副作用:同一行里 URL 之后的代码会被一起砍掉,概率极低。
ALLOWED_LITERALS="$(/usr/bin/grep -rn --include='*.swift' '\.allowed\b' Sources Packages \
  | /usr/bin/grep -v 'Support/KeychainRead.swift' \
  | /usr/bin/awk -F'//' '$1 ~ /\.allowed/ { print }' || true)"
if [[ -n "$ALLOWED_LITERALS" ]]; then
  echo "$ALLOWED_LITERALS" >&2
  fail "a source file constructs Interaction.allowed; only an explicit user action may request an interactive read"
fi

# 6. 变量转发的那一处必须默认 .disallowed,否则第 5 条就被架空了。
/usr/bin/grep -Eq 'keychainInteraction: *KeychainRead\.Interaction *= *\.disallowed' \
  Sources/UsageDock/Services/ClaudeOAuthUsageService.swift \
  || fail "ClaudeCredentialsReader.load no longer defaults to a non-interactive keychain read"

echo "keychain read contract verified: single read entry point, legacy UI suppressed, no interactive reads on the refresh path"
