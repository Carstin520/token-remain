# Token Remain 调色板 v1.1(2026-07-20)

桌面端(`Sources/UsageDock/Views/Theme/DashboardTheme.swift`)与移动端(`apple/FABLE-FUNCTIONAL-SPEC.md` §3 `TRTheme`)共用的颜色令牌。可视化色块板:见 Claude Artifact「Token Remain 色板」。

核心原则:**身份与语义分离** —— 紫罗兰/青只表达品牌身份与强调(Claude、Codex、选中、链接);红黄绿只表达状态好坏,且永远与图形符号(✓ / ! / ‼)+ 文字标签同时出现。

## 表面 Surfaces

| Token | Hex | 用途 |
|---|---|---|
| `ink` / `canvas` | `#070B12` | 窗口 / popover 底 |
| `surface` | `#0D1420` | 一级卡片 |
| `surface2` | `#141D2C` | 内嵌块 / chip |
| `surface3` | `#1B2536` | 浮起元素 |
| `border` | `#223044` | 1px 卡片描边、像素角刻 |
| `track` | `#1B2536` | 进度条空段 |

## 文字 Text

| Token | Hex | 用途 | 对比度 vs surface |
|---|---|---|---|
| `text` | `#E9EDF5` | 主文字、数值、英雄数字 | 15.7:1 (AAA) |
| `textDim` | `#8B97AB` | 次级文字、说明 | 6.3:1 (AA) |
| `textMute` | `#55617A` | 注脚、装饰;**不承载数值** | 2.97:1(仅装饰) |

## 品牌双色 Brand

| Token | Hex | 用途 | 对比度 vs surface |
|---|---|---|---|
| `violet` | `#8F7BF2` | Claude · 主强调 · 侧栏选中 | 5.5:1 |
| `violetDim` | `#5B4FB0` | 紫罗兰描边 / 静息段 | — |
| `cyan` | `#3ECFE0` | Codex · 倒计时 · 链接 · 确认 | 9.9:1 |
| `cyanDim` | `#2B8FA0` | 青描边 / 静息段 | — |

## 提供商扩展槽位 Provider Slots

未来接入新用量来源(OpenCode、Kimi、Gemini 等)时按顺序取下一个空槽;颜色永远跟随实体,不随排名或筛选变化;绝不占用语义红黄绿。全组已通过 CVD 色觉安全验证(任意两两组合,暗色卡面;青为品牌固定色的亮度带例外,图表中始终有图标+标签+间隙作二次编码)。

| 槽位 | Hex | Dim | 建议归属 |
|---|---|---|---|
| slot 1 · 紫罗兰 | `#8F7BF2` | `#5B4FB0` | Claude(已用) |
| slot 2 · 青 | `#3ECFE0` | `#2B8FA0` | Codex(已用) |
| slot 3 · 靛蓝 | `#2F5FD0` | `#24479C` | Google Gemini |
| slot 4 · 品红 | `#D95FB8` | `#A2478A` | Kimi |
| slot 5 · 橄榄绿 | `#7DA342` | `#5D7A31` | OpenCode |

代码令牌:`DashboardTheme.providerSlots`。

## 语义状态 Semantic

| Token | Hex | 用途 | 配套符号 | 对比度 vs surface |
|---|---|---|---|---|
| `success` | `#57D19A` | 正常 / 按预算 / 可持续到重置 | ✓ | 9.7:1 |
| `warning` | `#FFB554` | 预警 / 中风险 / 节奏偏快 | ! | 10.5:1 |
| `danger` | `#FF6B6B` | 危险 / 高风险 / 预计提前用尽 | ‼ | 6.7:1 |

风险等级映射(`RiskLevel.tint`):low → success,medium → warning,high → danger,unknown → textDim。

## 字体 Typography

代码入口:`Sources/UsageDock/Views/Theme/Typography.swift`(`DashboardTheme.Typo` + `.numericFont` / `.wordmarkFont`)。原则:**像素感来自结构,不来自字形**——不引入第三方像素字体。

| 角色 | 字体 | 规则 |
|---|---|---|
| 正文 / 中文标签 | 系统 SF / PingFang SC | 保持系统默认 |
| 所有数字(百分比、token、成本、倒计时、时间) | SF Mono + `monospacedDigit` | 一律等宽;混排行只对数字 Text 生效(SF Mono 无中文字形) |
| 英雄数值(46% 式大数字) | SF Mono semibold/bold | 等宽半粗 |
| 徽章 / meta 标签 | SF Mono 大写 + 字距 | `PixelBadge` 统一实现 |
| 品牌字标 "Token Remain" | SF Mono | popover 头部、侧栏、菜单栏共用 |

## 配色规则

0. **提供商 logo 用官方品牌形象,与应用强调色分离**(2026-07-20 用户定稿):Claude = 官方星芒位图着珊瑚橙 `#D97757`(template);Codex = 六瓣花瓣矢量底(垂直渐变 `#C49AF8 → #6A78FF → #245BFF`)+ 白色 `>_` 提示符(描边比 0.115、圆角端点),几何源 `Sources/UsageDock/Views/BrandIcon.swift` 的 `CodexBrandGlyph`。进度条、选中态、图表系列色继续使用槽位色(紫/青/…);logo 色与渐变不得用于进度条或图表系列。
1. **数值文字只用 `text` / `textDim`**;`textMute` 对比度不达标,只做注脚与装饰。
2. **状态三重表达**:语义色 + 图形符号 + 文字标签,绝不只靠颜色。
3. **填充徽章的文字色**:cyan / warning / danger 底配墨色字 `#070B12`(≥ 10:1);violet 底可用白字但仅限大号加粗(3.3:1);**白字压 danger 红禁止**(2.78:1)。
4. **进度条 = 剩余量**:14 段方块条(窄场景 10 段),填充色 = 所属提供商品牌色,空段 = `track`;不使用渐变。
5. **卡片外观**:`surface` 填充 + 1px `border` + 8pt 圆角 + 像素角刻(装饰层对辅助功能隐藏)。
6. **数字排版**:一律等宽(`monospacedDigit`),英雄数值半粗。
