import SwiftUI

/// A layout that arranges its children in a horizontal flow,
/// wrapping to new lines as needed
struct WrappingHStack: Layout {
    var alignment: Alignment = .center
    var spacing: CGFloat = 8

    struct CacheData {
        var result: FlowResult?
        var lastWidth: CGFloat = -1
    }

    func makeCache(subviews: Subviews) -> CacheData {
        CacheData()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let result = getResult(for: width, subviews: subviews, cache: &cache)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        let result = getResult(for: bounds.width, subviews: subviews, cache: &cache)

        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { continue }
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.positions[index].x,
                    y: bounds.minY + result.positions[index].y
                ),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    private func getResult(for width: CGFloat, subviews: Subviews, cache: inout CacheData) -> FlowResult {
        if let cached = cache.result, cache.lastWidth == width {
            return cached
        }
        let result = FlowResult(in: width, subviews: subviews, spacing: spacing)
        cache.result = result
        cache.lastWidth = width
        return result
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            guard maxWidth > 0 && maxWidth.isFinite else {
                self.size = .zero
                return
            }

            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0
            var maxX: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                guard size.width.isFinite && size.height.isFinite &&
                      size.width >= 0 && size.height >= 0 else {
                    sizes.append(.zero)
                    positions.append(.zero)
                    continue
                }

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                sizes.append(size)
                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
                maxX = max(maxX, x - spacing)
            }

            let finalWidth = max(0, maxX)
            let finalHeight = max(0, y + lineHeight)

            self.size = CGSize(
                width: finalWidth.isFinite ? finalWidth : 0,
                height: finalHeight.isFinite ? finalHeight : 0
            )
        }
    }
}
