import ImageIO
import SwiftUI

/// The selected head-only pixel pet with live Claude and Codex meters.
/// The lower remaining provider drives the expression; at hero/icon sizes both
/// provider rows remain visible so colour never changes the robot's identity.
public struct TokenRemainHeadLogo: View {
    private struct MeterRow: Identifiable {
        let provider: ProviderQuota.Provider
        let remainingPercent: Double

        var id: ProviderQuota.Provider { provider }
    }

    private let claudeRemaining: Double?
    private let codexRemaining: Double?
    private let size: CGFloat

    public init(
        claudeRemaining: Double?,
        codexRemaining: Double?,
        size: CGFloat
    ) {
        self.claudeRemaining = claudeRemaining
        self.codexRemaining = codexRemaining
        self.size = size
    }

    private var moodRemaining: Double? {
        [claudeRemaining, codexRemaining].compactMap { $0 }.min()
    }

    public var mood: RobotMoodState {
        .resolve(remainingPercent: moodRemaining)
    }

    private var availableRows: [MeterRow] {
        [
            claudeRemaining.map { MeterRow(provider: .claude, remainingPercent: $0) },
            codexRemaining.map { MeterRow(provider: .codex, remainingPercent: $0) }
        ].compactMap { $0 }
    }

    private var visibleRows: [MeterRow] {
        guard size >= 24 else { return [] }
        let rows = availableRows
        guard size < 72, rows.count > 1 else { return rows }
        return rows.min(by: { $0.remainingPercent < $1.remainingPercent }).map { [$0] } ?? []
    }

    public var body: some View {
        ZStack {
            headArtwork

            if !visibleRows.isEmpty {
                meterCanvas(rows: visibleRows)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var headArtwork: some View {
        if let cgImage = Self.loadImage(named: mood.rawValue) {
            Image(decorative: cgImage, scale: 1)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Color.clear
        }
    }

    private static func loadImage(named name: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func meterCanvas(rows: [MeterRow]) -> some View {
        Canvas { context, canvasSize in
            let segmentCount = 10
            let meterWidth = canvasSize.width * 0.63
            let gap = max(1, canvasSize.width * 0.008)
            let segmentWidth = (meterWidth - gap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount)
            let segmentHeight = max(2, canvasSize.width * 0.024)
            let x = (canvasSize.width - meterWidth) / 2
            let startY = rows.count == 2 ? canvasSize.height * 0.837 : canvasSize.height * 0.862
            let rowGap = canvasSize.height * 0.049

            for (rowIndex, row) in rows.enumerated() {
                let filled = Int((clamped(row.remainingPercent) / 10).rounded())
                let y = startY + CGFloat(rowIndex) * rowGap
                for segment in 0..<segmentCount {
                    let rect = CGRect(
                        x: x + CGFloat(segment) * (segmentWidth + gap),
                        y: y,
                        width: segmentWidth,
                        height: segmentHeight
                    )
                    let path = Path(roundedRect: rect, cornerRadius: max(0.75, segmentHeight * 0.16))
                    context.fill(path, with: .color(segment < filled ? meterColor(row.provider) : TRTheme.track))
                    context.stroke(path, with: .color(TRTheme.border), lineWidth: max(0.5, canvasSize.width * 0.0015))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private func meterColor(_ provider: ProviderQuota.Provider) -> Color {
        switch provider {
        case .claude: return TRTheme.claudeBrand
        case .codex: return TRTheme.codexBrand
        default: return TRTheme.brandColor(for: provider)
        }
    }

    private var accessibilityLabel: String {
        let values = availableRows.map { row in
            "\(row.provider.shortName) \(Int(clamped(row.remainingPercent).rounded()))%"
        }
        guard !values.isEmpty else {
            return "TokenRemain, \(mood.accessibilityDescription)"
        }
        return "TokenRemain, \(values.joined(separator: ", ")), \(mood.accessibilityDescription)"
    }
}

#Preview("Dual provider head logo") {
    HStack(spacing: 16) {
        TokenRemainHeadLogo(claudeRemaining: 72, codexRemaining: 38, size: 96)
        TokenRemainHeadLogo(claudeRemaining: 18, codexRemaining: 63, size: 96)
    }
    .padding()
    .background(TRTheme.ink)
}
