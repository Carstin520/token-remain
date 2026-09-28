#!/usr/bin/env bash
set -euo pipefail

# lane 护栏与 issue 助手的自测（S 级：只在自己的临时目录里建 git 仓库，gh 用替身）。
#
# 护栏是 hook 里的一段解析器，最容易出的错有两种：该拦的命令换个写法就漏过去，
# 或者交互会话被误拦。所以每条拦截项都配一个正例、几个绕行写法，外加同一批命令
# 在交互会话里必须原样放行。改护栏后先让这里变红再修，别只看它一直是绿的。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT_DIR/script/agent_lane_guard.sh"
ISSUE="$ROOT_DIR/script/agent_issue.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-lane-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
CASES=0
fail() {
  echo "lane guard self-test failed: $*" >&2
  FAILURES=$((FAILURES + 1))
}

git init -q "$WORK/plain"
git init -q "$WORK/main"
git -C "$WORK/main" -c user.email=guard@example.invalid -c user.name=guard commit -q --allow-empty -m base
git -C "$WORK/main" worktree add -q --detach "$WORK/lane"
echo unattended > "$(git -C "$WORK/lane" rev-parse --absolute-git-dir)/tokenremain-agent-lane"
git init -q "$WORK/other-marker"
echo interactive > "$(git -C "$WORK/other-marker" rev-parse --absolute-git-dir)/tokenremain-agent-lane"

# Payload cwd is a fixed non-temp lane path, so results do not depend on where this
# checkout lives; the temp repos above only decide lane identity.
LANE_CWD="/Users/agent/Developer/Desktop_Projects/UsageDock-agent"
claude_payload() {
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$2"
}

# guard <lane: env|none> <project dir> <host> <payload>; prints "exit|stdout|stderr".
guard() {
  local lane="$1" project="$2" host="$3" payload="$4" out err code
  out="$WORK/out" err="$WORK/err"
  if [[ "$lane" == "env" ]]; then
    (cd "$project" && printf '%s' "$payload" | env TOKENREMAIN_AGENT_LANE=unattended CLAUDE_PROJECT_DIR="$project" "$GUARD" --host "$host" >"$out" 2>"$err") && code=0 || code=$?
  else
    (cd "$project" && printf '%s' "$payload" | env -u TOKENREMAIN_AGENT_LANE CLAUDE_PROJECT_DIR="$project" "$GUARD" --host "$host" >"$out" 2>"$err") && code=0 || code=$?
  fi
  printf '%s|%s|%s' "$code" "$(cat "$out")" "$(cat "$err")"
}

expect_block() {
  local rule="$1" command="$2" result
  CASES=$((CASES + 1))
  result="$(guard env "$WORK/plain" claude "$(claude_payload "$command" "$LANE_CWD")")"
  [[ "${result%%|*}" == "2" ]] || { fail "lane must block [$rule]: $command (got exit ${result%%|*})"; return; }
  [[ "$result" == *"blocked $rule"* ]] || fail "lane blocked for the wrong rule, expected [$rule]: $command -> ${result#*|}"
  CASES=$((CASES + 1))
  result="$(guard none "$WORK/plain" claude "$(claude_payload "$command" "$LANE_CWD")")"
  [[ "$result" == "0||" ]] || fail "interactive session must pass silently: $command -> $result"
}

expect_allow() {
  local command="$1" result
  CASES=$((CASES + 1))
  result="$(guard env "$WORK/plain" claude "$(claude_payload "$command" "$LANE_CWD")")"
  [[ "$result" == "0||" ]] || fail "lane must allow: $command -> $result"
}

newline=$'\n'

