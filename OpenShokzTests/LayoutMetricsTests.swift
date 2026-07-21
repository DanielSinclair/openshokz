import CoreGraphics
import Testing
@testable import OpenShokz

@Suite("Layout metrics")
struct LayoutMetricsTests {
    @Test("empty state uses upward optical nudge")
    func emptyStateNudge() {
        #expect(LayoutMetrics.emptyStateNudge == -12)
        #expect(LayoutMetrics.emptyStateNudge < 0)
    }

    @Test("chrome insets are symmetric and positive")
    func symmetricInsets() {
        #expect(LayoutMetrics.edge == 8)
        #expect(LayoutMetrics.chromeInset == 14)
        #expect(LayoutMetrics.edge > 0)
        #expect(LayoutMetrics.chromeInset > LayoutMetrics.edge)
    }
}
