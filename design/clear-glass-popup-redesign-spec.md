# Clear Glass 弹窗重设计 — 设计规格

状态: 待实现 · 设计: Fable · 实现: Opus · 验收: Fable
日期: 2026-08-11

## 0. 一句话目标

菜单栏弹窗在 Clear Glass 模式下，**壳体（底衬)与卡片一样使用系统原生
Liquid Glass 透明玻璃**，顶部 beak 与壳体合并为一个圆润连续的剪影；
Frosted 与 Clear 的唯一差别是材质（毛玻璃 ↔ 透明玻璃），其余 UI/UX 不变。

## 1. 现状问题（为什么难看）

1. Clear 模式下壳体没有任何玻璃材质：`UsageDockCanvasBackground` 把
   `.ultraThinMaterial` opacity 置 0，只剩 `DashboardTheme.canvas.opacity(0.62)`
   的平涂墨水 —— 无折射、无高光，像一块深色亚克力板。
2. 壳体边缘靠 1pt 白色渐变 hairline 撑轮廓，配合平涂底就读作"线框"。
3. beak 是锐角三角形（`MenuBarPopupArrowShape`，三段直线，顶点 0 圆角），
   与壳体是两个独立描边图层，接缝处割裂,顶点刺眼。

## 2. 设计方案

### 2.1 统一剪影：`MenuBarPopupShellShape`

新建一个 `Shape`,把 beak 和壳体圆角矩形画进**同一条路径**：

- 主体：`RoundedRectangle` 等效路径，cornerRadius **14 保持不变**，
  `.continuous` 风格（保持现有 shell 14 → card 13 → control 9 的阶梯）。
- beak：仍是宽 24pt × 高 12pt、中心 x 由 `arrowCenterX` 决定（夹取逻辑不变，
  布局尺寸不变），但几何改为圆润版本：
  - **顶点圆角半径 ≈ 3.5pt**（用 arc 或二次贝塞尔削平顶点）；
  - **两腰与壳体顶边交接处各加 ≈ 6pt 的内切圆角**（tangent fillet），
    使 beak 像从顶边"隆起"而非"插上去"；
  - 参考 Apple 原生 NSPopover beak 的柔和轮廓。
- 路径必须单一、闭合，供 `glassEffect(in:)`、`clipShape`、`strokeBorder`
  三处共用。

删除 `MenuBarPopupArrow` / `MenuBarPopupArrowShape` / `MenuBarPopupArrowOutline`
三个独立图层视图（V 形描边一并移除）。

### 2.2 材质：底衬用原生 Liquid Glass

macOS 26 路径上，壳体背景改为对统一剪影应用一次原生玻璃：

- **Clear**: `Glass.clear`，tint 为 `DashboardTheme.canvas` 按现有
  `popoverBackgroundOpacity` 偏好映射（滑杆语义保留：越低越透）。
  平涂墨水层不再单独叠加——tint 就是墨水。
- **Frosted**: 同一剪影内呈现现有配方（`.ultraThinMaterial` ×
  `backdropMaterialOpacity` + canvas 墨水),视觉结果必须与今天的 Frosted
  一致（允许实现上改用 `Glass.regular.tint(...)`，前提是截图对比无退化）。
- 两种模式共享同一几何、同一 rim、同一动画时长
  (`materialTransitionDuration = 0.20`，Reduce Motion 跳过)，切换时只有
  材质交叉淡入淡出。

### 2.3 收边（rim）

- 保留"单条顶光 hairline"思路：`shellRimGradient` 沿**统一剪影**描边
  （beak 也被同一条 hairline 包住,不再有独立 V 线）。
- 各透明度常量（0.32/0.28 clear、0.24/0.20 frosted）不动，除非截图显示
  beak 圆角处高光断裂，可微调 ±0.04。

### 2.4 卡片与内容

- 卡片继续使用现有 `usageDockGlassSurface`（Clear → `Glass.clear.tint`）。
- **风险与守护**：代码注释警告过"玻璃叠玻璃会让卡片采样到深色父层而发黑"。
  实现后必须截图确认卡片没有变黑;若发黑，按序尝试：
  1. 降低壳体 tint 浓度（改 tint 映射系数,不改滑杆语义）；
  2. 提高 `minimumSurfaceLift`（0.055 → ≤0.09）；
  3. 最后手段：壳体玻璃仅对 beak+边缘带生效，中心区回退墨水。
- **可读性兜底**（用户明确允许）：Clear 模式下无法看清的局部控件
  （如 footer 命令 chips、菜单 label）可以局部保留 Frosted/regular 材质，
  但仅限确实不可读的元素，且需在验收截图中指认。

### 2.5 不许改的东西

- 弹窗尺寸、布局、间距、字体、颜色 token、卡片圆角阶梯、滑杆语义、
  Frosted 的整体观感、macOS 14/15 的 `NSPopover` 回退路径
  （旧系统仍走系统 bezel，新 Shape 只在 macOS 26 panel 生效，
  pre-26 分支保持 canvas 平涂回退）。
- 语义色规则（红黄绿警示）与品牌色使用不变。

## 3. 涉及文件