# Each R14 prohibition, plus the rewrites an agent reaches for after a block.
expect_block canary 'true tokenremain-lane-guard-canary'
expect_block git-push 'git push origin main'
expect_block git-push 'git push origin HEAD:main'
expect_block git-push 'git push origin HEAD:refs/heads/main'
expect_block git-push 'git push'
expect_block git-push 'git push --force origin agent/lane-b'
expect_block git-push 'git push --force-with-lease origin agent/lane-b'
expect_block git-push 'git push origin +agent/lane-b'
expect_block git-push 'git push origin :agent/lane-b'
expect_block git-push 'git push --tags origin agent/lane-b'
expect_block git-push 'cd /tmp && git push origin main'
expect_block git-push 'bash -lc "git push origin main"'
expect_block git-push "echo ok${newline}git push origin main"
expect_block git-push 'FOO=1 /usr/bin/git -C . push origin main'
expect_block git-push 'echo "$(git push origin main)"'
expect_block git-push 'echo `git push origin main`'
expect_block git-push 'if true; then git push origin main; fi'
expect_block git-push 'timeout 30 env -i git push origin main'
expect_block gh-pr-merge 'gh pr merge 12 --squash'
expect_block gh-pr-merge 'gh pr merge --auto --squash 12'
expect_block gh-pr-create 'gh pr create --title x --body y'
expect_block gh-pr-ready 'gh pr ready 12'
expect_block gh-api 'gh api -X PUT repos/o/r/pulls/5/merge'
expect_block git-tag 'git tag v9.9.9'
expect_block git-tag 'git tag -a v9.9.9 -m release'
expect_block git-tag 'git tag -d v1.0.0'
expect_block gh-release-create 'gh release create v9.9.9 dist/TokenRemain.dmg'
expect_block gh-release-upload 'gh release upload v1.3.9 appcast.xml'
expect_block wrangler 'wrangler deploy'
expect_block wrangler 'npx wrangler deploy'
expect_block wrangler 'npx wrangler d1 execute tokenremain-broadcast --remote --command "select 1"'
expect_block npm-deploy 'npm run deploy'
expect_block npm-deploy 'npm --prefix site run deploy'
expect_block yarn-deploy 'yarn deploy'
expect_block npm-publish 'npm publish'
expect_block package_developer_id_release.sh 'script/package_developer_id_release.sh'
expect_block package_developer_id_release.sh 'bash ./script/package_developer_id_release.sh notarize'
expect_block build_and_run.sh './script/build_and_run.sh --verify'
expect_block build_and_run.sh 'bash script/build_and_run.sh --print-install-contract'
expect_block verify_installation_isolation.sh 'script/verify_installation_isolation.sh'
expect_block verify_release_configuration.sh 'script/verify_release_configuration.sh'
expect_block verify_launch_stability.sh 'bash script/verify_launch_stability.sh --skip-build'
expect_block verify_ccusage_freshness.sh 'bash script/verify_ccusage_freshness.sh --update'
expect_block git-reset 'git reset --hard origin/main'
expect_block git-clean 'git clean -fd'
expect_block git-stash 'git stash'
expect_block git-checkout 'git checkout -- .'
expect_block rm-recursive 'rm -rf build'
expect_block rm-recursive 'rm -rf ~/Library/Caches/com.jamesli.usagedock'
expect_block rm-recursive 'rm -rf "$HOME/Developer"'
expect_block rm-recursive 'rm -rf /tmp'
expect_block rm-recursive 'rm -r Sources'
expect_block rm-recursive '/bin/rm -Rf ../UsageDock-project'
expect_block security 'security find-generic-password -s "Claude Code-credentials" -w'
expect_block security 'security find-identity -v -p codesigning'
expect_block security 'security find-internet-password -s github.com'
expect_block gh-issue-comment 'gh issue comment 5 --body "thanks"'
expect_block gh-pr-comment 'gh pr comment 5 --body "done"'
expect_block gh-pr-review 'gh pr review 5 --approve'
expect_block gh-api 'gh api repos/o/r/issues/5/comments -f body=hi'
expect_block gh-api 'gh api graphql -f query="mutation { addComment(input: {}) { clientMutationId } }"'
expect_block gh-issue-edit 'gh issue edit 5 --body "rewritten"'
expect_block gh-issue-close 'gh issue close 5'
expect_block gh-issue-create 'gh issue create --title x --body y'
expect_block gh-auth-token 'gh auth token'
expect_block gh-label 'gh label create agent:x'
expect_block sudo 'sudo true'
expect_block killall 'killall UsageDockDev'
expect_block open 'open -a "TokenRemain Dev"'
expect_block curl 'curl -X POST https://api.github.com/repos/o/r/issues -d "{}"'
expect_block dangerous-flag 'codex exec --dangerously-bypass-approvals-and-sandbox "fix it"'
expect_block git-config 'git config --global user.email x@example.invalid'

