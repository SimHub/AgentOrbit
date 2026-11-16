import CoreGraphics
import Foundation

public enum HorizontalSnapAnchor: String, Codable, Sendable {
    case leading
    case center
    case trailing
}

public enum VerticalSnapAnchor: String, Codable, Sendable {
    case bottom
    case center
    case top
}

public struct GridSnapResult: Sendable, Equatable {
    public let origin: CGPoint
    public let snappedToXAnchor: Bool
    public let snappedToYAnchor: Bool
    public let horizontalAnchor: HorizontalSnapAnchor
    public let verticalAnchor: VerticalSnapAnchor
    public let safeFrame: CGRect

    public var isSnappedToAnchor: Bool {
        snappedToXAnchor || snappedToYAnchor
    }
}

public enum GridSnapCalculator {
    public static func snap(
        frame: CGRect,
        visibleFrame: CGRect,
        margin: CGFloat = 12,
        gridStep: CGFloat = 24,
        magnetDistance: CGFloat = 22
    ) -> GridSnapResult {
        let safe = safeBounds(visibleFrame: visibleFrame, margin: margin)

        let minX = safe.minX
        let maxX = max(safe.minX, safe.maxX - frame.width)
        let midX = ((minX + maxX) / 2).rounded()

        let minY = safe.minY
        let maxY = max(safe.minY, safe.maxY - frame.height)
        let midY = ((minY + maxY) / 2).rounded()

        let xResult = snapAxis(
            value: frame.origin.x,
            minVal: minX,
            midVal: midX,
            maxVal: maxX,
            gridOrigin: safe.minX,
            gridStep: gridStep,
            magnetDistance: magnetDistance
        )

        let yResult = snapAxis(
            value: frame.origin.y,
            minVal: minY,
            midVal: midY,
            maxVal: maxY,
            gridOrigin: safe.minY,
            gridStep: gridStep,
            magnetDistance: magnetDistance
        )

        let snappedOrigin = CGPoint(x: xResult.snapped.rounded(), y: yResult.snapped.rounded())
        let snappedFrame = CGRect(origin: snappedOrigin, size: frame.size)

        let horizontalAnchor: HorizontalSnapAnchor
        if abs(snappedOrigin.x - maxX) <= 1 {
            horizontalAnchor = .trailing
        } else if abs(snappedOrigin.x - midX) <= 1 {
            horizontalAnchor = .center
        } else if abs(snappedOrigin.x - minX) <= 1 {
            horizontalAnchor = .leading
        } else {
            horizontalAnchor = snappedFrame.midX >= visibleFrame.midX ? .trailing : .leading
        }

        let verticalAnchor: VerticalSnapAnchor
        if abs(snappedOrigin.y - maxY) <= 1 {
            verticalAnchor = .top
        } else if abs(snappedOrigin.y - midY) <= 1 {
            verticalAnchor = .center
        } else if abs(snappedOrigin.y - minY) <= 1 {
            verticalAnchor = .bottom
        } else {
            verticalAnchor = snappedFrame.midY >= visibleFrame.midY ? .top : .bottom
        }

        return GridSnapResult(
            origin: snappedOrigin,
            snappedToXAnchor: xResult.isAnchor,
            snappedToYAnchor: yResult.isAnchor,
            horizontalAnchor: horizontalAnchor,
            verticalAnchor: verticalAnchor,
            safeFrame: safe
        )
    }

    public static func anchoredOrigin(
        size: CGSize,
        visibleFrame: CGRect,
        horizontalAnchor: HorizontalSnapAnchor,
        verticalAnchor: VerticalSnapAnchor,
        anchoredMinX: CGFloat?,
        anchoredMaxX: CGFloat?,
        anchoredMinY: CGFloat?,
        anchoredMaxY: CGFloat?,
        margin: CGFloat = 12
    ) -> CGPoint {
        let safe = safeBounds(visibleFrame: visibleFrame, margin: margin)
        let maxAllowedX = max(safe.minX, safe.maxX - size.width)
        let maxAllowedY = max(safe.minY, safe.maxY - size.height)

        let desiredX: CGFloat
        switch horizontalAnchor {
        case .trailing:
            desiredX = (anchoredMaxX ?? safe.maxX) - size.width
        case .center:
            desiredX = ((safe.minX + maxAllowedX) / 2)
        case .leading:
            desiredX = anchoredMinX ?? safe.minX
        }

        let desiredY: CGFloat
        switch verticalAnchor {
        case .top:
            desiredY = (anchoredMaxY ?? safe.maxY) - size.height
        case .center:
            desiredY = ((safe.minY + maxAllowedY) / 2)
        case .bottom:
            desiredY = anchoredMinY ?? safe.minY
        }

        let clampedX = min(max(desiredX, safe.minX), maxAllowedX)
        let clampedY = min(max(desiredY, safe.minY), maxAllowedY)
        return CGPoint(x: clampedX.rounded(), y: clampedY.rounded())
    }

    public static func anchorFrames(
        for size: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 12
    ) -> [CGRect] {
        let safe = safeBounds(visibleFrame: visibleFrame, margin: margin)
        let minX = safe.minX
        let maxX = max(safe.minX, safe.maxX - size.width)
        let midX = ((minX + maxX) / 2).rounded()

        let minY = safe.minY
        let maxY = max(safe.minY, safe.maxY - size.height)
        let midY = ((minY + maxY) / 2).rounded()

        let xs = [minX, midX, maxX]
        let ys = [minY, midY, maxY]

        var rects: [CGRect] = []
        for x in xs {
            for y in ys {
                rects.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            }
        }
        return rects
    }

    public static func safeBounds(visibleFrame: CGRect, margin: CGFloat = 12) -> CGRect {
        let insetX = min(margin, max(0, visibleFrame.width / 4))
        let insetY = min(margin, max(0, visibleFrame.height / 4))
        return visibleFrame.insetBy(dx: insetX, dy: insetY)
    }

    private static func snapAxis(
        value: CGFloat,
        minVal: CGFloat,
        midVal: CGFloat,
        maxVal: CGFloat,
        gridOrigin: CGFloat,
        gridStep: CGFloat,
        magnetDistance: CGFloat
    ) -> (snapped: CGFloat, isAnchor: Bool) {
        let anchors = [minVal, midVal, maxVal]
        if let closestAnchor = anchors.min(by: { abs($0 - value) < abs($1 - value) }),
           abs(closestAnchor - value) <= magnetDistance {
            return (closestAnchor, true)
        }

        guard gridStep > 0 else {
            return (min(max(value, minVal), maxVal), false)
        }
        let stepIndex = ((value - gridOrigin) / gridStep).rounded()
        let gridAligned = gridOrigin + stepIndex * gridStep
        let clamped = min(max(gridAligned, minVal), maxVal)
        return (clamped, false)
    }
}
