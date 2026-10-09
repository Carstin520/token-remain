@AGENTS.md

# Claude Code 入口

上面导入的 AGENTS.md 是本仓库唯一的规则正文。本文件只补充 Claude Code 的发现入口，不复制规则。

- **技能。** `.claude/skills/<name>` 是指向 `.cursor/skills/<name>` 的符号链接，内容以 `.cursor/skills/` 为准。维护任务用 `/tokenremain-mode`，验证用 `/verify-tokenremain`，无人值守 lane 用 `/maintain-tokenremain`。
- **pstack。** [pstack 适配规则](.cursor/rules/tokenremain-pstack.mdc) 同样约束 Claude Code 会话。Claude Code 没有 pstack 插件，技能里点名的 pstack 技能（`how`、`architect`、`unslop` 等）不可用时，用现有工具完成同一步骤并披露降级，不伪造调用。
- **lane 护栏。** `.claude/settings.json` 的 PreToolUse(Bash) hook 调用 `script/agent_lane_guard.sh`。它只在 R14 定义的无人值守 lane 中拦截命令，交互会话中直接放行；hook 通过不等于获得授权。
- **记忆。** `~/.claude/projects/*/memory/` 是个人记忆，不是项目事实源（R15）。共享事实查 [knowledge](docs/agents/knowledge.md)；发现只存在于个人记忆、其他宿主也需要的项目事实时，在规则维护任务中迁入仓库。
