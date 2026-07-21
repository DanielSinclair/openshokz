import AppKit
import Foundation
import SwiftData

/// Launch-argument helpers so UI tests can run without a real Shokz disk or network.
enum UITestingSupport {
    static let uiTestingArgument = "-ui-testing"
    static let connectedArgument = "-ui-testing-connected"
    static let disconnectedArgument = "-ui-testing-disconnected"
    static let autoDisconnectArgument = "-ui-testing-auto-disconnect"
    static let autoReconnectArgument = "-ui-testing-auto-reconnect"
    static let skipPreviewArgument = "-ui-testing-skip-preview"
    static let seedLibraryArgument = "-ui-testing-seed-library"
    static let seedCacheArgument = "-ui-testing-seed-cache"
    static let slowListingArgument = "-ui-testing-slow-listing"
    static let needsGrantArgument = "-ui-testing-needs-grant"

    /// Cleared by `simulateDisconnectForUITest()` so refresh stops re-asserting connected.
    private static var connectionSimulationOverride: Bool?

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestingArgument)
    }

    static var simulateConnected: Bool {
        if let connectionSimulationOverride { return connectionSimulationOverride }
        return ProcessInfo.processInfo.arguments.contains(connectedArgument)
            && !ProcessInfo.processInfo.arguments.contains(disconnectedArgument)
    }

    /// Forces disconnected UI even if a real Shokz disk is mounted.
    static var forceDisconnected: Bool {
        ProcessInfo.processInfo.arguments.contains(disconnectedArgument)
    }

    /// True after a UI-test mid-session disconnect override.
    static var isSimulatingDisconnected: Bool {
        connectionSimulationOverride == false
    }

    /// Starts connected, then the volume monitor flips to disconnected shortly after launch.
    static var autoDisconnectAfterLaunch: Bool {
        isEnabled
            && ProcessInfo.processInfo.arguments.contains(autoDisconnectArgument)
            && ProcessInfo.processInfo.arguments.contains(connectedArgument)
    }

    static var skipNetworkPreview: Bool {
        ProcessInfo.processInfo.arguments.contains(skipPreviewArgument)
    }

    /// After the simulated disconnect, reconnect shortly after — exercises the
    /// instant cache repaint on reconnect.
    static var autoReconnectAfterDisconnect: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains(autoReconnectArgument)
    }

    static var seedMockLibrary: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains(seedLibraryArgument)
    }

    /// Seed TrackState cache rows for the mock volume so cache painting is testable.
    static var seedCachedLibrary: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains(seedCacheArgument)
    }

    /// Delays the mock listing so tests can prove rows paint from cache first.
    static var slowListing: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains(slowListingArgument)
    }

    /// Forces the sandbox grant UI so it is testable without a real volume.
    static var forceNeedsGrant: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains(needsGrantArgument)
    }

    /// Long enough that any UI element gated on the listing would visibly miss
    /// the test's cache-paint deadline, short enough to keep suites fast.
    static let slowListingDelay: Duration = .seconds(6)

    /// Volume UUID reported by the simulated device — cache rows must match it.
    static let mockVolumeUUID = "UITEST-VOLUME"

    /// Inserts cache rows matching `mockLibraryFileNames` (idempotent).
    @MainActor
    static func seedCacheStatesIfNeeded(into context: ModelContext) {
        guard seedCachedLibrary else { return }
        let existing = (try? context.fetch(FetchDescriptor<TrackState>())) ?? []
        let known = Set(existing.compactMap(\.relativePath))
        for (index, name) in mockLibraryFileNames.enumerated() where !known.contains(name) {
            context.insert(
                TrackState(
                    identityKey: "\(name)|0|0",
                    cachedDuration: 187,
                    // Cache rows carry art so cache-painted rows show thumbnails.
                    cachedArtworkJPEG: mockArtworkJPEG(seed: index),
                    relativePath: name,
                    volumeID: mockVolumeUUID,
                    lastSeenAt: .now
                )
            )
        }
        try? context.save()
    }

    /// Fake on-device library files for UI tests (`-ui-testing-seed-library`).
    static let mockLibraryFileNames: [String] = [
        "Devin AI Guide [Vyyrvna-hUY].m4a",
        "Training Composer 2 [uTgqYeVxy2c].mp3"
    ]

    /// Writes mock audio files (plus sidecar cover art, so rows render real
    /// thumbnails during visual tests) into `mockVolumeURL` once per launch.
    static func seedMockVolumeIfNeeded() {
        guard seedMockLibrary else { return }
        let volume = mockVolumeURL
        for (index, name) in mockLibraryFileNames.enumerated() {
            let url = volume.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data("mock-audio".utf8).write(to: url)
            }
            let sidecar = url.deletingPathExtension().appendingPathExtension("jpg")
            if !FileManager.default.fileExists(atPath: sidecar.path),
               let jpeg = mockArtworkJPEG(seed: index) {
                try? jpeg.write(to: sidecar)
            }
        }
    }

    /// Tiny solid-color JPEG built with CoreGraphics (safe off the main thread).
    static func mockArtworkJPEG(seed: Int) -> Data? {
        let palette: [CGColor] = [
            CGColor(red: 0.86, green: 0.24, blue: 0.24, alpha: 1),
            CGColor(red: 0.22, green: 0.47, blue: 0.87, alpha: 1),
            CGColor(red: 0.24, green: 0.71, blue: 0.44, alpha: 1)
        ]
        let color = palette[seed % palette.count]
        let width = 88
        let height = 56
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// Empty temp volume used when `-ui-testing-connected` is set.
    static let mockVolumeURL: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokzUITestVolume", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func simulateDisconnectForUITest() {
        connectionSimulationOverride = false
    }

    static func resetSimulationOverrides() {
        connectionSimulationOverride = nil
    }
}
