#!/usr/bin/env bash
set -euo pipefail

# 代理规则、技能和知识库的结构契约（S 级，只读）。
#
# 规则正文散在 AGENTS.md、CLAUDE.md、.cursor/ 和 docs/ 里，三个宿主又各自通过
# 符号链接发现同一批技能。任何一处改名或挪动都会让另一处静默失效：宿主不会报错，
# 只是读不到规则。所以把"引用能解析、技能能注册、编号自洽"做成检查，而不是靠审查。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

command -v python3 >/dev/null || { echo "agent docs verification failed: python3 is required" >&2; exit 1; }

python3 - <<'PY'
import json, os, pathlib, re, subprocess, sys, unicodedata

root = pathlib.Path(".")
failures = []
def fail(msg): failures.append(msg)

doc_files = [p for p in [root / "AGENTS.md", root / "CLAUDE.md", root / "docs/design-boundaries.md"] if p.exists()]
for pattern in (".cursor/**/*.md", ".cursor/**/*.mdc", "docs/agents/**/*.md"):
    doc_files += sorted(root.glob(pattern))
for required in ("AGENTS.md", "CLAUDE.md", "docs/agents/knowledge.md", "docs/agents/pstack-upstream.json"):
    if not (root / required).exists():
        fail(f"{required} is missing")

def strip_code(text):
    """Drop fenced blocks and inline code so example paths are not treated as links."""
    out, fenced = [], False
    for line in text.splitlines():
        if re.match(r"^\s*(```|~~~)", line):
            fenced = not fenced
            out.append("")
            continue
        out.append("" if fenced else re.sub(r"`[^`]*`", "", line))
    return out

def slug(heading):
    heading = re.sub(r"<[^>]+>", "", heading).strip().lower()
    kept = []
    for ch in heading:
        cat = unicodedata.category(ch)
        if ch in " -_" or cat[0] in "LN" or cat == "Mn":
            kept.append(ch)
    return "".join(kept).replace(" ", "-")

anchor_cache = {}
def anchors(path):
    if path not in anchor_cache:
        found = set()
        for line in strip_code(path.read_text(encoding="utf-8")):
            found.update(re.findall(r'id="([^"]+)"', line))
            m = re.match(r"^#{1,6}\s+(.*)$", line)
            if m:
                found.add(slug(m.group(1)))
        anchor_cache[path] = found
    return anchor_cache[path]

link_count = 0
for doc in doc_files:
    lines = strip_code(doc.read_text(encoding="utf-8"))
    for lineno, line in enumerate(lines, 1):
        targets = re.findall(r"\[[^\]]*\]\(([^)\s]+)\)", line)
        if doc.name == "CLAUDE.md":
            targets += re.findall(r"^@(\S+)\s*$", line)
        for target in targets:
            if re.match(r"^[a-z]+:", target):
                continue
            link_count += 1
            path_part, _, fragment = target.partition("#")
            resolved = (doc.parent / path_part).resolve() if path_part else doc.resolve()
            where = f"{doc}:{lineno}"
            if not resolved.exists():
                fail(f"{where}: link target {target} does not exist")
                continue
            if fragment and resolved.suffix in (".md", ".mdc") and fragment not in anchors(resolved):
                fail(f"{where}: anchor #{fragment} not found in {path_part or doc.name}")

def frontmatter(path):
    text = path.read_text(encoding="utf-8")
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None
    fields = {}
    for line in m.group(1).splitlines():
        km = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if km:
            fields[km.group(1)] = km.group(2).strip().strip('"')
    return fields

skill_names = []
for skill in sorted((root / ".cursor/skills").glob("*/SKILL.md")):
    name = skill.parent.name
    skill_names.append(name)
    fields = frontmatter(skill)
    if fields is None:
        fail(f"{skill}: missing YAML frontmatter; the skill never registers")
        continue
    for key in ("name", "description"):
        if not fields.get(key):
            fail(f"{skill}: frontmatter `{key}` is missing or empty")
    if fields.get("name") and fields["name"] != name:
        fail(f"{skill}: frontmatter name `{fields['name']}` does not match directory `{name}`")
feature_h2 = ["Sub-features", "How to get to it (user POV)", "Driving it with native macOS control", "Gotchas"]
status_pattern = re.compile(r"^\*\*状态：\*\* `(draft|verified @ \d{4}-\d{2}-\d{2} [0-9a-f]{7,40} macOS \d+(\.\d+)* \([0-9A-Za-z]+\))`$", re.M)
for features in sorted((root / ".cursor/skills").glob("*/features")):
    index = features / "README.md"
    listed = set(re.findall(r"\]\(([^)#]+\.md)\)", index.read_text(encoding="utf-8"))) if index.exists() else set()
    if not index.exists():
        fail(f"{features}: README.md index is missing")
    for feature in sorted(features.glob("*.md")):
        if feature.name == "README.md":
            continue
        text = feature.read_text(encoding="utf-8")
        if feature.name not in listed:
            fail(f"{feature}: not listed in {index}")
        if not status_pattern.search(text):
            fail(f"{feature}: needs a status line `**状态：** \\`draft\\`` or `verified @ <date> <sha> macOS <version> (<build>)`")
        h2 = re.findall(r"^## (.+)$", text, re.M)
        if h2 != feature_h2:
            fail(f"{feature}: H2 sections must be exactly {feature_h2}, found {h2}")
    for name in listed:
        if not (features / name).exists():
            fail(f"{index}: lists {name}, which does not exist")
