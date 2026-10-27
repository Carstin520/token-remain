# TokenRemain App 图标规格：O4-C 点阵环机器人头

- **状态**：方向已定稿（2026-10-27，用户从多轮概念中选定 O4-C）。
- **分工**：Claude 定方向和规格；Codex 负责出最终图和接入两个仓库。
- **范围**：macOS 仓库（本仓库）和 iOS 仓库 `token-remain-ios`。Windows 和官网图标的源文件都在本仓库。
- **几何参考**：[`reference/`](reference/) 下的三张 1024 SVG 是本规格的几何真值。它们**不是生产资产**，没有 Liquid Glass、外观变体和尺寸适配，不能直接拿去替换图标。

## 0. 执行约束

1. 先读本仓库 [`AGENTS.md`](../../../AGENTS.md)。iOS 仓库没有 AGENTS.md，在那里同样遵守 R1（保留用户改动）、R2（未获授权不 commit、push、开 PR、部署）和 R8（保护真实安装）。
2. 分两阶段做，**阶段 A 必须先停下等用户确认**：
   - **阶段 A：出图和评审。** 产出主稿和评审图（见 §9），不替换任何正在使用的资产。
   - **阶段 B：接入。** 用户批准阶段 A 后，再按 §7 替换资产、修改渲染代码和测试。
3. 本次只做 §7 列出的内容。§12 的 App 内机器人替换要用户另行确认。
4. 不运行 `script/verify_release_configuration.sh`（会调用 ccusage `--update`）。运行 `script/build_and_run.sh` 前，先按 [verify-tokenremain](../../../.cursor/skills/verify-tokenremain/SKILL.md) 做实例归属检查。官网不部署。

## 1. 设计意图

| 元素 | 含义 | 规则 |
| --- | --- | --- |
| 机器人头 | 品牌角色 | 正面、平静、**表情固定**。不再有 11 档表情，也不随额度变化 |
| 外圈 20 颗点 | 剩余额度 | 每颗代表 5%。从 12 点方向开始顺时针点亮 |
| 亮点颜色 | 统一青色 | 不再区分 provider 颜色（现在支持 27 个以上的服务）。额度低时**不变红**，紧迫感只来自点亮的数量 |

机器人是主角，点阵环是辅助信息。点阵环在小尺寸下会看不清，所以这个风险要靠 §5 的尺寸变体来解决，不能靠加粗主稿。

## 2. 画布与坐标

- **Tile 坐标**：1024×1024，原点在左上角，图标的可见形状铺满整个画布。Icon Composer 的图层和 iOS 全出血图标都用这套坐标。
- **macOS 旧版 icns 和运行时 Dock 图块**：形状是 824×824，四边各内缩 100，圆角半径 185.4，沿用 `TokenRemainHeadLogoArtwork.dockTileInset` 和 `dockTileCornerRadius`。把 tile 坐标下的整张图按 824/1024 缩进这个形状里。
- **watchOS**：系统用圆形裁切同一张 1024 tile。完整版最外侧点的外沿在半径 430 处，小于 512，不会被裁掉。

## 3. 颜色（sRGB）

| 角色 | Hex | 来源 |
| --- | --- | --- |
| 背景 | `#081431` | 等于现有 `AppIcon.icon` 的 fill 和 `TokenRemainHeadLogoArtwork.dockTileFill`。**两者必须保持一致**，`testIconComposerFillMatchesTheRuntimeDockTile` 会检查 |
| 外壳 | `#8F7BF2` | 调色板 `violet` |
| 底部厚度带 | `#5B4FB0` | 调色板 `violetDim` |
| 天线 | `#B7A9F7` | 沿用 `site/assets/favicon.svg` |
| 屏幕 | `#070B12` | 调色板 `ink` |
| 眼睛 | `#3ECFE0` | 调色板 `cyan` |
| 亮点 | `#3ECFE0` | 调色板 `cyan` |
| 暗点 | `#2B3754` | 新值，图标专用的环轨道色。调色板的 `track` 色 `#1B2536` 在这个背景上看不清 |

## 4. 几何：完整版（tile 坐标）

参考文件：[`reference/full-1024.svg`](reference/full-1024.svg)

| 图层（从下到上） | 形状 | 参数 |
| --- | --- | --- |
| background | 矩形 | 0,0,1024,1024 |
| ring | 20 个圆 | 圆心 (512 + 400·cos θᵢ, 512 + 400·sin θᵢ)，θᵢ = −90° + 18°·i，i = 0…19；半径 30 |
| antenna | 圆角矩形 | x 459，y 262，w 106，h 64，r 24（下沿压在外壳下面） |
| depth | 圆角矩形 | x 286，y 352，w 452，h 400，r 120 |
| shell | 圆角矩形 | x 286，y 312，w 452，h 400，r 120 |
| screen | 圆角矩形 | x 352，y 386，w 320，h 240，r 66 |
| eyes | 2 个圆 | (439, 506) 和 (585, 506)，r 34 |

