# O4-C 阶段 A 评审材料

日期：2026-10-27。只制作评审资产，未进入阶段 B，未替换任何正在使用的图标。

## 评审入口

- `contact-sheet.png`：3456×3360，三个变体各含 1024、256、128、64、48、32、24、16px 原尺寸样张；另含裁切×外观矩阵、七种额度状态和小尺寸最近邻放大图。
- `masters/default/`：full、medium、small 的 1024 SVG 和带 sRGB profile 的 PNG。
- `masters/dark/`：与 Default 像素一致。
- `masters/tinted/`：白色眼睛/亮点；天线 85%、外壳 70%、厚度带 45%、暗点 20% 灰；背景和屏幕黑色。
- `composer/TokenRemain-{full,medium,small}.icon/`：可编辑工程包及其 `Assets/`，仅声明 macOS。full/medium 含 Ring、Head、Face 三组；small 无点环和厚度带，故只含 Head、Face。
- `layers/`：按变体拆出的透明 SVG 图层；`sizes/`：全套尺寸 PNG；`runtime/`：20、15、10、5、1、0 颗亮点和无数据七种状态的 SVG/PNG。
- `geometry.json` 和 `validation.json`：图元参数与检查结果。

所有 tile 主稿为全出血正方形，不预烘焙系统圆角。评审图里的 macOS 形状按四边 100、824×824、圆角 185.4 缩入；watchOS 直接圆裁。iOS 圆角 224 仅为评审示意，不能作为生产裁切路径。flat PNG 不包含仿制玻璃效果。

## 几何与颜色验证

参考源位于本仓库另一个工作树：`.claude/worktrees/app-logo-concepts-2aeb83/design/source/token-remain-dot-ring-head/reference/`。该工作树未被修改。`reference-snapshot/` 保存三张原始 SVG 的只读内容副本；原路径及 SHA-256 见 `validation.json`。

逐个对照 SVG 的矩形、圆、坐标、圆角、半径和 fill。参考圆心只保留一位小数，主稿保留六位，所以有以下微小差异：

| 变体 | 最大坐标差 | 填充色 |
| --- | --- | --- |
| full | 0.022607 px | 全部一致 |
| medium | 0.034662 px | 全部一致 |
| small | 0 px | 全部一致 |

几何差异远小于 ±2px。PNG 内部实色采样与指定 sRGB 值一致；抗锯齿边缘会正常混色。

152 项资产检查通过，另有 3 项独立参考对照通过。16px small 的青色眼睛分成两个独立像素区域；32px medium 的 8 个亮点互不粘连。Default 与 Dark 解码后像素一致。watchOS 点环外沿半径 430，距圆裁边缘 82px。

0% 与无数据按规格具有相同外观；这里只提供评审样张，未实现运行时状态身份、百分比映射或 Dock 重绘逻辑，不将这些图片当作产品功能测试。

## Icon Composer 验证边界

工程已配置：Ring/Face 的 glass 关闭；Head 高光开启、translucency 关闭、neutral shadow 0.5；Default/Dark 固定色，Tinted 按上述亮度覆盖；Clear 使用系统默认处理。

当前 Icon Composer 首次使用许可协议待用户亲自确认。工程 JSON 与引用文件已静态检查；尚未通过原生打开、编译或渲染验证。Liquid Glass 和 Clear 可读性不能由平面样张替代，仍需补充原生预览。`.icon` 序列化字段参考 [IconComposerModel 作者的格式说明](https://github.com/peterpoliwoda/icon-composer-template)，以本机实际打开/编译结果为最终依据；Apple 的工作流参见 [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。

## 范围与复现

基线：macOS 主工作区 `dev` / `c30f66fdd84e23d0ef8e9670709600085eb8794e`；iOS 主工作区 `main` / `638935023207c9f0012f5001bad6f3dcc781b017`。两个工作区均已有用户改动，包括 iOS/Watch 当前图标；本轮只新增本目录内容。

主工作区与规格来源工作树存在版本差异：例如主工作区尚无 `Resources/AppIcon.icon`，Dock renderer 仍为 Claude/Codex 双参数入口。阶段 B 需先选定正确实现基线；本轮未移植其他工作树的代码或改动。

重新生成本目录主稿和评审图：`python3 design/source/token-remain-dot-ring-head/review/generate_review.py`，依赖本机 Pillow。它只写本目录；不会生成现用 icns、ico、appiconset，不调用表情资源脚本。验证记录为本轮独立检查结果，生成器不会伪造或自动刷新验证记录。

未执行应用测试、产品构建、模拟器安装、生产安装、提交、推送或部署。阶段 A 获用户批准前不进入阶段 B；规格 §12 的机器人统一不在此次范围。
