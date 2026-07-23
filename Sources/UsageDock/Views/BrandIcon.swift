import AppKit
import SwiftUI

/// Provider identity marks with separate screen and menu-bar renderers.
///
/// Claude keeps its bundled vendor artwork. Codex is drawn as native vector
/// geometry so its blue-violet flower and white prompt stay smooth at every
/// SwiftUI size. The menu-bar variant is also drawn in color so the small icon
/// retains both the blue-violet identity and the white `>_` prompt.
struct BrandIcon: View {
    let provider: ProviderQuota.Provider
    var color: Color?

    private var tint: Color {
        color ?? DashboardTheme.claudeBrand
    }

    @ViewBuilder
    var body: some View {
        switch provider {
        case .claude:
            Image(nsImage: Self.claudeImage())
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(tint)
                .accessibilityLabel(provider.rawValue)
        case .codex:
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(
                    CodexBrandGlyph.flower(in: rect),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(hex: 0xC49AF8),
                            Color(hex: 0x6A78FF),
                            Color(hex: 0x245BFF)
                        ]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                    )
                )
                context.stroke(
                    CodexBrandGlyph.prompt(in: rect),
                    with: .color(.white),
                    style: StrokeStyle(
                        lineWidth: min(size.width, size.height) * CodexBrandGlyph.promptStrokeRatio,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
            .accessibilityLabel(provider.rawValue)
        case .cursor:
            // Cursor 官方标:实心等距立方体。整块六边形剪影填充,
            // 再用 destinationOut 抠出三条棱线,呈现顶面 + 两个侧面。
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                var solid = context
                solid.fill(CursorBrandGlyph.hexagon(in: rect), with: .style(.foreground))
                solid.blendMode = .destinationOut
                solid.stroke(
                    CursorBrandGlyph.innerY(in: rect),
                    with: .color(.black),
                    style: StrokeStyle(
                        lineWidth: min(size.width, size.height) * CursorBrandGlyph.seamRatio,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
            .accessibilityLabel(provider.rawValue)
        case .grok:
            // xAI 官方标:斜杠 + 半臂 + 竖杆组成的 "X-1" 实心组合。
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(MonoBrandGlyph.grokMark(in: rect), with: .style(.foreground))
            }
            .accessibilityLabel(provider.rawValue)
        case .zai:
            // Z.ai 官方标:粗体几何 "Z" 实心字标。
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(MonoBrandGlyph.zed(in: rect), with: .style(.foreground))
            }
            .accessibilityLabel(provider.rawValue)
        case .copilot, .devin, .openrouter, .antigravity, .opencode:
            // 其余 provider 共用"填充/描边路径"式单色字标。
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                let glyph = MonoBrandGlyph.glyph(for: provider)
                if glyph.filled {
                    context.fill(glyph.path(rect), with: .style(.foreground))
                } else {
                    context.stroke(
                        glyph.path(rect),
                        with: .style(.foreground),
                        style: StrokeStyle(
                            lineWidth: min(size.width, size.height) * 0.10,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
            .accessibilityLabel(provider.rawValue)
        default:
            // token-monitor 兼容层的长尾 provider:圆角方框 + 粗体首字母,
            // 始终与名称标签同现,不靠图形单独辨识。
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                let inset = min(size.width, size.height) * 0.06
                context.stroke(
                    Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: size.width * 0.24),
                    with: .style(.foreground),
                    style: StrokeStyle(lineWidth: min(size.width, size.height) * 0.09)
                )
                let text = Text(MonoBrandGlyph.initials(for: provider))
                    .font(.system(size: size.height * 0.42, weight: .bold, design: .rounded))
                context.draw(context.resolve(text), at: CGPoint(x: rect.midX, y: rect.midY))
            }
            .accessibilityLabel(provider.rawValue)
        }
    }

    /// Returns provider artwork for menu-bar attachments. Claude remains a
    /// system-tinted template; Codex deliberately keeps its native color.
    static func image(
        for provider: ProviderQuota.Provider,
        size: CGFloat = 32
    ) -> NSImage {
        let image: NSImage
        switch provider {
        case .claude:
            image = claudeImage().copy() as? NSImage
                ?? NSImage(size: NSSize(width: size, height: size))
            image.isTemplate = true
        case .codex:
            image = CodexBrandGlyph.colorImage(size: size)
            image.isTemplate = false
        case .cursor:
            image = CursorBrandGlyph.templateImage(size: size)
            image.isTemplate = true
        case .grok:
            image = MonoBrandGlyph.templateImage(size: size, path: MonoBrandGlyph.grokMark(in:))
            image.isTemplate = true
        case .zai:
            image = MonoBrandGlyph.templateImage(size: size, path: MonoBrandGlyph.zed(in:))
            image.isTemplate = true
        case .copilot, .devin, .openrouter, .antigravity, .opencode:
            let glyph = MonoBrandGlyph.glyph(for: provider)
            image = MonoBrandGlyph.templateImage(size: size, path: glyph.path, filled: glyph.filled)
            image.isTemplate = true
        default:
            image = MonoBrandGlyph.initialsTemplateImage(
                size: size,
                initials: MonoBrandGlyph.initials(for: provider)
            )
            image.isTemplate = true
        }

        image.size = NSSize(width: size, height: size)
        return image
    }

    private static func claudeImage() -> NSImage {
        AppResourceBundle.bundle.url(forResource: "claude", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(
                systemSymbolName: "questionmark.circle",
                accessibilityDescription: ProviderQuota.Provider.claude.rawValue
            )
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }
}

/// 实心单色字标(Grok 的 X-1 组合 / Z.ai 的 Z),SwiftUI 与 AppKit 共用几何。
enum MonoBrandGlyph {
    /// xAI 官方标的三段实心构件:完整斜杠(/)、X 的左上半臂、右侧竖杆。
    /// 半臂止于斜杠中点,竖杆替代 X 的右下臂——即官方 "X-1" 读法。
    static func grokMark(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        // 完整斜杠:自右上落向左下。
        path.move(to: point(0.56, 0.12))
        path.addLine(to: point(0.72, 0.12))
        path.addLine(to: point(0.28, 0.88))
        path.addLine(to: point(0.12, 0.88))
        path.closeSubpath()
        // 左上半臂:自左上斜向中心并穿过斜杠一小段,形成 X 的交叉读感
        // (止于交点会退化成 "Y")。
        path.move(to: point(0.12, 0.12))
        path.addLine(to: point(0.28, 0.12))
        path.addLine(to: point(0.58, 0.60))
        path.addLine(to: point(0.50, 0.74))
        path.closeSubpath()
        // 右侧竖杆(“1”),顶端随斜杠角度斜切。
        path.move(to: point(0.72, 0.24))
        path.addLine(to: point(0.88, 0.12))
        path.addLine(to: point(0.88, 0.88))
        path.addLine(to: point(0.72, 0.88))
        path.closeSubpath()
        return path
    }

    /// 粗体几何 "Z":上下横杠 + 等宽斜杠的一体多边形。
    static func zed(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.14, 0.14))
        path.addLine(to: point(0.86, 0.14))
        path.addLine(to: point(0.86, 0.30))
        path.addLine(to: point(0.40, 0.70))
        path.addLine(to: point(0.86, 0.70))
        path.addLine(to: point(0.86, 0.86))
        path.addLine(to: point(0.14, 0.86))
        path.addLine(to: point(0.14, 0.70))
        path.addLine(to: point(0.60, 0.30))
        path.addLine(to: point(0.14, 0.30))
        path.closeSubpath()
        return path
    }

