import CoreGraphics

/// Shared layout constants for window chrome and empty states — unit-testable.
enum LayoutMetrics {
    /// Outer window chrome (status, FAB) and list row side insets — keep L/R equal.
    static let edge: CGFloat = 8
    /// Inner padding inside the expanded add capsule — equal left/right.
    static let chromeInset: CGFloat = 14
    /// Optical center nudge for full-window empty states (bottom FAB pulls weight down).
    static let emptyStateNudge: CGFloat = -12
}
