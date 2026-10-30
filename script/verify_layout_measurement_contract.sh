#!/usr/bin/env bash
set -euo pipefail

# 布局测量不得回写被测视图或兄弟视图的尺寸（S 级，只读）。
#
# "量出尺寸 → 写进 @State → 再参与布局"是 SwiftUI 里最顺手的写法，也是本仓库
# 反复出现的卡死根因：
#   * issue #34：SwiftUI 量出的尺寸推回 NSWindow，布局回合重入自己直到栈溢出。
#     窗口一侧由 verify_launch_surface_isolation.sh 守着，本脚本不重复；
#   * 拖拽重排：几何回调读到弹簧动画中的位置又喂回 frames，测量和 offset 互相
#     追赶（DirectReorderInteraction.updateFrame 的守卫）；
#   * 1.4.7 (46)：Limits 的 LazyVGrid 把每张卡片的自然高度写进 @State，再把同排
#     卡片撑到最高值。滚动时懒容器重建卡片、清空卡内测量，循环始终不收敛，主线程
#     100% CPU，内存涨到数 GB。PR #98 改为 QuotaGridLayout，一次布局算出行高。
#
# 一处写回会不会收敛取决于数据流，正则证明不了。所以本脚本只做三件能做准的事：
#   1. 登记：Sources/UsageDock 里每一处把几何量转成回调的地方都必须登记在
#      REGISTRY，写明它为什么不会改变被测视图或兄弟视图的尺寸。新增、删除一处或
#      把它挪到别的文件都会失败，逼改动者重新论证，而不是默默放行；
#   2. 懒容器：LazyVGrid/LazyHGrid/LazyVStack/LazyHStack/List 的内容里不得直接
#      出现测量点，也不得直接使用含测量点的视图或修饰符。懒容器滚动时会销毁、
#      重建子视图并重置其 @State，测量值没有机会稳定（46 就是这种结构）；
#   3. 钉住：登记理由依赖的代码形状（拖拽期间冻结 frames、QuotaCard 内容按自然
#      高度布局）被改掉时失败。
#
# 不覆盖：测量点之间的真实数据流；跨多层视图的懒容器嵌套（只查懒容器内容里
# 直接出现的视图和修饰符）；AppKit 侧的 frame 观察和 fittingSize 读取；私有
# extension 里的测量修饰符。通过计算属性复用的探针只按定义计一处，通过函数复用
# 的探针按调用处计数。收敛本身要靠 D 级验证：滚动、缩放窗口时 CPU 回落、内存
# 不涨，见 docs/design-boundaries.md 的 DB-002。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

command -v python3 >/dev/null || { echo "layout measurement contract failed: python3 is required" >&2; exit 1; }

python3 - <<'PY'
import pathlib, re, sys, tempfile
from collections import Counter

# (文件, 测量方式, 处数, 为什么不会回写被测视图或兄弟视图的尺寸)
REGISTRY = [
    ("Sources/UsageDock/Interaction/DirectReorderInteraction.swift", "onGeometryChange", 2,
     "把手与卡片的 frame 只供拖拽命中和 offset，不改任何视图尺寸；拖动期间 updateFrame 冻结 frames"),
    ("Sources/UsageDock/Views/Popover/LiquidGlassScrollView.swift", "onGeometryChange", 2,
     "内容高度、视口高度和滚动位置只驱动 overlay 里的指示条，overlay 不参与布局"),
    ("Sources/UsageDock/Views/UsageMenuView.swift", "onGeometryChange", 2,
     "footer 高度只给设置浮层(overlay)留边；外层高度交给 AppKit 窗口，被测的是 .frame(height:) 之后的定值，与窗口尺寸无关"),
    ("Sources/UsageDock/Views/UsageMenuView.swift", "GeometryReader probe", 1,
     "量的是 LiquidGlassScrollView 内的内容高度；滚动视图不限制内容高度，外层 .frame(height:) 改不了被测值"),
    ("Sources/UsageDock/Views/UsageMenuView.swift", "onPreferenceChange", 1,
     "接收上一项探针的高度，理由同上"),
    ("Sources/UsageDock/Views/QuotaCard.swift", "GeometryReader probe via heightReader()", 1,
     "量 contentStack 的自然高度决定是否套内层 ScrollView；内容按自然高度布局(fixedSize)，ScrollView 只会让内容更窄更高，判定不会来回翻转"),
]

