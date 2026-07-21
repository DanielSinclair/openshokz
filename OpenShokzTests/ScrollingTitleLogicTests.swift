import CoreGraphics
import Foundation
import Testing
@testable import OpenShokz

@Suite("Scrolling title marquee")
struct ScrollingTitleLogicTests {
    @Test("starts at offset zero when hover begins")
    func startsAtZeroOnHover() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000)
        let offset = ScrollingTitleLogic.scrollOffset(
            isHovered: true,
            textWidth: 200,
            containerWidth: 100,
            anchor: anchor,
            now: anchor
        )
        #expect(offset == 0)
    }

    @Test("does not scroll when text fits")
    func noScrollWhenFits() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000)
        let later = anchor.addingTimeInterval(5)
        let offset = ScrollingTitleLogic.scrollOffset(
            isHovered: true,
            textWidth: 80,
            containerWidth: 120,
            anchor: anchor,
            now: later
        )
        #expect(offset == 0)
    }

    @Test("does not scroll while not hovered")
    func noScrollWhenNotHovered() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000)
        let later = anchor.addingTimeInterval(5)
        let offset = ScrollingTitleLogic.scrollOffset(
            isHovered: false,
            textWidth: 200,
            containerWidth: 100,
            anchor: anchor,
            now: later
        )
        #expect(offset == 0)
    }

    @Test("scrolls left after hover anchor elapses")
    func scrollsAfterElapsedTime() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000)
        let later = anchor.addingTimeInterval(2)
        let offset = ScrollingTitleLogic.scrollOffset(
            isHovered: true,
            textWidth: 200,
            containerWidth: 100,
            loopGap: 40,
            pointsPerSecond: 36,
            anchor: anchor,
            now: later
        )
        #expect(offset < 0)
    }

    @Test("overflow is positive only when text is wider than container")
    func overflowCalculation() {
        #expect(ScrollingTitleLogic.overflow(textWidth: 200, containerWidth: 100) == 100)
        #expect(ScrollingTitleLogic.overflow(textWidth: 80, containerWidth: 120) == 0)
    }
}
