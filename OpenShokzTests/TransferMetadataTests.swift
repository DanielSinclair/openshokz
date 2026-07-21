import AppKit
import Foundation
import SwiftData
import Testing
@testable import OpenShokz

@Suite("Enrichment policy")
struct EnrichmentPolicyTests {
    @Test("skips the USB read only when duration and artwork are both cached")
    func skipRequiresFullCache() {
        #expect(!EnrichmentPolicy.needsFileRead(cachedDuration: 200, hasCachedArtwork: true))
        #expect(EnrichmentPolicy.needsFileRead(cachedDuration: nil, hasCachedArtwork: true))
        #expect(EnrichmentPolicy.needsFileRead(cachedDuration: 0, hasCachedArtwork: true))
        #expect(EnrichmentPolicy.needsFileRead(cachedDuration: 200, hasCachedArtwork: false))
        #expect(EnrichmentPolicy.needsFileRead(cachedDuration: nil, hasCachedArtwork: false))
    }
}

@Suite("Transfer metadata capture")
@MainActor
struct TransferMetadataCaptureTests {
    private func makeRoots() throws -> (device: URL, staging: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-XferMeta-\(UUID().uuidString)", isDirectory: true)
        let device = base.appendingPathComponent("device", isDirectory: true)
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return (device, staging)
    }

    private func inMemoryViewModel() throws -> (LibraryViewModel, ModelContext) {
        let container = try ModelContainer(
            for: TrackState.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let vm = LibraryViewModel(
            backfill: TrackMetadataBackfill(runner: FailingRunner(), writeToDisk: false)
        )
        vm.configure(modelContext: context)
        return (vm, context)
    }

    private func tinyJPEG() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let jpeg = image.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [:])
        }
        return try #require(jpeg)
    }

    @Test("recordTransfer persists duration, title, and staged artwork — no backfill needed")
    func persistsDownloadMetadata() async throws {
        let (device, staging) = try makeRoots()
        defer { try? FileManager.default.removeItem(at: device.deletingLastPathComponent()) }

        let fileName = "New Song [dQw4w9WgXcQ].m4a"
        let localFile = staging.appendingPathComponent(fileName)
        try Data("audio".utf8).write(to: localFile)
        try tinyJPEG().write(
            to: localFile.deletingPathExtension().appendingPathExtension("jpg")
        )

        let monitor = ShokzVolumeMonitor()
        monitor.applyScanResult((url: device, name: "OpenSwim"))

        let (vm, context) = try inMemoryViewModel()
        vm.recordTransfer(
            volume: monitor,
            relativePaths: [fileName],
            localURLs: [localFile],
            info: RemoteVideoInfo(
                url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!,
                videoID: "dQw4w9WgXcQ",
                title: "New Song",
                duration: 187,
                thumbnailURL: nil,
                isPlaylist: false,
                playlistCount: nil
            ),
            mediaID: "dQw4w9WgXcQ"
        )

        #expect(vm.tracks.count == 1)
        #expect(vm.displayDuration(for: vm.tracks[0]) == 187)
        #expect(vm.displayArtwork(for: vm.tracks[0]) != nil, "Staged sidecar art shows immediately")

        let state = try #require(try context.fetch(FetchDescriptor<TrackState>()).first)
        #expect(state.cachedDuration == 187)
        #expect(state.cachedArtworkJPEG?.isEmpty == false)
        #expect(state.titleOverride?.contains("New Song") == true)
        #expect(
            state.hasAttemptedRemoteMetadata,
            "Fully described transfers must never trigger a network backfill"
        )
        #expect(
            !EnrichmentPolicy.needsFileRead(
                cachedDuration: state.cachedDuration,
                hasCachedArtwork: state.cachedArtworkJPEG != nil
            ),
            "Fully described transfers must never trigger an AVFoundation read over USB"
        )
    }

    @Test("playlist transfers do not smear one duration across all files")
    func playlistDoesNotSmearMetadata() async throws {
        let (device, staging) = try makeRoots()
        defer { try? FileManager.default.removeItem(at: device.deletingLastPathComponent()) }

        let names = ["One [aaaaaaaaaaa].m4a", "Two [bbbbbbbbbbb].m4a"]
        let locals = try names.map { name -> URL in
            let url = staging.appendingPathComponent(name)
            try Data("audio".utf8).write(to: url)
            return url
        }

        let monitor = ShokzVolumeMonitor()
        monitor.applyScanResult((url: device, name: "OpenSwim"))

        let (vm, context) = try inMemoryViewModel()
        vm.recordTransfer(
            volume: monitor,
            relativePaths: names,
            localURLs: locals,
            info: RemoteVideoInfo(
                url: URL(string: "https://youtube.com/playlist?list=x")!,
                videoID: nil,
                title: "Some Playlist",
                duration: 9_999,
                thumbnailURL: nil,
                isPlaylist: true,
                playlistCount: 2
            ),
            mediaID: nil
        )

        #expect(vm.tracks.count == 2)
        let states = try context.fetch(FetchDescriptor<TrackState>())
        #expect(states.count == 2)
        #expect(states.allSatisfy { $0.cachedDuration == nil })
        #expect(states.allSatisfy { $0.titleOverride == nil })
    }
}

/// Runner that fails loudly if any test path reaches the network.
private actor FailingRunner: AudioDownloadClient {
    func fetchMetadata(for url: URL) async throws -> RemoteVideoInfo {
        Issue.record("Unexpected network metadata fetch")
        throw MediaPipelineError.noAudioStream
    }

    func downloadAudio(
        url: URL,
        to directory: URL,
        allowPlaylist: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        Issue.record("Unexpected network download")
        throw MediaPipelineError.noAudioStream
    }

    func cancel() async {}
}
