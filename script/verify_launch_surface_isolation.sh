#!/usr/bin/env bash
set -euo pipefail

# 两条靠代码审查守不住的契约,1.3.0-1.3.4 各违反了一条,合起来是 issue #34
# 那个"启动后无人操作即栈溢出"的崩溃。
#
#   1. 读可见性不得建窗口。后台刷新每隔一分钟就问一次"弹窗可见吗",而
#      `lazy var` 让这个问句本身产生副作用:碰一下就把整个 Liquid Glass 面板
#      建了出来。看代码完全看不出问题——那一行就写着 `.isShown`。
#   2. AppKit 独占窗口尺寸。只要 SwiftUI 还能把量出来的尺寸推回 NSWindow,
#      布局回合就能改自身尺寸从而重入自己,直到主线程栈耗尽。
#
# 这两条都是"写起来很自然、后果在几千帧之外"的那种错误,所以用脚本钉死。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FAILURES=0
fail() {
  echo "launch surface isolation contract failed: $*" >&2
  FAILURES=$(( FAILURES + 1 ))
}

# 承载 NSWindow / NSPanel 的宿主:窗口尺寸必须归 AppKit,一个都不能漏。
WINDOW_HOSTS=(
  "Sources/UsageDock/Support/MenuBarPopupWindowController.swift"
  "Sources/UsageDock/Support/DashboardWindowController.swift"
  "Sources/UsageDock/Support/FloatingWidgetWindowController.swift"
  "Sources/UsageDock/Support/PopoverPreviewWindowController.swift"
)

# NSPopover 宿主:必须**排除**在上面那条规则之外。NSPopover 正是靠
# contentViewController.preferredContentSize 决定自己多大,给它
# sizingOptions = [] 会让 macOS 14/15 的弹窗塌成零高。别"顺手补全"这一处。
POPOVER_HOSTS=(
  "Sources/UsageDock/Support/StatusBarController.swift"
)

# 1. 弹窗控制器不得懒建在属性上:碰一下就构造正是崩溃的第一环。
if grep -rn "lazy var liquidGlassPopupController" Sources/UsageDock >/dev/null 2>&1; then
  fail "liquidGlassPopupController 不能是 lazy var;读状态会把窗口建出来(issue #34)"
fi

# 2. 全仓禁止把 SwiftUI 量出的尺寸接回窗口。
if grep -rn "sizingOptions = \[\.preferredContentSize\]" Sources/UsageDock >/dev/null 2>&1; then
  grep -rn "sizingOptions = \[\.preferredContentSize\]" Sources/UsageDock >&2
  fail "NSWindow 宿主不得使用 .preferredContentSize;改用 FixedHostingWindowSizing"
fi

# 3. 每个窗口宿主都必须显式交出尺寸控制权。
for host in "${WINDOW_HOSTS[@]}"; do
  [[ -f "$host" ]] || { fail "窗口宿主已不存在,请更新本脚本: $host"; continue; }
  grep -q "FixedHostingWindowSizing.configure" "$host" \
    || fail "$host 缺少 FixedHostingWindowSizing.configure(尺寸必须归 AppKit)"
done

# 4. NSPopover 宿主反向断言。
for host in "${POPOVER_HOSTS[@]}"; do
  [[ -f "$host" ]] || { fail "NSPopover 宿主已不存在,请更新本脚本: $host"; continue; }
  if grep -q "FixedHostingWindowSizing.configure" "$host"; then
    fail "$host 是 NSPopover 宿主,加了 FixedHostingWindowSizing 会让弹窗塌成零高"
  fi
done

# 5. 新增的 NSHostingController 必须先归类。漏判一个新宿主,就是把同一个
#    崩溃换个文件再发一遍;所以未登记即失败,而不是默默放行。
while IFS= read -r file; do
  known=0
  for host in "${WINDOW_HOSTS[@]}" "${POPOVER_HOSTS[@]}"; do
    [[ "$file" == "$host" ]] && known=1 && break
  done
  (( known == 1 )) || fail "$file 新建了 NSHostingController,请在本脚本里登记为窗口宿主或 NSPopover 宿主"
done < <(grep -rl "NSHostingController(" Sources/UsageDock --include="*.swift" | sort)

# 6. 可见性检查必须走 PrimarySurfaceVisibility,让"还没建出来"是个必须写出口
#    的状态,而不是靠下一个人记得注释里的叮嘱。
VISIBILITY_HOST="Sources/UsageDock/Support/StatusBarController.swift"
if ! grep -q "PrimarySurfaceVisibility.isVisible" "$VISIBILITY_HOST"; then
  fail "$VISIBILITY_HOST 的可见性检查必须经过 PrimarySurfaceVisibility"
fi

(( FAILURES == 0 )) || exit 1
echo "launch surface isolation verified: AppKit owns window size, visibility checks build nothing"
