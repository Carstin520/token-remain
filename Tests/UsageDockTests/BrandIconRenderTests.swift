import AppKit
import Testing
@testable import UsageDock

@Suite("Brand icon rendering")
struct BrandIconRenderTests {
    @Test("Branded providers have explicit artwork; shared products reuse only their real brand")
    func authenticArtworkCoverage() throws {
        // No published mark exists yet (Lobe Icons 1.95.1 has none); these
        // render the generic fallback glyph rather than an invented logo.
        let unbrandedProviders: Set<ProviderQuota.Provider> = [.factory, .augment]
        // Products of the same brand share that brand's real mark.
        let sharedBrand: [ProviderQuota.Provider: String] = [.zaiTeam: "zai", .museCode: "muse"]
        let resourceProviders = ProviderQuota.Provider.displayOrder.filter {
            $0 != .claude && $0 != .codex && $0 != .thirdParty && !unbrandedProviders.contains($0)
        }
        var resourceNames = Set<String>()

        for provider in unbrandedProviders {
            #expect(BrandIcon.artwork(for: provider) == nil)
        }

        for provider in resourceProviders {
            let artwork = try #require(
                BrandIcon.artwork(for: provider),
                "\(provider.displayName) is missing an explicit brand artwork mapping"
            )
            let inserted = resourceNames.insert(artwork.resourceName).inserted
            if let brand = sharedBrand[provider] {
                #expect(!inserted && artwork.resourceName == brand)
            } else {
                #expect(inserted, "\(provider.displayName) reuses another provider's brand resource")
            }

            let resourceURL = try #require(
                BrandIcon.resourceURL(for: artwork),
                "\(provider.displayName) artwork is not available to the renderer"
            )
            #expect(resourceURL.pathExtension == "png")
            #expect(FileManager.default.fileExists(atPath: resourceURL.path))
            if let monochrome = artwork.monochromeResourceName {
                #expect(!artwork.isTemplate, "\(provider.displayName) only needs a template for color artwork")
                #expect(BrandIcon.resourceURL(for: .init(resourceName: monochrome, isTemplate: true)) != nil)
            }
        }

        #expect(resourceNames.count == resourceProviders.count - sharedBrand.count)
        #expect(BrandIcon.artwork(for: .thirdParty) == nil)
    }

    @Test("Claude rendering loads the real brand asset instead of a fallback symbol")
    @MainActor
    func claudeArtworkIsAvailable() throws {
        let resource = try #require(BrandIcon.claudeResourceURL())
        #expect(resource.lastPathComponent == "claude.png")
        let source = try #require(NSImage(contentsOf: resource))
        source.size = NSSize(width: 64, height: 64)
        let rendered = BrandIcon.image(for: .claude, size: 64)
        let expected = try #require(source.tiffRepresentation)
        let actual = try #require(rendered.tiffRepresentation)
        #expect(actual == expected)
    }

    @Test("Menu-bar brand images render with visible content for every provider")
    @MainActor
    func rendersAllProviders() throws {
        let outputDirectory = ProcessInfo.processInfo.environment["USAGEDOCK_ICON_DUMP_DIR"]
        for provider in ProviderQuota.Provider.displayOrder {
            let image = BrandIcon.image(for: provider, size: 128)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))

            // 图标必须画出实际内容:统计非透明像素占比,空白即失败。
            var opaque = 0
            let sampleStep = 4
            for x in stride(from: 0, to: bitmap.pixelsWide, by: sampleStep) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: sampleStep) {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 {
                        opaque += 1
                    }
                }
            }
            let samples = (bitmap.pixelsWide / sampleStep) * (bitmap.pixelsHigh / sampleStep)
            let coverage = Double(opaque) / Double(max(1, samples))
            #expect(coverage > 0.05, "\(provider.displayName) icon looks empty (coverage \(coverage))")
            // Official app-tile marks such as Kiro intentionally fill almost
            // the entire square, so reject only a truly opaque fallback block.
            #expect(coverage < 0.99, "\(provider.displayName) icon is a solid block (coverage \(coverage))")

            if let outputDirectory,
               let png = bitmap.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: outputDirectory)
                    .appendingPathComponent("brand-\(provider.displayName.lowercased()).png")
                try? png.write(to: url)
            }
        }
    }

    @Test("Grok menu-bar glyph is inset so the diagonal mark does not flush the canvas", arguments: [13.0, 64.0])
    @MainActor
    func grokMenuBarImageIsPadded(size: Double) throws {
        let raw = BrandIcon.image(for: .grok, size: size)
        for colored in [false, true] {
            let menu = BrandIcon.menuBarImage(for: .grok, size: size, colored: colored)
            let rawPad = try #require(minPaddingRatio(of: raw))
            let menuPad = try #require(minPaddingRatio(of: menu))
            #expect(rawPad < 0.03, "Grok's Lobe PNG should still touch the canvas (got \(rawPad))")
            #expect(menuPad > 0.10, "menu-bar Grok glyph should keep inner padding (got \(menuPad))")
            #expect(menu.size == NSSize(width: size, height: size))
            #expect(menu.isTemplate)

            let tiff = try #require(menu.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            #expect(bitmap.pixelsWide == Int(size * 2))
            #expect(bitmap.pixelsHigh == Int(size * 2))
        }
    }

    @Test("Menu-bar rasterization keeps Claude and Codex filling their canvas", arguments: [13.0, 64.0])
    @MainActor
    func menuBarRasterizationDoesNotShrinkAlreadyPaddedMarks(size: Double) throws {
        for provider in [ProviderQuota.Provider.claude, .codex] {
            let raw = BrandIcon.image(for: provider, size: size)
            let rawPad = try #require(minPaddingRatio(of: raw))
            for colored in [false, true] {
                let menu = BrandIcon.menuBarImage(for: provider, size: size, colored: colored)
                let menuPad = try #require(minPaddingRatio(of: menu))
                #expect(
                    abs(menuPad - rawPad) < 0.06,
                    "\(provider.displayName) padding drifted from \(rawPad) to \(menuPad) (colored: \(colored))"
                )
            }
        }
    }

    @Test("Status title keeps the monospaced font and enlarged icons drawn by an attachment cell")
    @MainActor
    func statusTitleKeepsOriginalMetrics() throws {
        #expect(StatusBarController.statusFont == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        #expect(StatusBarController.statusIconSize > 13, "Icons are enlarged from the original 13pt slot")
        for colored in [false, true] {
            let title = StatusBarController.statusTitle(
                segments: [(.claude, "99%"), (.codex, "52%")],
                displayMode: .full,
                coloredIcons: colored
            )
            #expect(title.string.hasSuffix(" 52%"))
            #expect(title.attribute(.font, at: 2, effectiveRange: nil) as? NSFont == StatusBarController.statusFont)
            let attachment = try #require(title.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
            // Template colors are applied by the attachment cell.
            #expect(attachment.attachmentCell is StatusIconAttachmentCell)
        }
    }

    @Test("Status title narrows only its spaces, keeping numerals tabular", arguments: [MenuBarDisplayMode.full, .compact])
    @MainActor
    func statusTitleTightensSpaces(mode: MenuBarDisplayMode) throws {
        let segments: [(ProviderQuota.Provider, String)] = [(.claude, "55%"), (.codex, "83%")]
        let title = StatusBarController.statusTitle(segments: segments, displayMode: mode, coloredIcons: false)
        let text = title.string as NSString
        var spaces = 0
        for index in 0..<text.length {
            let kern = title.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat
            if text.character(at: index) == 0x20 {
                spaces += 1
                #expect(kern == StatusBarController.statusSpaceKern)
            } else {
                #expect(kern == nil, "Only spaces are narrowed; found kern at \(index)")
            }
        }
        #expect(spaces == (mode == .full ? 4 : 1))
        let font = StatusBarController.statusFont
        let space = NSAttributedString(string: " ", attributes: [.font: font]).size().width
        let iconWidth = 2 * StatusBarController.statusIconSize
        let digitsWidth = mode == .full ? NSAttributedString(string: "55%·83%", attributes: [.font: font]).size().width : 0
        let narrowed = iconWidth + digitsWidth + CGFloat(spaces) * (space + StatusBarController.statusSpaceKern)
        #expect(abs(title.size().width - narrowed) < 1, "width \(title.size().width) vs \(narrowed)")
    }

    @Test("Status icons are drawn centered on the numerals without moving the numerals", arguments: [1, 2])
    @MainActor
    func statusIconsCenterOnNumerals(scale: Int) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for provider in [ProviderQuota.Provider.claude, .codex] {
                let title = StatusBarController.statusTitle(segments: [(provider, "88%")], displayMode: .full, coloredIcons: false)
                let attachment = try #require(title.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
                let cell = try #require(attachment.attachmentCell as? StatusIconAttachmentCell)
                let drop = cell.drawingDrop
                let centered = try inkCenters(title, appearance: appearance, scale: scale)
                cell.drawingDrop = 0
                let onBaseline = try inkCenters(title, appearance: appearance, scale: scale)
                cell.drawingDrop = drop

                #expect(centered.digitRows == onBaseline.digitRows, "\(provider) numerals moved: \(onBaseline.digitRows) -> \(centered.digitRows)")
                // Default cell layout leaves the glyph well above the numerals.
                #expect(onBaseline.icon - onBaseline.digits < -2, "\(provider) baseline layout: \(onBaseline)")
                #expect(abs(centered.icon - centered.digits) <= 0.5, "\(provider) center drift at \(scale)x \(appearance.rawValue): \(centered)")
            }
        }
    }

    /// Vertical ink centers in points (downward positive) of the icon slot and
    /// of the numerals to its right.
    @MainActor
    private func inkCenters(
        _ title: NSAttributedString,
        appearance: NSAppearance.Name,
        scale: Int
    ) throws -> (icon: CGFloat, digits: CGFloat, digitRows: ClosedRange<Int>) {
        let bitmap = try renderAttachment(title, appearance: appearance, scale: scale)
        let iconEnd = (8 + Int(StatusBarController.statusIconSize) + 1) * scale
        var icon = (Int.max, Int.min), digits = (Int.max, Int.min)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                guard appearance == .darkAqua ? luminance > 0.5 : luminance < 0.5 else { continue }
                if x < iconEnd { icon = (min(icon.0, y), max(icon.1, y)) } else { digits = (min(digits.0, y), max(digits.1, y)) }
            }
        }
        #expect(icon.0 <= icon.1 && digits.0 <= digits.1, "icon and numerals must both draw")
        let center = { (range: (Int, Int)) in CGFloat(range.0 + range.1) / 2 / CGFloat(scale) }
        return (center(icon), center(digits), digits.0...max(digits.0, digits.1))
    }

    @Test("Monochrome is the default and every provider renders a template glyph", arguments: [13.0, 64.0])
    @MainActor
    func monochromeGlyphsAreTemplates(size: Double) throws {
        for provider in ProviderQuota.Provider.displayOrder {
            let menu = BrandIcon.menuBarImage(for: provider, size: size)
            #expect(menu.isTemplate, "\(provider.displayName) must follow the menu-bar appearance")
            #expect(menu.size == NSSize(width: size, height: size))
            let coverage = try alphaCoverage(of: menu)
            #expect(coverage > 0.03, "\(provider.displayName) monochrome glyph looks empty (\(coverage))")
            // White tile details must become cutouts, not a solid square.
            #expect(coverage < 0.97, "\(provider.displayName) monochrome glyph is a solid block (\(coverage))")
        }
    }

    @Test("Brand-color mode keeps vendor palettes and tints only single-color brand marks")
    @MainActor
    func brandColorGlyphsKeepTheirPalette() throws {
        for provider in ProviderQuota.Provider.displayOrder {
            let menu = BrandIcon.menuBarImage(for: provider, size: StatusBarController.statusIconSize, colored: true)
            let raw = BrandIcon.image(for: provider, size: StatusBarController.statusIconSize)
            if BrandIcon.menuBarBrandTint(for: provider) != nil {
                #expect(!menu.isTemplate, "\(provider.displayName) brand tint must not be recolored by AppKit")
            } else {
                #expect(menu.isTemplate == raw.isTemplate, "\(provider.displayName) changed template state")
            }
        }
    }

    @Test("Actual status attachments stay visible through light/dark/light transitions", arguments: [1, 2])
    @MainActor
    func statusAttachmentsFollowAppearance(scale: Int) throws {
        for colored in [false, true] {
            for provider in ProviderQuota.Provider.displayOrder {
                guard BrandIcon.menuBarImage(for: provider, size: StatusBarController.statusIconSize, colored: colored).isTemplate else { continue }
                // Reuse the same attachment, as the status title does when only the
                // appearance changes and the quota fingerprint stays unchanged.
                let attachment = StatusBarController.statusIcon(provider, size: StatusBarController.statusIconSize, colored: colored)
                var contrasts: [CGFloat] = []
                for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
                    let bitmap = try renderAttachment(attachment, appearance: appearance, scale: scale)
                    // Integrate contrast so antialiased thin strokes count at 1x;
                    // a hard per-pixel cutoff incorrectly discards visible strokes.
                    var contrast: CGFloat = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                            contrast += appearance == .darkAqua ? luminance : 1 - luminance
                        }
                    }
                    contrasts.append(contrast)
                    #expect(
                        contrast > CGFloat(5 * scale * scale),
                        "\(provider.displayName) attachment is invisible in \(appearance.rawValue) at \(scale)x"
                    )
                }
                #expect(contrasts[1] > contrasts[0] * 0.75, "Dark appearance must retain the visible mark")
                #expect(abs(contrasts[2] - contrasts[0]) < 0.01, "Returning to light must restore the same mark")
            }
        }
    }

    @Test("Monochrome attachments draw no color; brand-color attachments keep it", arguments: [1, 2])
    @MainActor
    func attachmentColorFollowsSetting(scale: Int) throws {
        for provider in [ProviderQuota.Provider.claude, .codex, .deepseek, .kiro] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let mono = try coloredPixels(
                    renderAttachment(StatusBarController.statusIcon(provider, size: StatusBarController.statusIconSize), appearance: appearance, scale: scale)
                )
                let colored = try coloredPixels(
                    renderAttachment(
                        StatusBarController.statusIcon(provider, size: StatusBarController.statusIconSize, colored: true),
                        appearance: appearance,
                        scale: scale
                    )
                )
                #expect(mono == 0, "\(provider.displayName) monochrome glyph drew \(mono) colored pixels")
                #expect(colored > 5 * scale * scale, "\(provider.displayName) lost its brand color")
            }
        }
    }

    @Test("Export the native status title for visual review when requested")
    @MainActor
    func statusTitlePreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["USAGEDOCK_STATUS_PREVIEW_DIR"] else { return }
        let segments: [(ProviderQuota.Provider, String)] = ProviderQuota.Provider.displayOrder.map { ($0, "88%") }
        for colored in [false, true] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let title = StatusBarController.statusTitle(segments: segments, displayMode: .full, coloredIcons: colored)
                let attachment = NSMutableAttributedString(attributedString: title)
                attachment.addAttribute(.foregroundColor, value: appearance == .darkAqua ? NSColor.white : .black,
                                        range: NSRange(location: 0, length: attachment.length))
                let bitmap = try renderAttachment(
                    attachment, appearance: appearance, scale: 2, width: Int(ceil(title.size().width)) + 16
                )
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = "status-\(colored ? "color" : "mono")-\(appearance == .darkAqua ? "dark" : "light").png"
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
    }

    private func coloredPixels(_ bitmap: NSBitmapImageRep) throws -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let components = [color.redComponent, color.greenComponent, color.blueComponent]
                if components.max()! - components.min()! > 0.2 { count += 1 }
            }
        }
        return count
    }

    private func alphaCoverage(of image: NSImage) throws -> Double {
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        var opaque = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 { opaque += 1 }
            }
        }
        return Double(opaque) / Double(max(1, bitmap.pixelsWide * bitmap.pixelsHigh))
    }

    @MainActor
    private func renderAttachment(
        _ attachment: NSAttributedString,
        appearance: NSAppearance.Name,
        scale: Int,
        width: Int = 100
    ) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width * scale,
            pixelsHigh: 32 * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: width, height: 32)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let resolvedAppearance = try #require(NSAppearance(named: appearance))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        resolvedAppearance.performAsCurrentDrawingAppearance {
            (appearance == .darkAqua ? NSColor.black : .white).setFill()
            NSRect(x: 0, y: 0, width: width, height: 32).fill()
            // No percentage text: text contrast must not mask an invisible icon.
            attachment.draw(at: NSPoint(x: 8, y: 8))
        }
        return bitmap
    }

    private func minPaddingRatio(of image: NSImage) -> CGFloat? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.08 else {
                    continue
                }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let pad = min(minX, minY, width - 1 - maxX, height - 1 - maxY)
        return CGFloat(pad) / CGFloat(max(width, height))
    }
}