# 登记理由依赖的代码形状。匹配在去掉注释、字符串并把空白折叠成单空格的代码上做。
PINS = [
    ("Sources/UsageDock/Interaction/DirectReorderInteraction.swift",
     r"func updateFrame\([^)]*\) \{ guard activeItem == nil else \{ return \}",
     "updateFrame 必须先判断 activeItem == nil：拖动期间不再接受几何回调，否则测量会追着弹簧动画跑"),
    ("Sources/UsageDock/Views/QuotaCard.swift",
     r"\.frame\(minHeight: Self\.minimumContentHeight, alignment: \.top\) "
     r"\.fixedSize\(horizontal: false, vertical: true\) \.frame\(maxHeight: \.infinity, alignment: \.top\)",
     "QuotaCard 内容必须先按自然高度布局(fixedSize)再填满行高，否则行高会传进卡内测量（PR #98）"),
]

CALLBACK = re.compile(r"\.(onGeometryChange|onPreferenceChange|onScrollGeometryChange)\s*\(")
GEOMETRY_READER = re.compile(r"\bGeometryReader\s*\{\s*\(?\s*(\w+)(?:\s*:\s*GeometryProxy)?\s*\)?\s+in\b")
REPORT = re.compile(r"\.(?:onAppear|onDisappear|task|onChange|preference)\b")
LAZY = re.compile(r"\b(LazyVGrid|LazyHGrid|LazyVStack|LazyHStack|List)\b")
DECL = re.compile(
    r"((?:(?:@[\w.]+(?:\([^()]*\))?|public|internal|private|fileprivate|final|open)\s+)*)"
    r"\b(struct|class|enum|extension|actor|protocol)\s+([A-Za-z_][\w.]*)"
)
FUNC = re.compile(r"((?:\b(?:private|fileprivate|static|public|internal)\s+)*)\bfunc\s+(\w+)")


def code_view(text):
    """Blank comments and string literals (keeping newlines) so offsets and lines still match."""
    out, n = list(text), len(text)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    def interpolation_end(j):
        depth = 0
        while j < n:
            c = text[j]
            if c == '"' or (c == "#" and re.match(r'#+"', text[j:j + 8])):
                j = string_end(j)
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        return n

    def string_end(i):
        j = i
        while j < n and text[j] == "#":
            j += 1
        hashes = j - i
        quote = '"""' if text.startswith('"""', j) else '"'
        close = quote + "#" * hashes
        j += len(quote)
        while j < n:
            if text.startswith(close, j):
                return j + len(close)
            if text[j] == "\\":
                if hashes == 0 and j + 1 < n and text[j + 1] == "(":
                    j = interpolation_end(j + 1)
                    continue
                j += 2
                continue
            if text[j] == "\n" and quote == '"':
                return j
            j += 1
        return n

    i = 0
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
        elif text[i] == '"' or (text[i] == "#" and re.match(r'#+"', text[i:i + 8])):
            j = string_end(i)
        else:
            i += 1
            continue
        blank(i, j)
        i = j
    return "".join(out)


def matching(code, i, opener, closer):
    depth = 0
    for j in range(i, len(code)):
        if code[j] == opener:
            depth += 1
        elif code[j] == closer:
            depth -= 1
            if depth == 0:
                return j
    return len(code) - 1


def block_after(code, i):
    """The `{...}` that follows position i outside any parentheses, e.g. a trailing closure."""
    depth = 0
    for j in range(i, len(code)):
        c = code[j]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
            if depth < 0:
                return None
        elif c == "{" and depth == 0:
            return j, matching(code, j, "{", "}")
        elif c == "}" and depth == 0:
            return None
    return None


def call_extent(code, i):
    """End of a modifier call that starts right after `.name`: its (...) and trailing {...}."""
    j = i
    while j < len(code) and code[j].isspace():
        j += 1
    if j < len(code) and code[j] == "(":
        j = matching(code, j, "(", ")") + 1
    k = j
    while k < len(code) and code[k].isspace():
        k += 1
    if k < len(code) and code[k] == "{":
        j = matching(code, k, "{", "}") + 1
    return j


class Source:
    def __init__(self, root, path):
        self.path = path
        self.code = code_view((root / path).read_text(encoding="utf-8"))
        depth, self.depth = 0, []
        for c in self.code:
            self.depth.append(depth)
            depth += (c == "{") - (c == "}")
        self.decls = []
        for m in DECL.finditer(self.code):
            if self.depth[m.start(2)] != 0:
                continue
            block = block_after(self.code, m.end())
            if block:
                private = re.search(r"\b(private|fileprivate)\b", m.group(1)) is not None
                self.decls.append((m.group(2), m.group(3).split(".")[-1], private, block[0], block[1]))

    def line(self, pos):
        return self.code.count("\n", 0, pos) + 1

    def decl_at(self, pos):
        return next((d for d in self.decls if d[3] <= pos <= d[4]), None)

    def funcs(self, start, end):
        for m in FUNC.finditer(self.code, start, end):
            block = block_after(self.code, m.end())
            if block:
                yield m.group(2), "private" in m.group(1), block[0], block[1]


