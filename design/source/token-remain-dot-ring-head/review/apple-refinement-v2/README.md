# O4-C Apple 材质适配 v2 — 阶段 A

2026-10-27，按用户要求在定稿几何上做适度加工，继续停在评审阶段。没有替换两个仓库的现用资产，没有改产品代码、偏好、表情或全身机器人。

优先看 `contact-sheet-native.png`（原稿 / AI 材质方向 / 原生 Liquid Glass，以及 macOS、iOS 六种外观）和 `native-preview.png`（三个平台的原生输出）。`contact-sheet.png`、`platform-preview.png` 是此前制作的手工材质示意，不能冒充系统渲染；新的 native 图已补齐当时缺失的原生证据。

## 加工内容

- 外壳保留紫色身份，增加柔和倒角、高光和厚度层次；屏幕保持深色内嵌感。
- 20 点环的位置、尺寸、顺序和静态 15 亮 / 5 暗不变。眼睛保持固定圆形和平静表情。
- medium 仍为 10 点、8 亮；small 仍为放大头部、无点环、无厚度带。
- 点和眼睛保持独立的非 glass 图层。Head 采用 combined lighting，避免相接外壳、天线和厚度带各自产生不必要的接缝高光。
- Default/Dark 保持原始源色；Tinted 使用规定灰阶作为输入。系统还会叠加用户的主题 tint，原生 Tinted 输出因此可以带主题色。Clear 交给系统处理。

这个方向遵循 Apple 对简洁背景、清楚分层和跨外观识别度的建议：[App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)。

## 文件分工

| 文件/目录 | 用途 |
| --- | --- |
| `material-study-imagegen.png` | 内置 ImageGen 生成的材质方向稿，1254×1254；不是颜色精确的生产图标 |
| `imagegen-prompt.txt` | 生成该方向稿的完整提示词 |
| `masters/` | full/medium/small × Default/Dark/Tinted 的可编辑 SVG 和 sRGB PNG；手工材质示意 |
| `sizes/` | 每个变体的 1024、256、128、64、48、32、24、16px 样张 |
| `platforms/` | 手工材质稿的平台裁切示意，iOS 圆角仅作说明 |
| `runtime/` | 不同点亮数的手工材质场景示意，不是运行时实现 |
| `composer/` | 三个原生可编辑 `.icon` 工程；原始平面 SVG 图层，材质由系统生成 |
| `native/` | `ictool` 原生渲染与导出记录；保留 Display P3 ICC profile |
| `validation.json` | 本轮几何、引用、可读性、颜色和保留用户改动的核对记录 |

## 原生验证

用户已亲自接受 Icon Composer 协议。`TokenRemain-full.icon` 已在 GUI 中成功打开，显示 Face、Head、Ring 三组共 7 图层，并保持打开供评审。使用 Xcode 26.6 (17F113)、Icon Composer/ictool 1.6 (99.1) 完成 25 项原生输出：full 的 iOS/macOS 六种外观与 watchOS Default，以及 medium/small 的 macOS 六种外观。

三个 macOS `.icon` 仍只声明 macOS。iOS/watchOS 导出使用另一个仅供评审的 `TokenRemain-platform-preview.icon`，显式启用 shared square 与 watchOS circle；因此 watchOS 样张确实经过原生圆形 enclosure 处理。这个副本不意味着决定将 iOS 项目改为 `.icon`。

工程修正了初稿静态检查未发现的两个兼容问题：本机 sRGB SVG 默认解释要求省略 `color-space-for-untagged-svg-colors`（字面值 `srgb` 会导致读取失败）；`.icon` 图层数组按前到后存储，需要反转规格中从下到上的列表。新工程已通过实际导出；初轮原稿保持原样，不将其静态检查结果当作原生验证。

所有原生 Assets 的 SVG 内容仍与已核对几何的初轮图层一致，背景 fill、亮点与眼睛源色不变。原生导出的 Display P3 像素需先转到 sRGB 再比较；青色采样精确回到 `#3ECFE0`。深色屏幕在 8 位 ICC 往返中出现 1 级量化差（源 `#070B12`，导出转回 sRGB 为 `#060A12`），已记录，不能将原生 PNG 宣称为所有像素均与源 Hex 完全一致。

本轮资产检查 129 项通过，并保留上述 1 项深色像素精确性不一致记录；未放宽断言或隐去该结果。已有用户文件与初轮评审材料逐文件 hash 核对无变化。

AI 稿与可编辑矢量稿是同一材质方向的不同精确度表达。AI 稿经检查有 15 个亮点和 2 个眼睛，亮点圆心归一化到 1024 后最大偏差约 0.77px，但背景采样已不同于源色，因此只用于评审光感。矢量稿保留精确的原始图元，渐变和高光新增的色值属于本轮材质加工。原生工程不烘焙这些手工渐变，避免与系统效果叠加。

Clear 静态输出中眼睛和亮点可辨；Tinted 的显示结果随系统 tint 而变化。尚未做各种壁纸、动态光照下的全面验证。GUI 打开和 ictool 导出不等于 App 已接入：资产目录编译、iOS/watchOS 模拟器主屏幕、真实 Dock 切换一致性仍属于获批后的阶段 B。

## 复现与边界

`generate.mjs` 使用已安装的 sharp，通过 `SHARP_MODULE` 指向现有依赖即可，不需要安装新包。它只写本目录。所有原始评审材料和现用资产均保留。阶段 B 仍需用户批准这次视觉结果后再开始。
