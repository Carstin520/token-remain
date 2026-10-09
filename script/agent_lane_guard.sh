#!/usr/bin/env bash
set -uo pipefail

# 无人值守 lane 的命令护栏（AGENTS.md R14）。由 Claude Code / Codex 的 PreToolUse(Bash)
# hook 和 Cursor 的 beforeShellExecution hook 调用：stdin 是宿主的 JSON，exit 2 表示拒绝。
#
# 只在 lane 中生效。lane 身份二选一：
#   * 环境变量 TOKENREMAIN_AGENT_LANE=unattended；
#   * 会话所在 worktree 的私有 git 目录里有内容为 unattended 的 tokenremain-agent-lane。
# 第二种存在的原因：Codex 定时任务和 Cursor hook 都没有文档保证能传递环境变量，
# 而 linked worktree 的 git 目录只属于那一个 worktree，不会波及交互会话。
#
# 交互会话里本脚本在解析 JSON 之前就放行，不改变任何人的日常工作。
# 这是纵深防御，不是沙箱：没被拦下的命令不等于获得授权。

HOST="claude"
if [[ "${1:-}" == "--host" && -n "${2:-}" ]]; then
  HOST="$2"
fi

lane_active() {
  [[ "${TOKENREMAIN_AGENT_LANE:-}" == "unattended" ]] && return 0
  local dir="${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-$PWD}}"
  local git_dir marker
  git_dir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  marker="$git_dir/tokenremain-agent-lane"
  [[ -f "$marker" ]] && [[ "$(tr -d '[:space:]' < "$marker")" == "unattended" ]]
}

lane_active || exit 0

if ! command -v python3 >/dev/null; then
  echo "[agent-lane-guard] blocked: python3 is missing, so lane commands cannot be inspected (AGENTS.md R14)." >&2
  exit 2
fi

GUARD_PAYLOAD="$(cat)" GUARD_HOST="$HOST" GUARD_CWD="$PWD" exec python3 - <<'PY'
import json, os, posixpath, re, shlex, sys

HOST = os.environ["GUARD_HOST"]
TEMP_ROOTS = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/",
              os.path.expanduser("~/.tokenremain-agent/tmp/")]
if os.environ.get("TMPDIR"):
    TEMP_ROOTS.append(os.environ["TMPDIR"].rstrip("/") + "/")


class Blocked(Exception):
    def __init__(self, rule, why, segment):
        super().__init__(why)
        self.rule, self.why, self.segment = rule, why, segment


def deny(rule, why, segment):
    command = " ".join(segment)[:200]
    message = (f"[agent-lane-guard] blocked {rule}: {why}. Command: {command}. "
               "Unattended lanes may not do this (AGENTS.md R14). Stop this action and record it "
               "in the run report; do not look for another way to run it.")
    if HOST == "cursor":
        print(json.dumps({"permission": "deny", "user_message": message, "agent_message": message}))
    print(message, file=sys.stderr)
    sys.exit(2)


SEPARATORS = {";", "&&", "||", "|", "&", "|&", "(", ")", ";;"}
REDIRECTS = {">", ">>", "<", "<<", "<<<", ">&", "&>", "&>>", "<&", ">|", "<>"}


def newline_to_separator(command):
    out, quote, escaped = [], None, False
    for ch in command:
        if escaped:
            out.append(ch); escaped = False; continue
        if ch == "\\" and quote != "'":
            out.append(ch); escaped = True; continue
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "\n":
            out.append(" ; "); continue
        out.append(ch)
    return "".join(out)


def is_redirect(token):
    return token in REDIRECTS or (token not in SEPARATORS and re.fullmatch(r"[<>&]+", token) is not None)


def substitutions(token):
    found = re.findall(r"\$\(([^()]*(?:\([^()]*\)[^()]*)*)\)", token)
    found += re.findall(r"`([^`]*)`", token)
    found += re.findall(r"[<>]\(([^()]*)\)", token)
    return found