def scan(root):
    files = sorted(p.relative_to(root).as_posix() for p in (root / "Sources/UsageDock").rglob("*.swift"))
    sources = {path: Source(root, path) for path in files}
    sites = []  # (path, kind, pos)
    for src in sources.values():
        code = src.code
        for m in CALLBACK.finditer(code):
            sites.append((src.path, m.group(1), m.start()))
        for m in GEOMETRY_READER.finditer(code):
            if m.group(1) == "_":
                continue
            body_end = matching(code, m.start() + m.group(0).index("{"), "{", "}")
            # 只读 proxy 画图的容器不算；回调里用到 proxy（或由它算出的局部量）才是探针。
            names = {m.group(1)} | set(re.findall(
                rf"\blet\s+(\w+)\s*=[^\n]*\b{m.group(1)}\b", code[m.end():body_end]
            ))
            measured = re.compile(r"\b(?:" + "|".join(map(re.escape, sorted(names))) + r")\b")
            if not any(
                measured.search(code[r.end():call_extent(code, r.end())])
                for r in REPORT.finditer(code, m.end(), body_end)
            ):
                continue
            helper = None
            for name, private, start, end in src.funcs(0, len(code)):
                if start < m.start() < end and name != "body":
                    helper = (name, private, start)
            if helper is None:
                sites.append((src.path, "GeometryReader probe", m.start()))
                continue
            name, private, _ = helper
            callers = [src] if private else list(sources.values())
            calls = [
                (caller.path, c.start())
                for caller in callers
                for c in re.finditer(rf"(?<!func )\b{re.escape(name)}\s*[({{]", caller.code)
            ]
            for path, pos in calls or [(src.path, m.start())]:
                sites.append((path, f"GeometryReader probe via {name}()", pos))

    # 含测量点的视图和修饰符：测量点所在的非私有类型、非私有 extension 函数；
    # 私有类型则取同文件里直接使用它的非私有类型或 extension 函数（修饰符）。
    measuring = {}  # regex -> label
    def type_ref(name):
        measuring[rf"\b{name}\b(?:\s*<[^<>{{}}]*>)?\s*[({{]"] = name
    def modifier_ref(name):
        measuring[rf"\.{name}\s*\("] = f".{name}()"

    for path, kind, pos in sites:
        src = sources[path]
        decl = src.decl_at(pos)
        if decl is None:
            continue
        decl_kind, name, private, start, end = decl
        if decl_kind == "extension":
            for func, func_private, fstart, fend in src.funcs(start, end):
                if not (private or func_private) and fstart <= pos <= fend:
                    modifier_ref(func)
        elif not private:
            type_ref(name)
        else:
            for other_kind, other_name, other_private, ostart, oend in src.decls:
                if other_private or ostart == start or not re.search(rf"\b{name}\b", src.code[ostart:oend]):
                    continue
                if other_kind != "extension":
                    type_ref(other_name)
                    continue
                for func, func_private, fstart, fend in src.funcs(ostart, oend):
                    if not func_private and re.search(rf"\b{name}\b", src.code[fstart:fend]):
                        modifier_ref(func)

    lazy_violations = []
    lazy_count = 0
    for src in sources.values():
        for m in LAZY.finditer(src.code):
            block = block_after(src.code, m.end())
            if not block:
                continue
            lazy_count += 1
            start, end = block
            where = f"{src.path}:{src.line(m.start())} 的 {m.group(1)}"
            for path, kind, pos in sites:
                if path == src.path and start < pos < end:
                    lazy_violations.append((m.group(1), kind, f"{where} 内直接有 {kind}（第 {src.line(pos)} 行）"))
            body = src.code[start:end]
            for pattern, label in measuring.items():
                if re.search(pattern, body):
                    lazy_violations.append((m.group(1), label, f"{where} 内使用了含测量点的 {label}"))
    return sources, sites, lazy_violations, lazy_count


def collapsed(code):
    return re.sub(r"\s+", " ", code)