关键关系（调整细节时不能破坏）：

- 头宽 452，占 tile 的 44%。头加天线的垂直范围是 262–752，视觉中心在 507。
- 头的最外点距中心约 280，点环内沿在半径 370 处，中间留出约 90 的空隙。
- 两颗点的间隙约 65，比点的直径（60）略大，所以缩小后点不会糊成一条线。

## 5. 尺寸变体

一张主稿缩小到 16–32px 时，点阵会糊成一圈（已在 16、32、48px 下实测）。所以按实际渲染尺寸用三个变体：

| 变体 | 渲染尺寸 | 点环 | 头部 | 参考 |
| --- | --- | --- | --- | --- |
| full | ≥ 64 px | 20 点，R 400，r 30 | 按 §4 | [`full-1024.svg`](reference/full-1024.svg) |
| medium | 32–63 px | 10 点，R 392，r 46，θᵢ = −90° + 36°·i；每点代表 10% | 同 §4，眼睛半径改为 40 | [`medium-1024.svg`](reference/medium-1024.svg) |
| small | < 32 px | 无 | 放大的头：天线 (439, 201, 146×88, r 33)；外壳 (200, 270, 624×552, r 166)；屏幕 (291, 372, 442×331, r 91)；眼睛 (411, 538) 和 (613, 538)，r 56；**去掉厚度带** | [`small-1024.svg`](reference/small-1024.svg) |

各平台的具体文件对应哪个变体：

| 平台和文件 | 变体 |
| --- | --- |
| macOS icns：16 | small |
| macOS icns：16@2x、32 | medium |
| macOS icns：32@2x 及以上 | full |
| Windows ico：16、24 | small |
| Windows ico：32、48 | medium |
| Windows ico：64、128、256 | full |
| Windows 托盘兜底图标（20 px） | small |
| 官网 favicon | small |
| iOS 和 watchOS 的单张 1024 图标 | full。系统自己缩放，最小渲染约 40 px，full 在这个尺寸实测可读。iOS 无法按尺寸提供不同变体，这是已知限制 |

## 6. 状态规则

**静态主稿**（打包进 App 的图标、官网、Windows）：full 点亮 15/20（75%），medium 点亮 8/10，small 没有点环。15/20 时暗点落在 9 点到 12 点之间。

**运行时**（macOS Dock 图标，以及 §12 确认后的其他位置）：

- **数值 `p`**：用户在设置里为 Dock 选定的那几个 provider 中，剩余百分比最低的一个。这就是现在 `TokenRemainHeadLogoArtwork.moodRemaining(slots)` 的语义，**保持不变**。
- **点亮数**：
  - `p` 不存在 → 0 颗点亮，全部是暗点，表示"无数据"。
  - `p ≤ 0` → 0 颗。
  - 其他 → `clamp(round(p / 5), 1, 20)`。`p` 的取值是 0–100，`round` 采用四舍五入。
  - medium 变体用 `clamp(round(p / 10), 1, 10)`。
- **点亮顺序**：第 0 颗在 12 点方向，顺时针。点亮的是序号 `[0, 点亮数)` 的点。
- **不做的事**：不改颜色，不做动画，眼睛不变。

## 7. 交付清单（阶段 B）

### 7.1 macOS（本仓库）