def segments(command, depth=0):
    if depth > 6:
        raise Blocked("nesting", "command nesting is too deep to inspect", [command])
    lexer = shlex.shlex(newline_to_separator(command), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
    current, i = [], 0
    while i < len(tokens):
        token = tokens[i]
        if token in SEPARATORS:
            if current:
                yield current
            current = []
        elif is_redirect(token):
            i += 2
            continue
        elif token.isdigit() and i + 1 < len(tokens) and is_redirect(tokens[i + 1]):
            i += 1
            continue
        else:
            current.append(token)
        i += 1
    if current:
        yield current
    for inner in substitutions(command):
        yield from segments(inner, depth + 1)


ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = {"command", "builtin", "exec", "nohup", "time", "caffeinate", "stdbuf"}
SHELL_KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"}


def unwrap(segment, depth):
    args = list(segment)
    while args:
        head = posixpath.basename(args[0])
        if ASSIGNMENT.match(args[0]) or args[0] in SHELL_KEYWORDS:
            args = args[1:]
        elif head == "env":
            args = args[1:]
            while args and (args[0].startswith("-") or ASSIGNMENT.match(args[0])):
                args = args[1:]
        elif head in WRAPPERS:
            args = args[1:]
            while args and args[0].startswith("-"):
                args = args[1:]
        elif head == "nice":
            args = args[1:]
            if args[:1] == ["-n"]:
                args = args[2:]
        elif head in ("timeout", "gtimeout"):
            args = args[1:]
            while args and args[0].startswith("-"):
                args = args[1:]
            args = args[1:]
        elif head == "xargs":
            args = args[1:]
            while args and args[0].startswith("-"):
                takes_value = args[0] in ("-I", "-n", "-P", "-L", "-s", "-E", "-d")
                args = args[2:] if takes_value else args[1:]
        elif head in ("npx", "bunx", "pnpx"):
            args = args[1:]
            while args and args[0].startswith("-"):
                args = args[1:]
        elif head in ("npm", "pnpm") and len(args) > 1 and args[1] in ("exec", "x", "dlx"):
            args = args[2:]
            while args and args[0].startswith("-"):
                args = args[1:]
        elif head in ("bash", "sh", "zsh", "dash", "ksh") and len(args) > 1:
            flags = [a for a in args[1:] if a.startswith("-") and not a.startswith("--")]
            if any("c" in f for f in flags):
                idx = next(i for i, a in enumerate(args[1:], 1) if a.startswith("-") and "c" in a)
                if idx + 1 < len(args):
                    return ("recurse", args[idx + 1])
                return ("args", [])
            j = 1
            while j < len(args) and args[j].startswith("-"):
                j += 1
            args = args[j:]
        elif head == "eval":
            return ("recurse", " ".join(args[1:]))
        else:
            break
    return ("args", args)


def first_positional(args, value_flags=()):
    i = 0
    while i < len(args):
        if args[i] in value_flags:
            i += 2
            continue
        if args[i].startswith("-"):
            i += 1
            continue
        return i
    return None


def has_flag(args, *names):
    for a in args:
        for n in names:
            if a == n or (n.startswith("--") and a.startswith(n + "=")):
                return True
            if len(n) == 2 and n.startswith("-") and re.fullmatch(r"-[A-Za-z]+", a) and n[1] in a[1:]:
                return True
    return False


def check_git(args, seg):
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-C", "-c") else 1
    if i >= len(args):
        return
    sub, rest = args[i], args[i + 1:]
    if sub == "push":
        if has_flag(rest, "--force", "-f", "--force-with-lease", "--force-if-includes", "--mirror",
                    "--all", "--tags", "--delete", "-d", "--prune"):
            raise Blocked("git-push", "lanes push only new agent/* branches, without force, delete, mirror or tags", seg)
        positional = [a for a in rest if not a.startswith("-")]
        refspecs = positional[1:]
        if not refspecs:
            raise Blocked("git-push", "name an explicit agent/* refspec; a bare push can reach main", seg)
        for spec in refspecs:
            if spec.startswith("+"):
                raise Blocked("git-push", "a + refspec is a force push", seg)
            src, _, dst = spec.partition(":")
            target = dst if dst else src
            if not src or target == "HEAD":
                raise Blocked("git-push", "the destination must be an explicit agent/* branch", seg)
            target = target.removeprefix("refs/heads/")
            if not target.startswith("agent/"):
                raise Blocked("git-push", f"destination {target} is not an agent/* branch", seg)
    elif sub == "tag":
        listing = has_flag(rest, "-l", "--list", "--contains", "--no-contains", "--points-at", "--merged", "--no-merged") or not rest
        mutating = has_flag(rest, "-d", "--delete", "-a", "--annotate", "-s", "--sign", "-f", "--force", "-m", "-F")
        if not listing or mutating:
            raise Blocked("git-tag", "lanes do not create, move or delete tags", seg)
    elif sub == "reset" and has_flag(rest, "--hard", "--merge", "--keep"):
        raise Blocked("git-reset", "reset --hard discards work (R1)", seg)
    elif sub == "clean" and not has_flag(rest, "-n", "--dry-run"):
        raise Blocked("git-clean", "git clean deletes untracked files (R1); remove only files this run created, by name", seg)
    elif sub == "stash" and not (rest[:1] in (["list"], ["show"])):
        raise Blocked("git-stash", "lanes do not stash; a dirty lane worktree is a stop condition", seg)
    elif sub in ("checkout", "switch") and (has_flag(rest, "-f", "--force", "--discard-changes") or "." in rest or "--" in rest):
        raise Blocked("git-checkout", "discarding working-tree changes is not allowed (R1)", seg)
    elif sub == "restore" and not (has_flag(rest, "--staged", "-S") and not has_flag(rest, "--worktree", "-W")):
        raise Blocked("git-restore", "restoring the working tree discards changes (R1)", seg)
    elif sub == "worktree" and rest[:1] == ["remove"] and has_flag(rest, "-f", "--force"):
        raise Blocked("git-worktree", "force-removing a worktree can destroy uncommitted work (R1)", seg)
    elif sub == "branch" and has_flag(rest, "-d", "-D", "--delete"):
        names = [a for a in rest if not a.startswith("-")]
        if not names or any(not n.startswith("agent/") for n in names):
            raise Blocked("git-branch", "lanes delete only their own agent/* branches", seg)
    elif sub == "config" and has_flag(rest, "--global", "--system"):
        raise Blocked("git-config", "global git configuration is out of bounds (R11)", seg)


GH_ALLOWED = {
    "pr": {"list", "view", "status", "checks", "diff", "checkout", "create", "edit", "ready"},
    "issue": {"list", "view", "status", "create", "edit"},
    "release": {"list", "view"},
    "label": {"list"},
    "repo": {"view", "list", "clone"},
    "workflow": {"list", "view"},
    "run": {"list", "view", "watch"},
    "gist": {"list", "view"},
    "search": None, "status": None, "api": None, "auth": {"status"},
}
LABEL_FLAGS = ("--add-label", "--remove-label")


def only_label_flags(args):
    i, flags = 0, []
    while i < len(args):
        if args[i].startswith("-"):
            name = args[i].split("=")[0]
            flags.append(name)
            i += 1 if "=" in args[i] else 2
        else:
            i += 1
    return flags and all(f in LABEL_FLAGS for f in flags)


def flag_values(args, *names):
    values = []
    for i, a in enumerate(args):
        for n in names:
            if a == n and i + 1 < len(args):
                values.append(args[i + 1])
            elif a.startswith(n + "="):
                values.append(a.split("=", 1)[1])
    return values


def check_gh(args, seg):
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-R", "--repo") else 1
    if i >= len(args):
        return
    group, rest = args[i], args[i + 1:]
    if group not in GH_ALLOWED:
        raise Blocked(f"gh-{group}", f"`gh {group}` is outside the lane allowlist", seg)
    allowed = GH_ALLOWED[group]
    sub = rest[0] if rest else ""
    if allowed is not None and sub not in allowed:
        raise Blocked(f"gh-{group}-{sub or 'none'}", f"`gh {group} {sub}` is not allowed in a lane (merge, comment, close, release and similar stay with people)", seg)
    tail = rest[1:]
    if group == "pr" and sub == "create" and not has_flag(tail, "--draft", "-d"):
        raise Blocked("gh-pr-create", "lane PRs must be opened with --draft", seg)
    if group == "pr" and sub == "ready" and not has_flag(tail, "--undo"):
        raise Blocked("gh-pr-ready", "lane PRs stay draft; only `gh pr ready --undo` is allowed", seg)
    if group in ("pr", "issue") and sub == "edit" and not only_label_flags(tail):
        raise Blocked(f"gh-{group}-edit", "lanes may only add or remove labels; update agent issues with script/agent_issue.sh", seg)
    if group == "issue" and sub == "create":
        labels = ",".join(flag_values(tail, "--label", "-l")).split(",")
        if not any(label.strip().startswith("agent:") for label in labels):
            raise Blocked("gh-issue-create", "lanes create only agent:* tracking issues (pass --label agent:...)", seg)
    if group == "api":
        method = [m.upper() for m in flag_values(rest, "-X", "--method")]
        body = has_flag(rest, "-f", "-F", "--field", "--raw-field", "--input")
        endpoint = next((a for a in rest if not a.startswith("-")), "")
        if endpoint == "graphql":
            if any("mutation" in a.lower() for a in rest):
                raise Blocked("gh-api", "GraphQL mutations are not allowed in a lane", seg)
        elif any(m != "GET" for m in method) or body:
            raise Blocked("gh-api", "lanes use gh api for reads only", seg)
        if re.search(r"/(merge|comments|reviews)(\b|/|$)", endpoint) and (method or body):
            raise Blocked("gh-api", "merging, commenting and reviewing stay with people", seg)


RELEASE_SCRIPTS = {
    "package_developer_id_release.sh": "release packaging is a P-level operation",
    "build_and_run.sh": "build_and_run.sh stops, installs and launches the app (D-level, R8)",
    "build_app_store_candidate.sh": "App Store candidate builds sign with real identities",
    "verify_launch_stability.sh": "launch stability installs and kills app processes (D-level, R8)",
    "verify_installation_isolation.sh": "calls build_and_run.sh --print-install-contract, which deletes dist/ bundles",
    "verify_release_configuration.sh": "runs ccusage --update, which rewrites Vendor/",
}


def under_temp(path, cwd):
    if "$" in path or path.startswith("~") and not path.startswith("~/"):
        return False
    path = os.path.expanduser(path)
    if not path.startswith("/"):
        path = posixpath.join(cwd, path)
    norm = posixpath.normpath(path) + "/"
    return any(norm.startswith(root) and norm != root for root in TEMP_ROOTS)


def check_segment(segment, cwd, depth=0):
    kind, value = unwrap(segment, depth)
    if kind == "recurse":
        for inner in segments(value, depth + 1):
            check_segment(inner, cwd, depth + 1)
        return
    args = value
    if not args:
        return
    if "tokenremain-lane-guard-canary" in args:
        raise Blocked("canary", "the lane preflight canary is blocked on purpose; the guard is active", segment)
    if any(a.startswith("--dangerously") for a in args):
        raise Blocked("dangerous-flag", "--dangerously-* flags disable another agent's safety checks", segment)
    head = posixpath.basename(args[0])
    rest = args[1:]
    if head in RELEASE_SCRIPTS:
        raise Blocked(head, RELEASE_SCRIPTS[head], segment)
    if head == "verify_ccusage_freshness.sh" and "--update" in rest:
        raise Blocked(head, "--update rewrites Vendor/; lanes use --check", segment)
    if re.search(r"\.app/Contents/MacOS/", args[0]):
        raise Blocked("app-binary", "launching the app is D-level (R8)", segment)
    if head == "git":
        check_git(rest, segment)
    elif head == "gh":
        check_gh(rest, segment)
    elif head == "wrangler":
        sub = rest[0] if rest else ""
        dry = "--dry-run" in rest and sub in ("deploy", "versions")
        if not (dry or sub in ("--version", "-v", "types", "--help", "-h")):
            raise Blocked("wrangler", "wrangler can deploy or touch production data; only --dry-run and types are allowed", segment)
    elif head in ("npm", "pnpm", "yarn", "bun"):
        if has_flag(rest, "-g", "--global"):
            raise Blocked(f"{head}-global", "global installs change the machine, not the repo (R11)", segment)
        positional = [a for i, a in enumerate(rest) if not a.startswith("-") and not (i > 0 and rest[i - 1] in ("--prefix", "-C", "--cwd", "--dir", "-w", "--workspace"))]
        script = None
        if positional[:1] == ["publish"]:
            raise Blocked(f"{head}-publish", "publishing packages is a release operation", segment)
        if positional[:1] in (["run"], ["run-script"]) and len(positional) > 1:
            script = positional[1]
        elif head in ("yarn", "pnpm", "bun") and positional:
            script = positional[0]
        if script and re.match(r"^(deploy|release|publish)(:|$)", script) and "dry-run" not in script:
            raise Blocked(f"{head}-{script}", "deploy/release scripts reach production", segment)
    elif head == "rm":
        recursive = has_flag(rest, "-r", "-R", "--recursive")
        targets = [a for a in rest if not a.startswith("-")]
        if recursive and (not targets or not all(under_temp(t, cwd) for t in targets)):
            raise Blocked("rm-recursive", "recursive delete outside a temp directory", segment)
    elif head == "find" and ("-delete" in rest or any(posixpath.basename(a) == "rm" for a in rest)):
        roots = [a for a in rest if not a.startswith("-")][:1]
        if not roots or not under_temp(roots[0], cwd):
            raise Blocked("find-delete", "deleting files outside a temp directory", segment)
    elif head == "security":
        raise Blocked("security", "lanes never read or change Keychain items or identities (R3)", segment)
    elif head == "sudo":
        raise Blocked("sudo", "privilege escalation is out of bounds", segment)
    elif head in ("killall", "pkill"):
        raise Blocked(head, "killing processes by name can stop someone else's instance (R8)", segment)
    elif head == "open":
        raise Blocked("open", "opening apps or URLs is outside unattended lanes (D-level, R8)", segment)
    elif head == "defaults" and rest[:1] and rest[0] in ("write", "delete", "import", "rename"):
        raise Blocked("defaults", "changing app preferences is D-level (R8)", segment)
    elif head in ("curl", "wget"):
        method = [m.upper() for m in flag_values(rest, "-X", "--request", "--method")]
        body = has_flag(rest, "-d", "-F", "-T", "--data", "--data-raw", "--data-binary", "--data-urlencode",
                        "--form", "--upload-file", "--json", "--post-data", "--post-file")
        if body or any(m not in ("GET", "HEAD") for m in method):
            raise Blocked(head, "lanes use HTTP for reads only", segment)


def main():
    try:
        payload = json.loads(os.environ.get("GUARD_PAYLOAD") or "{}")
    except json.JSONDecodeError:
        deny("payload", "the hook payload is not valid JSON, so the command cannot be inspected", ["<unparsed>"])
    command = ""
    if isinstance(payload, dict):
        tool_input = payload.get("tool_input")
        if isinstance(tool_input, dict):
            command = tool_input.get("command") or ""
        command = command or payload.get("command") or ""
    if isinstance(command, list) and all(isinstance(part, str) for part in command):
        command = shlex.join(command)
    if not isinstance(command, str):
        deny("payload", "the command field has an unexpected shape", ["<unparsed>"])
    if not command.strip():
        return
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.environ["GUARD_CWD"]
    try:
        for segment in segments(command):
            check_segment(segment, cwd)
    except Blocked as blocked:
        deny(blocked.rule, blocked.why, blocked.segment)
    except ValueError as error:
        deny("parse", f"the command cannot be tokenized ({error})", [command])


main()
PY
