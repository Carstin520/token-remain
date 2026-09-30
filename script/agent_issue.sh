#!/usr/bin/env bash
set -euo pipefail

# 无人值守 lane 开或更新自己的 agent:* 追踪 issue（AGENTS.md R14）。
#
# lane 不能评论，也不能改别人的 issue 正文，但漂移、阻塞记录需要随每次运行更新。
# 所以护栏拦下裸 `gh issue edit --body`，更新只走这里：只改本账号创建、带同一
# label 和去重键标记的 open issue，找不到就新建。去重键写在正文首行的 HTML 注释里。

usage() {
  echo "usage: $0 upsert --key KEY --label agent:{drift|triage|proposal|blocked} --title TITLE --body-file FILE" >&2
  exit 64
}
fail() {
  echo "agent issue upsert failed: $*" >&2
  exit 1
}

[[ "${1:-}" == "upsert" ]] || usage
shift
KEY="" LABEL="" TITLE="" BODY_FILE=""
while (($#)); do
  case "$1" in
    --key) KEY="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$KEY" =~ ^[a-z0-9][a-z0-9:._/-]*$ ]] || fail "key must be lowercase letters, digits and :._/- (got '$KEY')"
[[ "$LABEL" =~ ^agent:(drift|triage|proposal|blocked)$ ]] || fail "label must be one of the agent:* lane labels (got '$LABEL')"
[[ -n "$TITLE" ]] || fail "title is empty"
[[ -r "$BODY_FILE" ]] || fail "body file '$BODY_FILE' is not readable"

MARKER="<!-- agent-key: $KEY -->"
ME="$(gh api user --jq .login)"
[[ -n "$ME" ]] || fail "cannot resolve the authenticated GitHub account"

NUMBER="$(gh issue list --state open --label "$LABEL" --limit 200 --json number,author,body \
  | AGENT_MARKER="$MARKER" AGENT_ME="$ME" python3 -c '
import json, os, sys
for issue in json.load(sys.stdin):
    if (issue.get("author") or {}).get("login") == os.environ["AGENT_ME"] \
            and (issue.get("body") or "").startswith(os.environ["AGENT_MARKER"]):
        print(issue["number"])
        break
')"

BODY="$(mktemp "${TMPDIR:-/tmp}/agent-issue.XXXXXX")"
trap 'rm -f "$BODY"' EXIT
{ printf '%s\n\n' "$MARKER"; cat "$BODY_FILE"; } > "$BODY"

if [[ -n "$NUMBER" ]]; then
  gh issue edit "$NUMBER" --title "$TITLE" --body-file "$BODY" >/dev/null
  echo "updated #$NUMBER ($KEY)"
else
  gh issue create --label "$LABEL" --title "$TITLE" --body-file "$BODY"
fi
