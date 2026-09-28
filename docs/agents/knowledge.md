# TokenRemain 代理知识库

本文件保存多个宿主都需要、但还不能写成可执行契约的项目事实。规则在 [AGENTS.md](../../AGENTS.md)，本文件不新增授权。按 R15，能变成测试或脚本的条目优先转为契约，见文末“待转为契约”。

每条写明事实、来源（代码路径、PR/issue 或实测记录）和核实日期。条目与当前代码不符时，以代码为准并在规则维护任务中修正本文件；不要把个人记忆当作来源。

<a id="host-capabilities"></a>

## 宿主能力

本节记录本仓库依赖的宿主行为。“实测”指在本机用临时探针仓库验证；“文档”指只核对了官方文档；二者都没有的写“未验证”。

| 宿主与版本 | 事实 | 来源 | 核实日期 |
| --- | --- | --- | --- |
| Claude Code 2.1.267 | 项目根 `CLAUDE.md` 首行 `@AGENTS.md` 会把 AGENTS.md 导入上下文；相对路径按导入文件解析，最多 4 层 | 实测：探针仓库中 AGENTS.md 的 nonce 出现在 `claude -p` 回答里；文档 code.claude.com/docs/en/memory | 2026-09-28 |
| Claude Code 2.1.267 | 扫描 `.claude/skills/<name>/SKILL.md`，跟随指向 `.cursor/skills/<name>` 的目录符号链接；不扫描 `.agents/skills`、`.codex/skills` | 实测：探针仓库中符号链接技能与真实目录技能都被列出，另两处未列出 | 2026-09-28 |
| Claude Code 2.1.267 | `.claude/settings.json` 的 PreToolUse(Bash) hook 以 exit 2 拒绝时，`bypassPermissions` 模式和已放行的工具规则都不能越过；hook 进程继承启动 `claude` 时的环境变量；无 lane 标记时命令正常执行 | 实测：`claude -p` 在临时克隆中运行 `git tag`，以 `git tag -l` 结果为准 | 2026-09-28 |
| Codex CLI 0.144.1 | 读取 AGENTS.md；扫描从 cwd 到仓库根的 `.agents/skills`，跟随符号链接；不扫描 `.cursor/skills`、`.claude/skills` | 实测：`codex debug prompt-input` 输出含对应 nonce，移除 `.agents/skills` 链接后消失；文档 learn.chatgpt.com/docs/build-skills | 2026-09-28 |
| Codex CLI 0.144.1 | 也扫描仓库 `.codex/skills`，但官方文档未列出该路径 | 实测，同上 | 2026-09-28 |
| Codex CLI 0.144.1 | 项目 hook 在 `.codex/hooks.json`，`PreToolUse` 用 matcher `Bash`，命令在 `tool_input.command`，exit 2 或 `permissionDecision: deny` 阻止；项目 hook 须经 `/hooks` 信任后才运行，`codex exec --dangerously-bypass-hook-trust` 可单次跳过信任 | 文档 learn.chatgpt.com/docs/hooks | 2026-09-28 |
| Codex CLI 0.144.1 | 本仓库护栏：带 lane 标记的克隆中 `git tag` 被 hook 拦下且标签未创建；无标记时 hook 运行但放行；未信任 hook 时 hook 完全不运行，所以 lane 预检用 canary 命令确认护栏生效 | 实测：`codex exec`（`gpt-5.6-sol`）在临时克隆中，以 `git tag -l` 结果为准 | 2026-09-28 |
| Codex CLI 0.144.1 | `workspace-write` sandbox 禁止写 `.git`（`git tag` 报 Operation not permitted），默认也不开网络；在此设置下 lane 无法 commit、push 或调用 `gh` | 实测，同上；本机默认 `sandbox_mode = "workspace-write"` 且未设 `network_access` | 2026-09-28 |
| Codex app 定时任务 | 用用户的默认 sandbox 设置运行，组织策略允许时 `approval_policy = "never"`；可选本地项目或新 worktree；文档未说明能否为单个任务设环境变量；定义保存在 `~/.codex/automations/<id>/automation.toml`（`kind`、`rrule`、`execution_environment`、`cwds`、`target`、`model` 等字段） | 文档 learn.chatgpt.com/docs/automations；本机只读查看字段名 | 2026-09-28 |
| Cursor 3.22.7 | 项目 hook 在 `.cursor/hooks.json`（`version: 1`），`beforeShellExecution` 输入含 `command`、`cwd`；exit 2 等同 deny，stdout 字段为 `permission`、`user_message`、`agent_message`；仅在受信任工作区运行，云代理也运行项目命令 hook；文档未说明 hook 是否继承父进程环境变量 | 文档 cursor.com/docs/agent/hooks；本机未实跑 Cursor | 2026-09-28 |
| GitHub Actions | `macos-26` 为 arm64 GA 镜像，macOS 26.6.2（25G83），默认 Xcode 26.6（17F113），与本机开发环境一致 | 文档 github.com/actions/runner-images `macos-26-arm64-Readme.md`（镜像 20260907.0351.1） | 2026-09-28 |

因为 Codex 定时任务与 Cursor hook 的环境变量继承都没有文档保证，lane 身份除环境变量外还认 worktree 私有 git 目录里的标记文件（R14）。

<a id="upstream-baselines"></a>

## 上游基线

Lane B 比较这些基线与上游当前状态。基线变更需要人审阅后在独立 PR 中更新。

| 上游 | 基线 | 来源 | 核实日期 |
| --- | --- | --- | --- |
| pstack（`cursor/plugins` 的 `pstack/`） | 见 [pstack-upstream.json](pstack-upstream.json)；处置表在 `.cursor/rules/tokenremain-pstack.mdc` | 本仓库审阅记录 | 2026-09-28 |
| token-monitor（`Javis603/token-monitor`，MIT） | 移植时的上游提交未记录，状态为“未知”。已知移植落地于本仓库 `697e550`（2026-07-23，首次移植）与 `b4fc28d`（2026-08-04，扩展兼容）；Lane B 首次运行列出 2026-07-23 以来 `src/shared/*Limits.js` 的提交，由人确认基线后写回本表 | `Sources/UsageDock/Services/ExtendedProviderServices.swift` 文件头注释；`git log --follow` | 2026-09-28 |
| ccusage（npm `@ccusage/ccusage-darwin-*`） | `Resources/Info.plist` 的 `TokenRemainBundledCCUsageVersion`；`script/verify_ccusage_freshness.sh --check` 只读比较 npm 最新版（写 `/tmp` 临时目录，陈旧时退出 1），`--update` 会改 `Vendor/`，属于发布任务 | 脚本源码 | 2026-09-28 |