# The commands lanes actually need must keep working.
expect_allow 'git status --porcelain'
expect_allow 'git fetch origin'
expect_allow 'git switch --detach origin/main'
expect_allow 'git switch -c agent/lane-b-20260928-drift'
expect_allow 'git add docs/agents/knowledge.md && git commit -m "docs(agents): record drift"'
expect_allow 'git push -u origin agent/lane-b-20260928-drift'
expect_allow 'git push origin HEAD:agent/lane-b-20260928-drift 2>&1 | tail -3'
expect_allow 'git tag'
expect_allow 'git tag -l "v1.*"'
expect_allow 'git tag --contains HEAD'
expect_allow 'git stash list'
expect_allow 'git log --oneline -5 > /tmp/agent-log.txt'
expect_allow 'git branch -D agent/lane-b-20260921-drift'
expect_allow 'gh issue list --state open --json number,title,labels --limit 50'
expect_allow 'gh issue view 5 --json title,body,labels'
expect_allow 'gh issue edit 5 --add-label agent:triage,bug'
expect_allow 'gh issue create --title "pstack drift" --label agent:drift --body-file /tmp/body.md'
expect_allow 'gh pr create --draft --title "docs(agents): x" --body-file /tmp/body.md'
expect_allow 'gh pr list --state open --json headRefName'
expect_allow "gh api 'repos/cursor/plugins/commits?path=pstack&per_page=1' --jq '.[0].sha'"
expect_allow "gh api graphql -f query='query { viewer { login } }'"
expect_allow 'gh release list --limit 5'
expect_allow 'gh auth status'
expect_allow 'swift test --no-parallel --filter AccountLoginProcessTests 2>&1 | tail -5'
expect_allow 'npm --prefix broadcast run check'
expect_allow 'npm --prefix broadcast run deploy:dry-run'
expect_allow 'npx wrangler deploy --dry-run'
expect_allow 'bash script/verify_ccusage_freshness.sh --check'
expect_allow 'bash script/verify_agent_docs.sh'
expect_allow 'script/agent_issue.sh upsert --key drift:pstack --label agent:drift --title t --body-file /tmp/b.md'
expect_allow 'rm -rf /tmp/tokenremain-agent-probe'
expect_allow 'rm Tests/UsageDockTests/Fixtures/agent-probe.json'
expect_allow 'find /tmp/agent-run -name "*.log" -delete'
expect_allow 'curl -fsSL https://registry.npmjs.org/@ccusage%2fccusage-darwin-arm64/latest'
expect_allow 'defaults read com.jamesli.usagedock.dev'

# Lane identity: the worktree-private marker, and nothing else.
CASES=$((CASES + 1))
result="$(guard none "$WORK/lane" claude "$(claude_payload 'git push origin main' "$WORK/lane")")"
[[ "${result%%|*}" == "2" ]] || fail "the marker in the lane worktree's git dir must activate the guard -> $result"
CASES=$((CASES + 1))
result="$(guard none "$WORK/main" claude "$(claude_payload 'git push origin main' "$WORK/main")")"
[[ "$result" == "0||" ]] || fail "the lane marker must not leak into the main worktree -> $result"
CASES=$((CASES + 1))
result="$(guard none "$WORK/other-marker" claude "$(claude_payload 'git push origin main' "$WORK/other-marker")")"
[[ "$result" == "0||" ]] || fail "a marker that is not 'unattended' must not activate the guard -> $result"

