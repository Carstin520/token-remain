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
| Codex CLI 0.144.1 | 读取 AGENTS.md；扫描从 cwd 到仓库根的 `.agents/skills`，跟随符号链接；不扫描 `.cursor/skills`、`.claude/skills` | 实测：`codex debug prompt-input` 输出含对应 nonce，移除 `.agents/skills` 链接后消失；文档 learn.chatgpt.com/docs/build-skills | 2026-09-28 |
| Codex CLI 0.144.1 | 也扫描仓库 `.codex/skills`，但官方文档未列出该路径 | 实测，同上 | 2026-09-28 |
| Codex CLI 0.144.1 | 项目 hook 在 `.codex/hooks.json`，`PreToolUse` 用 matcher `Bash`，命令在 `tool_input.command`，exit 2 或 `permissionDecision: deny` 阻止；项目 hook 须经 `/hooks` 信任后才运行，`codex exec --dangerously-bypass-hook-trust` 可单次跳过信任 | 文档 learn.chatgpt.com/docs/hooks；本仓库挂接结果见 P3 记录 | 2026-09-28 |
| Codex app 定时任务 | 用用户的默认 sandbox 设置运行，组织策略允许时 `approval_policy = "never"`；可选本地项目或新 worktree；文档未说明能否为单个任务设环境变量；定义保存在 `~/.codex/automations/<id>/automation.toml`（`kind`、`rrule`、`execution_environment`、`cwds`、`target`、`model` 等字段） | 文档 learn.chatgpt.com/docs/automations；本机只读查看字段名 | 2026-09-28 |
| Cursor 3.22.7 | 项目 hook 在 `.cursor/hooks.json`（`version: 1`），`beforeShellExecution` 输入含 `command`、`cwd`；exit 2 等同 deny，stdout 字段为 `permission`、`user_message`、`agent_message`；仅在受信任工作区运行，云代理也运行项目命令 hook；文档未说明 hook 是否继承父进程环境变量 | 文档 cursor.com/docs/agent/hooks；本机未实跑 Cursor | 2026-09-28 |
| GitHub Actions | `macos-26` 为 arm64 GA 镜像，macOS 26.6.2（25G83），默认 Xcode 26.6（17F113），与本机开发环境一致 | 文档 github.com/actions/runner-images `macos-26-arm64-Readme.md`（镜像 20260907.0351.1） | 2026-09-28 |

因为 Codex 定时任务与 Cursor hook 的环境变量继承都没有文档保证，lane 身份除环境变量外还认 worktree 私有 git 目录里的标记文件（R14）。