| 文件 | 要求 |
| --- | --- |
| `Resources/AppIcon.icon/icon.json` 和 `Assets/` | 按 §8 重做分组（Ring、Head、Face）。fill 保持 `#081431`，`supported-platforms` 仍然只有 macOS。每个图层引用的文件都必须放在 `Assets/` 里（有测试检查） |
| `Sources/UsageDock/Resources/TokenRemain.icns` | 按 §5 的尺寸对应关系分尺寸生成 |
| `script/build_token_remain_icons.sh` | 改用新主稿，并支持按尺寸选择变体。这个脚本现在还会运行 `refine_token_remain_icons.swift` 重新生成表情 PNG（`TokenRemainStates`）。本次不能改动那些表情资源，所以要拆开脚本或加开关，确保接入后表情资源零 diff。`extract_app_icon_foreground.swift` 如果不再需要，先确认没有其他调用者再删除 |
| `Sources/UsageDock/Views/TokenRemainHeadLogo.swift` | `TokenRemainHeadLogoArtwork` 的 `.dockTile` 和 `.bare` 两种样式都改成按点亮数用代码绘制矢量图形，几何取自 §4。不再从 `TokenRemainHeadStates` 的 PNG 合成，也去掉 provider 颜色的进度条。`renderKey` 改为由点亮数和"无数据"状态决定，保留"内容相同就跳过 Dock 重绘"的用途。`dockTileFill`、`dockTileInset`、`dockTileCornerRadius` 不变。无障碍标签去掉表情描述，保留各 provider 的百分比。如果 `TokenRemainHeadStates` 之后没有任何引用，可以删除，删除前先 grep 确认 |
| `Sources/UsageDock/Support/StatusBarController.swift` | Dock 图标去重的依据改用新的 `renderKey`。第 456 行附近的 `TokenRemainLogoState.resolve` 先确认还有没有用处再改 |
| `Sources/UsageDock/Views/Dashboard/SettingsSection.swift` | 设置页的 Dock 预览自动跟随新图形，不需要单独设计 |
| `Sources/UsageDock/Localization/*.lproj/Localizable.strings`（16 种语言） | 只改 `settings.dock_logo_title`、`_hint`、`_top`、`_bottom` 这四个文案的取值，不改键名。设置里两个选择器和偏好存储（`PreferencesStore.dockLogoProviders`）都不变。参考文案：英文 "Dock icon meter" / "The dots around the Dock icon follow the lower of these two apps" / "App 1" / "App 2"；简体中文 "Dock 图标余量环" / "Dock 图标外圈的点跟随这两个应用中较低的一个" / "应用 1" / "应用 2"。其余语言按同样意思翻译。改完后在 `windows/` 下运行 `npm run locales:generate` 重新生成 `windows/src/locales.generated.js`，不要手改 |
| `Tests/UsageDockTests/TokenRemainLogoTests.swift` | Dock 相关测试按新规则重写，覆盖面不能比现在少。至少覆盖：点亮数映射（无数据、0、2、2.5、50、97、100）、取最低值、点亮数相同时 `renderKey` 相同、点亮数不同时 `renderKey` 不同。`testIconComposerFillMatchesTheRuntimeDockTile`、`testInfoPlistNamesTheIconComposerIconAndKeepsTheIcnsFallback`、`testDockTileDrawsTheIconShapeWhileTheBareLogoStaysTransparent` 保留。表情相关测试不动，全身机器人还在用 |

不在本次范围：`TokenRemainFullBodyRobot`（仪表盘和新手引导在用）、`PixelRobotMark`、`TokenRemainLogoState`、`TokenRemainStates` 和 `TokenRemainFullBodyStates` 资源。

### 7.2 iOS（`token-remain-ios`）

| 文件 | 要求 |
| --- | --- |
| `App/Assets.xcassets/AppIcon.appiconset` | 1024 的 Any、Dark、Tinted 三种外观，在 Contents.json 里声明 appearances，配色按 §8。也可以改用 `.icon` 文件，但前提是验证 Xcode 26.6 在 iOS 18.0 部署目标下能正确生成旧系统用的图标；验证不了就用 appiconset |
| `App/Assets.xcassets/TRIcon50/60/80/90/100.appiconset` | 重新生成为 full 变体，分别点亮 10、12、16、18、20 颗。改 `script/generate_dynamic_app_icons.swift`，不再从 `HeadLogoStates` 取图。**这几套备选图标目前没有任何代码调用**，本次不接入切换逻辑（`setAlternateIconName` 每次切换都会弹系统提示，是否接入需要另做产品决定） |
| `WatchApp/Assets.xcassets/AppIcon.appiconset` | 1024 full 变体，由系统裁成圆形 |
| `project.yml` | 只有改用 `.icon` 时才需要改。改完运行 `xcodegen generate`，生成的工程不入库 |

不在本次范围：`TokenRemainKit` 里的 `TokenRemainHeadLogo`（小组件和实时活动在用）、`HeadLogoStates` 和 `FullBodyLogoStates` 资源。

### 7.3 Windows（源文件在本仓库）

- `site/assets/brand/appicon-mac.png` 是 `windows/scripts/generate-ico.mjs` 的输入。它也会被打包成 `appicon.png`，用作窗口图标和托盘兜底图标（`windows/electron/main.js` 的 `iconPath()`）。
- 新增 `site/assets/brand/appicon-small.png`（256，small 变体）和 `appicon-medium.png`（256，medium 变体）。
- 改 `generate-ico.mjs`，按 §5 为每个尺寸选择对应的源图，然后运行 `npm run icon:generate`。
- 托盘兜底图标改用 small 变体，`windows/package.json` 的 `extraResources` 要同时打包这个文件。

### 7.4 官网（只改文件，不部署）

