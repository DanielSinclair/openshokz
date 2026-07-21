import AppKit
import Foundation
import SwiftData
import Testing
@testable import OpenShokz

@Suite("Library view model")
@MainActor
struct LibraryViewModelTests {
    private func makeVolumeWithTrack(named fileName: String) throws -> (URL, ShokzVolumeMonitor) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-LibraryVM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent(fileName)
        try Data("audio".utf8).write(to: audio)

        let monitor = ShokzVolumeMonitor()
        monitor.applyScanResult((url: root, name: "OpenSwim"))
        return (root, monitor)
    }

    private func inMemoryViewModel() throws -> (LibraryViewModel, ModelContext) {
        let container = try ModelContainer(
            for: TrackState.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let vm = LibraryViewModel(
            backfill: TrackMetadataBackfill(runner: NoOpMetadataRunner(), writeToDisk: false)
        )
        vm.configure(modelContext: context)
        return (vm, context)
    }

    @Test("quickTracks uses relativePath as stable track id")
    func stableTrackID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-TrackID-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("folder/song.m4a")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: nested)

        let tracks = LibraryScanner().quickTracks(volumeRoot: root, files: [nested])
        #expect(tracks.count == 1)
        #expect(tracks[0].id == "folder/song.m4a")
        #expect(tracks[0].relativePath == tracks[0].id)
    }

    @Test("deleteSelected optimistically clears rows before disk delete finishes")
    func optimisticDelete() async throws {
        let (root, monitor) = try makeVolumeWithTrack(named: "clip.m4a")
        defer { try? FileManager.default.removeItem(at: root) }

        let (vm, _) = try inMemoryViewModel()
        await vm.refresh(volume: monitor)
        #expect(vm.tracks.count == 1)

        let audioPath = vm.tracks[0].url.path
        vm.selection = [vm.tracks[0].id]
        vm.deleteSelected(volume: monitor)
        #expect(vm.tracks.isEmpty)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: audioPath) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!FileManager.default.fileExists(atPath: audioPath))

        await vm.refresh(volume: monitor, force: true)
        #expect(vm.tracks.isEmpty, "Deleted track should not reappear after refresh")
    }

    @Test("displayArtwork returns SwiftData cached JPEG")
    func cachedArtworkDisplay() throws {
        let (vm, context) = try inMemoryViewModel()
        let track = DeviceTrack(
            id: "song.m4a",
            url: URL(fileURLWithPath: "/tmp/song.m4a"),
            relativePath: "song.m4a",
            fileName: "Song [Vyyrvna-hUY].m4a",
            title: "Song",
            artist: nil,
            duration: nil,
            fileSize: 1,
            modifiedAt: .now,
            artwork: nil
        )
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let jpeg = image.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [:])
        }
        let jpegData = try #require(jpeg)
        context.insert(
            TrackState(
                identityKey: track.identityKey,
                mediaID: "Vyyrvna-hUY",
                cachedArtworkJPEG: jpegData
            )
        )
        try context.save()

        #expect(vm.displayArtwork(for: track) != nil)
    }

    @Test("existingVideoIDs merges filename ids and TrackState")
    func existingVideoIDsFromState() async throws {
        let (root, monitor) = try makeVolumeWithTrack(named: "Other [dQw4w9WgXcQ].m4a")
        defer { try? FileManager.default.removeItem(at: root) }

        let (vm, context) = try inMemoryViewModel()
        await vm.refresh(volume: monitor)
        #expect(vm.existingVideoIDs.contains("dQw4w9WgXcQ"))

        if let track = vm.tracks.first {
            context.insert(
                TrackState(identityKey: track.identityKey, mediaID: "Vyyrvna-hUY")
            )
            try context.save()
        }
        #expect(vm.existingVideoIDs.contains("dQw4w9WgXcQ"))
        #expect(vm.existingVideoIDs.contains("Vyyrvna-hUY"))
    }
}

/// Metadata runner that never hits the network — keeps library VM tests fast.
private actor NoOpMetadataRunner: AudioDownloadClient {
    func fetchMetadata(for url: URL) async throws -> RemoteVideoInfo {
        RemoteVideoInfo(
            url: url,
            videoID: nil,
            title: "x",
            duration: nil,
            thumbnailURL: nil,
            isPlaylist: false,
            playlistCount: nil
        )
    }

    func downloadAudio(
        url: URL,
        to directory: URL,
        allowPlaylist: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        []
    }

    func cancel() async {}
}