    static func templateImage(
        size: CGFloat,
        path: @escaping (CGRect) -> Path,
        filled: Bool = true
    ) -> NSImage {
        let dimensions = NSSize(width: size, height: size)
        let image = NSImage(size: dimensions, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            context.addPath(path(rect).cgPath)
            if filled {
                context.setFillColor(NSColor.black.cgColor)
                context.fillPath()
            } else {
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(min(rect.width, rect.height) * 0.10)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 长尾 provider 的首字母标。
    static func initials(for provider: ProviderQuota.Provider) -> String {
        switch provider {
        case .deepseek: return "DS"
        case .kimi: return "K"
        case .minimax: return "MX"
        case .mimo: return "Mo"
        case .qoder: return "Q"
        case .kiro: return "Kr"
        case .volcengine: return "V"
        case .ollama: return "OL"
        default: return String(provider.displayName.prefix(1))
        }
    }

    static func initialsTemplateImage(size: CGFloat, initials: String) -> NSImage {
        let dimensions = NSSize(width: size, height: size)
        let image = NSImage(size: dimensions, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let inset = min(rect.width, rect.height) * 0.06
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(min(rect.width, rect.height) * 0.09)
            context.addPath(
                CGPath(
                    roundedRect: rect.insetBy(dx: inset, dy: inset),
                    cornerWidth: rect.width * 0.24,
                    cornerHeight: rect.height * 0.24,
                    transform: nil
                )
            )
            context.strokePath()

            let font = NSFont.systemFont(ofSize: rect.height * 0.42, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let text = NSAttributedString(string: initials, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - 第 6–10 个 provider 的字标

    struct Glyph {
        let path: (CGRect) -> Path
        let filled: Bool
    }

    static func glyph(for provider: ProviderQuota.Provider) -> Glyph {
        switch provider {
        case .copilot: return Glyph(path: copilotGoggles(in:), filled: false)
        case .devin: return Glyph(path: devinCluster(in:), filled: true)
        case .openrouter: return Glyph(path: openRouterFork(in:), filled: false)
        case .antigravity: return Glyph(path: antigravityArc(in:), filled: false)
        case .opencode: return Glyph(path: opencodePrompt(in:), filled: false)
        default: return Glyph(path: zed(in:), filled: true)
        }
    }

    private static func point(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    /// Copilot:护目镜——圆角面罩轮廓 + 两只竖圆角眼。
    static func copilotGoggles(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(
                x: rect.minX + 0.12 * rect.width, y: rect.minY + 0.26 * rect.height,
                width: 0.76 * rect.width, height: 0.48 * rect.height
            ),
            cornerSize: CGSize(width: 0.16 * rect.width, height: 0.16 * rect.height)
        )
        for x in [0.30, 0.62] {
            path.addRoundedRect(
                in: CGRect(
                    x: rect.minX + x * rect.width, y: rect.minY + 0.38 * rect.height,
                    width: 0.08 * rect.width, height: 0.24 * rect.height
                ),
                cornerSize: CGSize(width: 0.04 * rect.width, height: 0.04 * rect.height)
            )
        }
        return path
    }

    /// Devin:三枚小六边形品字排列(蜂窝簇)。
    static func devinCluster(in rect: CGRect) -> Path {
        func hexagon(center: CGPoint, radius: CGFloat) -> Path {
            var path = Path()
            for index in 0..<6 {
                let angle = (CGFloat(index) * 60 - 90) * .pi / 180
                let vertex = CGPoint(
                    x: center.x + radius * cos(angle),
                    y: center.y + radius * sin(angle)
                )
                if index == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
            }
            path.closeSubpath()
            return path
        }
        let radius = min(rect.width, rect.height) * 0.21
        var path = Path()
        path.addPath(hexagon(center: point(rect, 0.50, 0.30), radius: radius))
        path.addPath(hexagon(center: point(rect, 0.30, 0.66), radius: radius))
        path.addPath(hexagon(center: point(rect, 0.70, 0.66), radius: radius))
        return path
    }

    /// OpenRouter:一进两出的分流箭头。
    static func openRouterFork(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(rect, 0.12, 0.50))
        path.addLine(to: point(rect, 0.42, 0.50))
        // 上分支 + 箭头
        path.move(to: point(rect, 0.42, 0.50))
        path.addCurve(
            to: point(rect, 0.78, 0.28),
            control1: point(rect, 0.56, 0.50),
            control2: point(rect, 0.62, 0.28)
        )
        path.move(to: point(rect, 0.70, 0.20))
        path.addLine(to: point(rect, 0.86, 0.28))
        path.addLine(to: point(rect, 0.70, 0.38))
        // 下分支 + 箭头
        path.move(to: point(rect, 0.42, 0.50))
        path.addCurve(
            to: point(rect, 0.78, 0.72),
            control1: point(rect, 0.56, 0.50),
            control2: point(rect, 0.62, 0.72)
        )
        path.move(to: point(rect, 0.70, 0.62))
        path.addLine(to: point(rect, 0.86, 0.72))
        path.addLine(to: point(rect, 0.70, 0.80))
        return path
    }

    /// Antigravity:上升弧线 "A"——两段外扩弧脚。
    static func antigravityArc(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(rect, 0.16, 0.82))
        path.addCurve(
            to: point(rect, 0.50, 0.18),
            control1: point(rect, 0.32, 0.72),
            control2: point(rect, 0.42, 0.34)
        )
        path.addCurve(
            to: point(rect, 0.84, 0.82),
            control1: point(rect, 0.58, 0.34),
            control2: point(rect, 0.68, 0.72)
        )
        return path
    }

    /// OpenCode:方角终端框 + 提示符 ">_"。
    static func opencodePrompt(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(
                x: rect.minX + 0.12 * rect.width, y: rect.minY + 0.14 * rect.height,
                width: 0.76 * rect.width, height: 0.72 * rect.height
            ),
            cornerSize: CGSize(width: 0.10 * rect.width, height: 0.10 * rect.height)
        )
        path.move(to: point(rect, 0.28, 0.38))
        path.addLine(to: point(rect, 0.44, 0.52))
        path.addLine(to: point(rect, 0.28, 0.66))
        path.move(to: point(rect, 0.52, 0.66))
        path.addLine(to: point(rect, 0.70, 0.66))
        return path
    }
}

/// Cursor 的实心等距立方体:正六边形剪影,中心向三个间隔顶点的 "Y" 棱线
/// 以镂空呈现,分出顶面与两个侧面。
enum CursorBrandGlyph {
    /// 棱线(镂空缝)相对边长的宽度。
    static let seamRatio: CGFloat = 0.06

    private static func vertex(_ index: Int, in rect: CGRect) -> CGPoint {
        // 顶点从正上方开始每 60° 一个,内缩 6% 给线宽留边。
        let radius = min(rect.width, rect.height) / 2 * 0.94
        let angle = (CGFloat(index) * 60 - 90) * .pi / 180
        return CGPoint(
            x: rect.midX + radius * cos(angle),
            y: rect.midY + radius * sin(angle)
        )
    }

    static func hexagon(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: vertex(0, in: rect))
        for index in 1..<6 {
            path.addLine(to: vertex(index, in: rect))
        }
        path.closeSubpath()
        return path
    }

    static func innerY(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for index in [1, 3, 5] {
            path.move(to: center)
            path.addLine(to: vertex(index, in: rect))
        }
        return path
    }

    static func templateImage(size: CGFloat) -> NSImage {
        let dimensions = NSSize(width: size, height: size)
        let image = NSImage(size: dimensions, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(hexagon(in: rect).cgPath)
            context.fillPath()
            // 棱线以 destinationOut 抠出透明缝,模板渲染只看 alpha。
            context.setBlendMode(.destinationOut)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(min(rect.width, rect.height) * seamRatio)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(innerY(in: rect).cgPath)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Geometry shared by the SwiftUI color glyph and AppKit template glyph.
enum CodexBrandGlyph {
    static let promptStrokeRatio: CGFloat = 0.115

    static func flower(in rect: CGRect) -> Path {
        func ellipse(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: rect.minX + x * rect.width,
                y: rect.minY + y * rect.height,
                width: width * rect.width,
                height: height * rect.height
            )
        }

        var path = Path()
        // A filled center joins six overlapping rounded lobes into one smooth
        // flower/cloud silhouette without raster cutout edges.
        path.addEllipse(in: ellipse(0.20, 0.20, 0.60, 0.60))
        path.addEllipse(in: ellipse(0.30, 0.04, 0.40, 0.40))
        path.addEllipse(in: ellipse(0.56, 0.16, 0.38, 0.40))
        path.addEllipse(in: ellipse(0.58, 0.45, 0.38, 0.40))
        path.addEllipse(in: ellipse(0.34, 0.58, 0.40, 0.38))
        path.addEllipse(in: ellipse(0.08, 0.44, 0.40, 0.42))
        path.addEllipse(in: ellipse(0.06, 0.16, 0.42, 0.42))
        return path
    }

    static func prompt(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + x * rect.width,
                y: rect.minY + y * rect.height
            )
        }

        var path = Path()
        path.move(to: point(0.30, 0.34))
        path.addLine(to: point(0.45, 0.50))
        path.addLine(to: point(0.30, 0.66))
        path.move(to: point(0.55, 0.66))
        path.addLine(to: point(0.73, 0.66))
        return path
    }

    static func colorImage(size: CGFloat) -> NSImage {
        let dimensions = NSSize(width: size, height: size)
        let image = NSImage(size: dimensions, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            context.saveGState()
            context.addPath(flower(in: rect).cgPath)
            context.clip()

            let colors = [
                NSColor(srgbRed: 0xC4 / 255, green: 0x9A / 255, blue: 0xF8 / 255, alpha: 1).cgColor,
                NSColor(srgbRed: 0x6A / 255, green: 0x78 / 255, blue: 0xFF / 255, alpha: 1).cgColor,
                NSColor(srgbRed: 0x24 / 255, green: 0x5B / 255, blue: 0xFF / 255, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.55, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.midX, y: rect.minY),
                    end: CGPoint(x: rect.midX, y: rect.maxY),
                    options: []
                )
            }
            context.restoreGState()

            context.addPath(prompt(in: rect).cgPath)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(min(rect.width, rect.height) * promptStrokeRatio)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            return true
        }
        image.isTemplate = false
        return image
    }
}
