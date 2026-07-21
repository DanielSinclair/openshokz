import AppKit
import Sparkle
import SwiftData
import SwiftUI

/// Widget-style app: closing the window means quitting, like a utility.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct OpenShokzApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Widget-sized floor — also the preferred launch size.
    static let defaultWidth: CGFloat = 280
    static let defaultHeight: CGFloat = 320

    /// Sparkle auto-updates against SUFeedURL (openshokz.app/appcast.xml).
    /// Not started under UI testing — no update prompts over test runs.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: !UITestingSupport.isEnabled,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private static let modelContainer: ModelContainer = {
        let schema = Schema([TrackState.self])
        // UI-test runs use a throwaway in-memory store so mock rows can never
        // leak into (or ghost-paint from) the real library cache.
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: UITestingSupport.isEnabled
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Lightweight migration can fail when adding fields; reset local play/metadata state.
            let url = configuration.url
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Failed to create ModelContainer after reset: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(
                    minWidth: Self.defaultWidth,
                    minHeight: Self.defaultHeight
                )
        }
        .modelContainer(Self.modelContainer)
        .defaultSize(width: Self.defaultWidth, height: Self.defaultHeight)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
        }
    }
}