# Host payload shapes.
CASES=$((CASES + 1))
result="$(guard env "$WORK/plain" cursor '{"command": "gh pr merge 3", "cwd": "/tmp"}')"
[[ "${result%%|*}" == "2" && "$result" == *'"permission": "deny"'* ]] \
  || fail "Cursor payloads must be denied with exit 2 and permission=deny JSON -> $result"
CASES=$((CASES + 1))
result="$(guard env "$WORK/plain" cursor '{"command": "git status", "cwd": "/tmp"}')"
[[ "$result" == "0||" ]] || fail "Cursor allow must print nothing, so Cursor's own approval still applies -> $result"
CASES=$((CASES + 1))
result="$(guard env "$WORK/plain" codex '{"tool_name": "Bash", "tool_input": {"command": ["bash", "-lc", "git push origin main"]}}')"
[[ "${result%%|*}" == "2" ]] || fail "argv-array commands must be inspected -> $result"
CASES=$((CASES + 1))
result="$(guard env "$WORK/plain" claude 'not json')"
[[ "${result%%|*}" == "2" ]] || fail "an unreadable payload must fail closed in a lane -> $result"
CASES=$((CASES + 1))
result="$(guard env "$WORK/plain" claude '{"tool_name": "Read", "tool_input": {"file_path": "AGENTS.md"}}')"
[[ "$result" == "0||" ]] || fail "payloads without a shell command must pass -> $result"
CASES=$((CASES + 1))
result="$(guard none "$WORK/plain" claude 'not json')"
[[ "$result" == "0||" ]] || fail "interactive sessions must not even parse the payload -> $result"

# agent_issue.sh against a gh stand-in: it may only rewrite its own marked issue.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "api user") echo "lane-bot" ;;
  "issue list") cat "$STUB_ISSUES" ;;
  "issue create") echo "https://github.com/o/r/issues/99" ;;
esac
STUB
chmod +x "$WORK/bin/gh"
printf 'drift details\n' > "$WORK/body.md"
issue_case() {
  local name="$1" issues="$2" expect="$3" label="${4:-agent:drift}"
  CASES=$((CASES + 1))
  printf '%s' "$issues" > "$WORK/issues.json"
  : > "$WORK/gh.log"
  PATH="$WORK/bin:$PATH" STUB_LOG="$WORK/gh.log" STUB_ISSUES="$WORK/issues.json" \
    "$ISSUE" upsert --key drift:pstack --label "$label" --title "pstack drift" --body-file "$WORK/body.md" \
    >/dev/null 2>&1 || true
  local calls; calls="$(grep -E '^issue (edit|create)' "$WORK/gh.log" || true)"
  [[ "$calls" == $expect ]] || fail "agent_issue.sh $name: expected '$expect', gh saw '$calls'"
}
marker='<!-- agent-key: drift:pstack -->'
issue_case "creates when none exist" '[]' 'issue create --label agent:drift*'
issue_case "updates its own marked issue" "[{\"number\": 7, \"author\": {\"login\": \"lane-bot\"}, \"body\": \"$marker\\n\\nold\"}]" 'issue edit 7 *'
issue_case "never edits someone else's issue" "[{\"number\": 8, \"author\": {\"login\": \"reporter\"}, \"body\": \"$marker\\n\\nold\"}]" 'issue create *'
issue_case "ignores a different key" "[{\"number\": 9, \"author\": {\"login\": \"lane-bot\"}, \"body\": \"<!-- agent-key: drift:ccusage -->\"}]" 'issue create *'
issue_case "rejects non-agent labels" '[]' '' 'bug'

(( FAILURES == 0 )) || { echo "lane guard self-test: $FAILURES of $CASES checks failed" >&2; exit 1; }
echo "lane guard self-test verified: $CASES checks; every R14 prohibition blocks in a lane and passes interactively"
