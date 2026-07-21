import AppKit
import SwiftUI

/// Makes the host NSWindow transparent so liquid glass can show through,
/// and enforces the widget-sized launch frame (without blocking later resize).
struct WindowConfigurator: NSViewRepresentable {
    private static let autosaveName = "OpenShokz.MainWindow.v2"
    private static var didApplyInitialSize = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.configure(nsView.window)
        }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(
            width: OpenShokzApp.defaultWidth,
            height: OpenShokzApp.defaultHeight
        )
        window.isMovableByWindowBackground = true

        // New autosave name so an older oversized frame is not restored.
        if window.frameAutosaveName != autosaveName {
            window.setFrameAutosaveName(autosaveName)
        }

        // Apply the widget launch size once per process.
        if !didApplyInitialSize {
            didApplyInitialSize = true
            let size = NSSize(
                width: OpenShokzApp.defaultWidth,
                height: OpenShokzApp.defaultHeight
            )
            window.setContentSize(size)
        }
    }
}