- `site/assets/favicon.svg`：small 变体的矢量版，可以用 64 的 viewBox，背景是圆角图块。
- `site/assets/brand/appicon-mac.png`：512×512 的 full 变体（15/20），构图和现在一样，背景色铺满整个正方形，这样不用改官网 CSS。
- `site/index.html` 第 2044 行附近的图标 alt 文案：去掉"pixel robot head over Claude and Codex quota bars"的描述。如果其他语言也有这段文案，一起改。

不在本次范围：官网介绍 11 种表情的品牌展示区、`assets/brand/head`、`assets/brand/body` 和 `mascot.gif`，见 §12。

## 8. 图层与外观

**Icon Composer 分组**（macOS `.icon`；iOS 如果改用 `.icon` 也照此分组）：

| 分组（从下到上） | 图层 | 建议设置 |
| --- | --- | --- |
| Ring | dots-dim、dots-lit | 关闭 glass，保证点的颜色准确 |
| Head | antenna、depth、shell | 开启 glass 的高光，translucency 关闭，阴影用 neutral、强度 0.5（和现在一样） |
| Face | screen、eyes | 关闭 glass，保证眼睛清晰 |

运行时的 Dock 图标（`applicationIconImage`）在 macOS 26 上会原样显示，没有 glass 效果。所以识别度不能依赖 glass：在点亮数相同时，打包图标和运行时图标除了 glass 质感，大小、位置、颜色都必须一致。

**外观变体：**

| 外观 | 配色 |
| --- | --- |
| Default | 按 §3 |
| Dark | 同 Default（本身就是深色） |
| Tinted / Mono | 按亮度映射：亮点和眼睛 100% 白，天线 85%，外壳 70%，厚度带 45%，暗点 20%，屏幕和背景是黑色或透明 |
| Clear（macOS/iOS 26） | 用系统默认处理，检查点和眼睛仍然可辨 |

## 9. 阶段 A 评审产出（替换资产之前给用户看）

放在 `design/source/token-remain-dot-ring-head/review/`：

1. 三个变体的生产主稿，SVG 或 1024 PNG，加 Icon Composer 工程。
2. 一张 `contact-sheet.png`，包含：
   - full、medium、small 在 1024、256、128、64、48、32、24、16 px 下的效果；
   - macOS 形状、iOS 形状、watchOS 圆形三种裁切；
   - Default、Dark、Tinted 三种外观；
   - 运行时点亮 20、15、10、5、1、0 颗以及"无数据"七种状态。

交付这两项后**停下，等用户确认**，再进入阶段 B。

## 10. 验收标准

- 1024 下几何和 `reference/` 偏差不超过 ±2 px，颜色和 §3 的 sRGB 值完全一致。
- 16 px（small）能分辨出两只眼睛；32 px（medium）的点不粘连。
- App 启动后 Dock 图标和打包图标在同样的点亮数下看不出跳变（glass 质感的差异除外）。
- iOS 主屏幕的 Default、Dark、Tinted 都正确；watchOS 圆形裁切不碰到点。
- 新图标里没有任何 provider 颜色，也没有平静表情以外的表情。
- 测试全部通过，没有放宽断言或删除覆盖。表情和全身机器人资源、用户偏好格式零 diff。

## 11. 验证命令

macOS（本仓库）：

```bash
swift test --filter TokenRemainLogoTests
swift test
script/compile_app_icon.sh "$(mktemp -d)" --required
```

真实运行时的 Dock 图标，按 verify-tokenremain 用普通 Dev 身份检查，不要覆盖生产版的 `TokenRemain.app`。

iOS（`token-remain-ios`）：

```bash
xcodegen generate
xcodebuild -project TokenRemain.xcodeproj -scheme TokenRemain -destination 'platform=iOS Simulator,name=iPhone 17' build
```

在模拟器主屏幕上分别检查 Default、Dark、Tinted，再在 watchOS 模拟器上检查图标。

Windows：

```bash
cd windows && npm run icon:generate && npm test
```

官网：

```bash
cd site && npm run build
```

只构建，不运行 `deploy`。

## 12. 阶段 2 候选（需用户另行确认，本次不做）

放弃表情后，下面这些位置还在显示带表情的机器人或 provider 颜色的进度条。是否、以及怎样统一成新标志，由用户决定：

- **iOS**：`TokenRemainKit/Components/TokenRemainHeadLogo.swift`，用在 `Widgets/TRWidgetViews.swift`（6 处）和 `Widgets/TokenRemainLiveActivity.swift`。
- **macOS**：`TokenRemainFullBodyRobot`（`DashboardView`、`OnboardingView`）和 `PixelRobotMark`。
- **官网**：品牌展示区的 11 档表情、头像和全身像 PNG、`mascot.gif`，以及首页小组件截图里的机器人。
