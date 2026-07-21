import AppKit
import Foundation

/// Reveal a file in Finder without blocking the UI on slow FSKit FAT mounts.
/// Sandbox-safe: NSWorkspace only, always off the MainActor.
enum FinderReveal {
    /// Fire-and-forget: returns immediately; Finder opens in the background.
    static func reveal(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
