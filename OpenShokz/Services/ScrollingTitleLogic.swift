import CoreGraphics
import Foundation

/// Pure marquee math for `ScrollingTitle` — unit-testable without SwiftUI.
enum ScrollingTitleLogic {
    static let defaultLoopGap: CGFloat = 40
    static let defaultPointsPerSecond: CGFloat = 36

    static func overflow(textWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        max(0, textWidth - containerWidth)
    }

    /// Offset for marquee text. Returns `0` at hover start (elapsed == 0).
    static func scrollOffset(
        isHovered: Bool,
        textWidth: CGFloat,
        containerWidth: CGFloat,
        loopGap: CGFloat = defaultLoopGap,
        pointsPerSecond: CGFloat = defaultPointsPerSecond,
        anchor: Date?,
        now: Date
    ) -> CGFloat {
        let overflow = overflow(textWidth: textWidth, containerWidth: containerWidth)
        let shouldLoop = isHovered && overflow > 0
        let cycleWidth = textWidth + loopGap
        guard shouldLoop, cycleWidth > 0, let anchor else { return 0 }
        let elapsed = now.timeIntervalSince(anchor)
        let period = Double(cycleWidth / pointsPerSecond)
        guard period > 0 else { return 0 }
        let phase = elapsed.truncatingRemainder(dividingBy: period) / period
        return -CGFloat(phase) * cycleWidth
    }
}
