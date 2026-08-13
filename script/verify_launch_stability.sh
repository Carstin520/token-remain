#!/usr/bin/env bash
set -euo pipefail

# 启动后无人操作就自己崩掉,是单元测试结构上抓不到的一类回归。
#
# TokenRemain 1.3.0-1.3.4 在 macOS 26 上就是这么死的(issue #34):后台刷新
# 只是想读一下"弹窗可不可见",却把隐藏的 Liquid Glass 面板整个建了出来;那个
# 窗口随后在自己的布局回合里反复改自身尺寸,直到主线程栈耗尽。全程零交互,
# 所有纯函数测试全绿,441 个单测一个都没响。
#
# 能守住这条契约的只有一件事:真的把 app 启起来,真的什么都不做,看它还在不在。
# frosted / clear 两种玻璃都要跑 —— issue #34 的报告人正是用这两轮不同的崩溃
# 栈,证明了病根不在材质上。
#
# 这条竞态不是每次都触发:实测报告人是 5-8 秒必崩,本机复现却是 37 秒,而同
# 一份未修复的二进制换成 clear 跑满 90 秒也能活。所以——
#   * 单轮通过是证据,不是证明。默认每种玻璃跑 ROUNDS 轮来压低假阴性。
#   * 真正验证这个脚本本身有效的办法是反向验证:把修复 stash 掉再跑一遍,
#     它必须失败。改动这个脚本后请重做一次反向验证,否则你只是在看一个
#     永远绿灯的仪表盘。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IDLE_SECONDS="${TOKENREMAIN_LAUNCH_IDLE_SECONDS:-90}"
ROUNDS="${TOKENREMAIN_LAUNCH_ROUNDS:-2}"
REPORT_DIR="$HOME/Library/Logs/DiagnosticReports"
SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

fail() {
  echo "launch stability verification failed: $*" >&2
  exit 1
}

# 只有 macOS 26 才有出问题的那条 Liquid Glass 布局路径。在 14/15 上跑这个脚本
# 走的是 legacy NSPopover,通过了也证明不了任何事,所以明确跳过而不是假装成功。
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( OS_MAJOR < 26 )); then
  echo "skipped: needs macOS 26 or newer (found $(sw_vers -productVersion))"
  exit 0
fi

CONTRACT="$(bash script/build_and_run.sh --print-install-contract)"
APP="$(sed -n 's/^installed_app=//p' <<<"$CONTRACT")"
EXECUTABLE="$(sed -n 's/^executable=//p' <<<"$CONTRACT")"
BUNDLE_ID="$(sed -n 's/^bundle_id=//p' <<<"$CONTRACT")"
[[ -n "$APP" && -n "$EXECUTABLE" && -n "$BUNDLE_ID" ]] \
  || fail "could not read the install contract from build_and_run.sh"

stop_app() {
  /usr/bin/pkill -x "$EXECUTABLE" 2>/dev/null || true
  for _ in {1..20}; do
    /usr/bin/pgrep -x "$EXECUTABLE" >/dev/null || return 0
    sleep 0.5
  done
  fail "$EXECUTABLE would not stop"
}

# 崩溃报告是异步落盘的,进程消失的瞬间文件往往还没写完。用"当前有哪些报告"的
# 集合快照做差,比数数量更耐得住并发写入。
report_snapshot() {
  ls "$REPORT_DIR" 2>/dev/null | grep "^${EXECUTABLE}-" || true
}

if (( SKIP_BUILD == 0 )); then
  echo "==> building and installing $APP"
  stop_app
  bash script/build_and_run.sh run >/dev/null
fi
[[ -d "$APP" ]] || fail "$APP is not installed; run without --skip-build"
stop_app

FAILURES=0
for STYLE in frosted clear; do
  echo "==> popoverGlassStyle=$STYLE: ${ROUNDS} round(s) × ${IDLE_SECONDS}s idle, no interaction"
  /usr/bin/defaults write "$BUNDLE_ID" tokenRemain.popoverGlassStyle.v1 "$STYLE"
  for (( ROUND = 1; ROUND <= ROUNDS; ROUND++ )); do
    BEFORE="$(report_snapshot)"

    /usr/bin/open "$APP"
    # 给 LaunchServices 一点时间把进程真正拉起来,拉不起来本身就是失败。
    LAUNCHED=0
    for _ in {1..20}; do
      if /usr/bin/pgrep -x "$EXECUTABLE" >/dev/null; then LAUNCHED=1; break; fi
      sleep 0.5
    done
    (( LAUNCHED == 1 )) || fail "$EXECUTABLE never started for style=$STYLE round=$ROUND"

    # 每秒轮询而不是直接 sleep 到底:崩溃版本 5-40 秒内就会死,快速失败让反向
    # 验证(故意用未修复的代码跑一遍)几十秒内就能出结论。
    DIED_AT=""
    for (( ELAPSED = 1; ELAPSED <= IDLE_SECONDS; ELAPSED++ )); do
      sleep 1
      if ! /usr/bin/pgrep -x "$EXECUTABLE" >/dev/null; then
        DIED_AT="$ELAPSED"
        break
      fi
    done

    if [[ -n "$DIED_AT" ]]; then
      echo "    round $ROUND FAILED: process died after ${DIED_AT}s with no user interaction" >&2
      FAILURES=$(( FAILURES + 1 ))
    else
      echo "    round $ROUND ok: still running after ${IDLE_SECONDS}s"
    fi

    sleep 3  # 让崩溃报告落盘
    NEW_REPORTS="$(comm -13 <(sort <<<"$BEFORE") <(report_snapshot | sort) || true)"
    if [[ -n "${NEW_REPORTS//[[:space:]]/}" ]]; then
      echo "    round $ROUND FAILED: new crash report(s) for style=$STYLE:" >&2
      sed 's/^/      /' <<<"$NEW_REPORTS" >&2
      FAILURES=$(( FAILURES + 1 ))
    fi
    stop_app
  done
done

# 别把机器留在某一轮的玻璃设置上。
/usr/bin/defaults delete "$BUNDLE_ID" tokenRemain.popoverGlassStyle.v1 2>/dev/null || true

(( FAILURES == 0 )) || fail "$FAILURES check(s) failed"
echo "launch stability verified: ${ROUNDS} round(s) × ${IDLE_SECONDS}s idle survived on both glass styles"