def self_test():
    """The scanner must still see the shapes this contract is about; a regex that rots passes everything."""
    files = {
        "Card.swift": """
            struct Card: View {
                @State private var height: CGFloat = 0
                var body: some View {
                    VStack { Text("a") }
                        .background(heightReader { height = $0 })
                        .background(heightReader { _ in })
                        // .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in }
                        .help(".onGeometryChange(for:")
                }
                private func heightReader(_ update: @escaping (CGFloat) -> Void) -> some View {
                    GeometryReader { proxy in
                        Color.clear.onAppear { update(proxy.size.height) }
                    }
                }
            }
            """,
        "Bar.swift": """
            struct Bar: View {
                var body: some View {
                    GeometryReader { geo in
                        Capsule().frame(width: geo.size.width).onAppear { print("drawn") }
                    }
                    GeometryReader { _ in Color.clear.onAppear { } }
                }
            }
            private struct Probe: View {
                let report: (CGFloat) -> Void
                var body: some View {
                    GeometryReader { (geo: GeometryProxy) in
                        let height = geo.size.height
                        Color.clear.onChange(of: height) { _, value in report(value) }
                    }
                }
            }
            """,
        "Modifier.swift": """
            private struct Measured: ViewModifier {
                @State private var frame = CGRect.zero
                func body(content: Content) -> some View {
                    content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                }
            }
            extension View {
                func measured() -> some View { modifier(Measured()) }
                func plain() -> some View { self }
            }
            """,
        "Grids.swift": """
            struct Grids: View {
                var body: some View {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 6) {
                        Card()
                    }
                    LazyVStack {
                        Text("x").measured()
                    }
                    LazyHStack {
                        Text("y").plain()
                        Bar()
                    }
                    VStack { Card() }
                }
            }
            """,
    }
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "Sources/UsageDock").mkdir(parents=True)
        for name, body in files.items():
            (root / "Sources/UsageDock" / name).write_text(body, encoding="utf-8")
        _, sites, lazy, _ = scan(root)
    got = Counter((pathlib.Path(p).name, k) for p, k, _ in sites)
    want = Counter({
        ("Card.swift", "GeometryReader probe via heightReader()"): 2,
        ("Modifier.swift", "onGeometryChange"): 1,
        ("Bar.swift", "GeometryReader probe"): 1,
    })
    problems = []
    if got != want:
        problems.append(f"sites {dict(got)} != {dict(want)}")
    flagged = sorted(f"{container}:{label}" for container, label, _ in lazy)
    if flagged != ["LazyVGrid:Card", "LazyVStack:.measured()"]:
        problems.append(f"lazy violations {flagged}")
    return problems


problems = self_test()
if problems:
    for problem in problems:
        print(f"layout measurement contract failed: scanner self-test: {problem}", file=sys.stderr)
    sys.exit(1)

root = pathlib.Path(".")
sources, sites, lazy_violations, lazy_count = scan(root)
failures = [message for _, _, message in lazy_violations]

found = Counter((path, kind) for path, kind, _ in sites)
registered = {(path, kind): count for path, kind, count, _ in REGISTRY}
for key in sorted(set(found) | set(registered)):
    path, kind = key
    have, want = found.get(key, 0), registered.get(key, 0)
    if have == want:
        continue
    lines = ", ".join(str(sources[p].line(pos)) for p, k, pos in sites if (p, k) == key)
    if want == 0:
        failures.append(f"{path} 有 {have} 处未登记的 {kind}（第 {lines} 行）")
    else:
        failures.append(f"{path} 的 {kind} 登记为 {want} 处，实际 {have} 处" + (f"（第 {lines} 行）" if lines else ""))

for path, pattern, message in PINS:
    src = sources.get(path)
    if src is None:
        failures.append(f"{path} 已不存在，请更新本脚本")
    elif not re.search(pattern, collapsed(src.code)):
        failures.append(f"{path}: {message}")

if failures:
    for message in failures:
        print(f"layout measurement contract failed: {message}", file=sys.stderr)
    print(
        "规则：测量值写进状态后，不得改变被测视图、给它报尺寸的祖先或兄弟视图的尺寸；"
        "行高、列宽这类结论改用 Layout 协议在一次布局里算出。确认收敛后再更新 "
        "script/verify_layout_measurement_contract.sh 的 REGISTRY 并写明理由，见 DB-002。",
        file=sys.stderr,
    )
    sys.exit(1)
print(
    f"layout measurement contract verified: {sum(found.values())} measurement sites registered "
    f"in {len({p for p, _ in found})} files, {lazy_count} lazy containers hold no measured views, "
    f"{len(PINS)} pinned shapes intact"
)
PY
