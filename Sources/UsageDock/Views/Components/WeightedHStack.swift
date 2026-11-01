import SwiftUI

/// Lays children out side by side at fixed width ratios, every child taking
/// the tallest child's height. A pure layout: widths come from the proposal
/// and the weights alone, never from measured state, so it cannot feed back
/// into itself. Rows that share one weight list share their column edges.
struct WeightedHStack: Layout {
    let weights: [CGFloat]
    /// Width reported when the parent asks for an ideal size (`ViewThatFits`).
    var idealWidth: CGFloat = 800
    /// Gap between neighbouring children, outside the weighted widths.
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? idealWidth
        let widths = columnWidths(total: width, count: subviews.count)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(total: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    /// No alignment guides pass through: parents align the stack by its
    /// bounds. The default merges children's guides by placing every child,
    /// which re-ran the whole row's layout for each alignment query.
    func explicitAlignment(
        of guide: HorizontalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    private func columnWidths(total: CGFloat, count: Int) -> [CGFloat] {
        let used = Array(weights.prefix(count)) + Array(repeating: 1, count: max(0, count - weights.count))
        let sum = used.reduce(0, +)
        let available = max(0, total - spacing * CGFloat(max(0, count - 1)))
        return used.map { available * $0 / sum }
    }
}

/// Children side by side at equal widths and the tallest child's height when
/// the proposal is at least `minimumWidth` wide, stacked at natural heights
/// otherwise. One set of subviews either way: a `ViewThatFits` over a row
/// and a stack built and measured both, doubling the children's cost on
/// every build. Pure, like `WeightedHStack`: nothing measured is stored.
struct AdaptiveRowLayout: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumWidth
        guard !subviews.isEmpty else { return CGSize(width: width, height: 0) }
        if Self.isRow(width: width, minimum: minimumWidth) {
            let column = columnWidth(total: width, count: subviews.count)
            let height = subviews
                .map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
                .max() ?? 0
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(subviews.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if Self.isRow(width: bounds.width, minimum: minimumWidth) {
            let column = columnWidth(total: bounds.width, count: subviews.count)
            var x = bounds.minX
            for subview in subviews {
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    proposal: ProposedViewSize(width: column, height: bounds.height)
                )
                x += column + spacing
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
            y += height + spacing
        }
    }

    func explicitAlignment(
        of guide: HorizontalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    static func isRow(width: CGFloat, minimum: CGFloat) -> Bool {
        width >= minimum
    }

    private func columnWidth(total: CGFloat, count: Int) -> CGFloat {
        max(0, (total - spacing * CGFloat(max(0, count - 1))) / CGFloat(max(1, count)))
    }
}