- `Sources/UsageDock/Support/MenuBarPopupWindowController.swift`
  （Chrome、新 Shape、删除三个 Arrow 视图、rim 描边改走统一剪影）
- `Sources/UsageDock/Views/Theme/LiquidGlassSupport.swift`
  （`UsageDockCanvasBackground` 增加/改造壳体玻璃路径；
  `UsageDockPopoverShellModifier` 改为按统一剪影描边）
- `Tests/UsageDockTests/ThemeContrastTests.swift`（如常量变动需同步）

## 4. 第二轮修正（2026-08-11 用户反馈）

用户验收后提出三项问题，全部为必须修复：

### 4.1 Frosted/Clear 视觉映射疑似反了

症状：选 **Frosted** 弹窗反而更透明，选 **Clear** 反而闷/像毛玻璃。
数据层绑定与 tag 已核实无误（frosted→frosted, clear→clear），问题在渲染层。

- 首要嫌疑：`UsageDockPopoverShellBackdropModifier` 用 `.opacity(0/1)`
  交叉淡化两个常驻背景，其中 clear 背景是 `glassEffect` —— glass 的
  backdrop 层可能**不受外层 opacity 影响**，导致 Frosted 模式下
  `Glass.clear` 仍在渲染（Frosted 显透），且组合观感错乱。
- 修复方向：不要依赖 `.opacity()` 隐藏 glassEffect。改为条件挂载
  （if/else + `.transition(.opacity)`），或单一 glass 表面在两种模式间
  切换 `Glass.regular`/`Glass.clear` 与 tint。切换动画仍须 ≈0.20s
  平滑（Reduce Motion 跳过）；若条件挂载导致动画弹跳，可接受把
  材质切换动画降级为直切,但两种模式的稳态观感必须正确：
  **Frosted = 明显毛玻璃漫射；Clear = 明显透明折射**。
- 必须实拍两种模式各一张截图，肉眼确认方向没反。

### 4.2 Clear 模式卡片必须有透明度

症状：Clear 模式下 Claude/Codex/AI Feed 等卡片看起来完全不透明。
根因：卡片 tint 浓度直接取 `surfaceTintOpacity = backdropOpacity`
（默认 0.62 的深色 surface tint），在 `Glass.clear` 上近乎实心。

- Clear 模式下卡片 tint 增加一个衰减系数（建议 0.35–0.5,常量化,
  进 `UsageDockPopoverAppearance` 并加测试），目标：卡片呈半透明
  液态玻璃,能隐约看到桌面内容透过，同时正文文字仍可读
  （文字已有 glyph shadow 保护）。
- Frosted 模式卡片浓度不变。滑杆语义不变（仍控制整体浓淡）。
- 若衰减后卡片与壳体层次不清，可微调 `surfaceLift`（≤0.09）。

### 4.3 卡片悬停/按下两种状态（Frosted 与 Clear 都要）

用户确认指的是：鼠标悬停/按下弹窗卡片（Claude、Codex、Local Usage、
AI Feed 等）时卡片应有"亮起/浮起"的交互反馈——未悬停=常态,
悬停/按下=高亮态。

- 首选实现：macOS 26 上给弹窗内卡片的 glass 加 `.interactive()`
  （`DashboardCard` 增加 `interactive` 参数并由弹窗调用点传 true，
  或经 environment 让弹窗内的 `usageDockGlassSurface` 默认 interactive）。
  Dashboard 窗口内的卡片**不要**跟着变。
- 若 `.interactive()` 在深色 tint 上反馈不可见，退而求其次：
  onHover 驱动的白色 lift 叠加（+0.04~0.06 opacity，0.16s ease，
  Reduce Motion 跳过），两种玻璃风格都要生效。
- pre-macOS 26 回退路径维持现状即可。

### 4.4 验收注意（给实现者）

- 测试机可能残留多个 `UsageDockDev` 实例，先 `pkill -x UsageDockDev`。
- `--open-popover` 若状态栏锚点不可用，弹窗会落到 (0,1440) 屏幕外的
  兜底位置；重启单实例后用 CGWindowList 找真实窗口坐标再截图
  （此前正常时约在 X≈1712, Y=30，380×770pt，主屏 2560×1440pt @2x）。
- 用户正在使用这台机器：截图动作尽量少、快，不要反复抢焦点。

## 5. 第三轮修正（2026-08-12 用户反馈）

### 5.1 根因：透明窗口逐像素点击穿透（P0）

已复现：Clear 模式下向弹窗内合成点击（卡片展开箭头），弹窗立即关闭、
点击落到下层窗口。机制：macOS 对无边框透明窗口做**逐像素命中测试**，
像素 alpha 低于阈值（≈0.05）时鼠标事件穿透到下层窗口；`glassEffect`
的折射是合成层效果，窗口自身缓冲区在纯玻璃区域 alpha≈0 → 点击/悬停
全部穿透 → 本 app 的 global event monitor 认为是"外部点击"而关闭弹窗。
这同时解释了"点击穿透到桌面"“悬停无反馈”“选中态不存在"。

### 5.2 修复设计：Clear = 透明玻璃 + 显式深色遮罩（scrim）