for rule in sorted((root / ".cursor/rules").glob("*.mdc")):
    fields = frontmatter(rule)
    if not fields or not fields.get("description"):
        fail(f"{rule}: frontmatter `description` is missing")

for host_dir in (".claude/skills", ".agents/skills"):
    base = root / host_dir
    present = set()
    if base.is_dir():
        for entry in sorted(base.iterdir()):
            present.add(entry.name)
            expected = f"../../.cursor/skills/{entry.name}"
            if not entry.is_symlink():
                fail(f"{entry}: must be a symlink to {expected}, not a copy")
            elif os.readlink(entry) != expected:
                fail(f"{entry}: points to {os.readlink(entry)}, expected {expected}")
            elif not (entry / "SKILL.md").is_file():
                fail(f"{entry}: symlink does not resolve to a skill")
    for name in skill_names:
        if name not in present:
            fail(f"{host_dir}/{name}: missing link; this host cannot discover the skill")

upstream_path = root / "docs/agents/pstack-upstream.json"
if upstream_path.exists():
    try:
        upstream = json.loads(upstream_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        upstream = None
        fail(f"{upstream_path}: invalid JSON ({error})")
    if upstream is not None:
        schema = {
            "repo": lambda v: isinstance(v, str) and re.fullmatch(r"[\w.-]+/[\w.-]+", v),
            "path": lambda v: isinstance(v, str) and v and not v.startswith("/"),
            "commit": lambda v: isinstance(v, str) and re.fullmatch(r"[0-9a-f]{40}", v),
            "version": lambda v: isinstance(v, str) and re.fullmatch(r"\d+\.\d+\.\d+", v),
            "reviewed_at": lambda v: isinstance(v, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", v),
            "reviewed_by_pr": lambda v: v is None or (isinstance(v, int) and not isinstance(v, bool) and v > 0),
        }
        if not isinstance(upstream, dict) or set(upstream) != set(schema):
            fail(f"{upstream_path}: keys must be exactly {sorted(schema)}")
        else:
            for key, valid in schema.items():
                if not valid(upstream[key]):
                    fail(f"{upstream_path}: `{key}` has an invalid value {upstream[key]!r}")

agents = (root / "AGENTS.md").read_text(encoding="utf-8") if (root / "AGENTS.md").exists() else ""
defined = [int(n) for n in re.findall(r"^### R(\d+)\.", agents, re.M)]
if defined != list(range(1, len(defined) + 1)):
    fail(f"AGENTS.md: rule headings must run R1..R{len(defined)} without gaps or duplicates, found {defined}")
db_ids = anchors(root / "docs/design-boundaries.md") if (root / "docs/design-boundaries.md").exists() else set()
for doc in doc_files:
    for lineno, line in enumerate(doc.read_text(encoding="utf-8").splitlines(), 1):
        for n in re.findall(r"(?<![A-Za-z0-9/])R(\d{1,2})(?![0-9])", line):
            if int(n) not in defined:
                fail(f"{doc}:{lineno}: references R{n}, which AGENTS.md does not define")
        for n in re.findall(r"\bDB-(\d{3})\b", line):
            if f"db-{n}" not in db_ids:
                fail(f"{doc}:{lineno}: references DB-{n}, which docs/design-boundaries.md does not define")

guard = "script/agent_lane_guard.sh"
for hook_file in (".claude/settings.json", ".codex/hooks.json", ".cursor/hooks.json"):
    path = root / hook_file
    if not path.exists():
        continue
    try:
        text = json.dumps(json.loads(path.read_text(encoding="utf-8")))
    except json.JSONDecodeError as error:
        fail(f"{hook_file}: invalid JSON ({error})")
        continue
    if guard not in text:
        fail(f"{hook_file}: does not invoke {guard}")
for script in sorted(root.glob("script/*agent*.sh")):
    if not os.access(script, os.X_OK):
        fail(f"{script}: must be executable")
    if subprocess.run(["bash", "-n", str(script)], capture_output=True).returncode != 0:
        fail(f"{script}: bash -n reports a syntax error")

if failures:
    for message in failures:
        print(f"agent docs verification failed: {message}", file=sys.stderr)
    sys.exit(1)
print(f"agent docs verified: {len(doc_files)} documents, {link_count} links, "
      f"{len(skill_names)} skills linked for Claude Code and Codex, R1..R{len(defined)} consistent")
PY