用户明确要求的模型：透明玻璃之上有一层**深色遮罩**，Popup opacity
滑杆控制遮罩深浅；即使"完全透明"档也保留遮罩下限。

- Clear 底衬重构为两层，均沿统一剪影绘制：
  1. `Glass.clear`（固定、无/极轻 tint）——折射来源；
  2. **scrim**：普通 `DashboardTheme.canvas` 颜色层（非 glass tint），
     opacity = 滑杆值映射，**硬下限 ≥0.10**（保证窗口像素 alpha 始终
     高于穿透阈值，事件永远命中）。
- 滑杆从 0 → 1 必须产生**肉眼明显**的深浅变化（此前 66%→30% 几乎
  不可见，因为 glass tint 会饱和；scrim 是普通颜色层，线性可见）。
- Frosted 同样加 scrim 下限护栏（低滑杆值时材质层也可能过透）。
- 卡片 tint 的 0.42 衰减系数保留；若 scrim 叠加后卡片过暗可下调。

### 5.2b 模式身份必须与滑杆解耦（用户单实例复确认"映射反了"后新增）

用户退出正式版后仍报告"Frosted 显透明、Clear 显模糊"。机制：两种模式
的可辨识身份目前由滑杆浓度承载，而非材质本身——

- Frosted 用 `.ultraThinMaterial`（系统最薄的模糊档），滑杆低时
  模糊几乎不可见 → 读作"透明"；
- Clear 的深色 tint 随滑杆升高压暗折射 → 读作"模糊/闷"。

修复要求（与 5.2 的 scrim 重构合并执行）：

1. **Frosted 换厚材质**：`.regularMaterial` 或更厚（或 `Glass.regular`
   不带重 tint），保证滑杆在任何位置背后内容都被明显糊化、
   不可辨认细节；
2. **Clear 保持清晰折射**：背后内容轮廓/文字在任何滑杆位置都应
   可辨（遮罩只降亮度,不加模糊）；
3. 滑杆只控制两种模式共用的 scrim 深浅,不再参与材质浓度;
4. 验收必须覆盖滑杆两端：Frosted@10% 仍明显模糊、Clear@90% 仍
   清晰折射,两两对比截图肉眼立辨。

### 5.3 随修复必须重新验证的行为

1. **点击**：用 clicktest 合成点击卡片展开箭头 → 卡片展开、弹窗不关；
   点击卡片间空白 → 弹窗不关。
2. **悬停**：Clear 与 Frosted 下悬停卡片均有可见亮起，移开恢复
   （在真实弹窗上验证，不是模拟背景板）。
3. **映射方向**：单实例下 Frosted=毛玻璃、Clear=透明+遮罩。
4. 滑杆三档（10%/50%/90%）截图,遮罩深浅差异肉眼可辨。

### 5.4 环境注意（穿透误判的另一半来源）

用户机器上**正式版 TokenRemain.app 与 TokenRemain Dev.app 同时运行**，
菜单栏两套相同图标、两套独立偏好——用户在 A 的设置窗口切换、点开的
却是 B 的弹窗，造成"映射反了/滑杆无效"的表象。验证时只操作 Dev
（`pkill -x UsageDockDev`,不要动正式版进程 UsageDock）,并在交付
说明中提醒用户测试期间退出正式版。

## 5.5 第四轮修正：非激活窗口的玻璃降级渲染（2026-08-12）

用户反馈"实拍效果在本地 dev 无法重现"，实验证实：macOS 26 对**非激活
窗口**中的 Liquid Glass / 材质采用不透明的降级渲染。真实点击状态栏
图标打开弹窗时 app 处于非激活态、面板仅 `orderFrontRegardless()`——
玻璃、遮罩、滑杆全部失效,呈现死黑;而 `--open-popover` 测试通道会
激活 app,所以此前所有验收截图都拍不到用户看到的画面。

- 修复：`show()` 常规路径改为 `makeKeyAndOrderFront`——nonactivating
  panel 可取得 key 而不抢 app 级焦点,玻璃随即按激活态渲染。
- 验收方法论修正：**必须用真实路径验证**（合成点击状态栏图标本身,
  AX API 取图标坐标）,`--open-popover` 通道只作辅助。
- 卡片浓度解耦（同日）：卡片 tint/边线/lift 改为按风格固定常量
  （`cardTintOpacity`）,滑杆只控制壳体遮罩,职责分离为
  "按钮=材质,滑杆=遮罩深浅"。

## 6. 验收清单（Fable 执行）

1. `swift build` 通过；`swift test`（带 Xcode DEVELOPER_DIR）通过。
2. `--open-popover` 截图 × {Clear, Frosted} × 亮色/彩色桌面：
   - Clear：壳体可见真实折射/透过桌面内容，不再是平涂+线框；
   - beak 顶点圆润（≈3.5pt），与壳体一条连续 hairline 包裹，无接缝；
   - 卡片未发黑，正文/次级文本可读；
   - Frosted：除 beak 圆角外与改动前视觉一致；
   - 两模式切换动画平滑，无图层"弹入"。
3. 不出现双重描边、beak 与壳体错位（arrowCenterX 夹取行为不变）。
