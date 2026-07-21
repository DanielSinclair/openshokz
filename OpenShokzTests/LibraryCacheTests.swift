import AppKit
import Foundation
import SwiftData
import Testing
@testable import OpenShokz

@Suite("Library cache policy")
struct LibraryCachePolicyTests {
    @Test("paints when device UUIDs match or either side is unknown")
    func paintDecision() {
        #expect(LibraryCachePolicy.shouldPaint(cachedVolumeID: "A", currentVolumeID: "A"))
        #expect(LibraryCachePolicy.shouldPaint(cachedVolumeID: nil, currentVolumeID: "A"))
        #expect(LibraryCachePolicy.shouldPaint(cachedVolumeID: "A", currentVolumeID: nil))
        #expect(LibraryCachePolicy.shouldPaint(cachedVolumeID: nil, currentVolumeID: nil))
        #expect(!LibraryCachePolicy.shouldPaint(cachedVolumeID: "A", currentVolumeID: "B"))
    }

    @Test("eviction spares rows owned by a different device")
    func evictionDecision() {
        #expect(LibraryCachePolicy.shouldEvictAfterReconcile(cachedVolumeID: "A", currentVolumeID: "A"))
        #expect(LibraryCachePolicy.shouldEvictAfterReconcile(cachedVolumeID: nil, currentVolumeID: "A"))
        #expect(
            !LibraryCachePolicy.shouldEvictAfterReconcile(cachedVolumeID: "B", currentVolumeID: "A"),
            "Second Shokz device's cache must survive reconciling the first"
        )
        #expect(
            !LibraryCachePolicy.shouldEvictAfterReconcile(cachedVolumeID: "B", currentVolumeID: nil),
            "Unknown current device (UUID still resolving) must never evict another device's rows"
        )
        #expect(
            LibraryCachePolicy.shouldEvictAfterReconcile(cachedVolumeID: nil, currentVolumeID: nil),
            "Unowned rows always reconcile"
        )
    }

    @Test("legacy identityKey recovers a relative path")
    func legacyRelativePathRecovery() {
        #expect(
            TrackState(identityKey: "folder/song.m4a|123|456").cacheRelativePath
                == "folder/song.m4a"
        )
        #expect(
            TrackState(identityKey: "name|with|pipes.m4a|9|9").cacheRelativePath
                == "name|with|pipes.m4a"
        )
        #expect(TrackState(identityKey: "not-a-key").cacheRelativePath == nil)
        #expect(
            TrackState(identityKey: "x|y|z", relativePath: "explicit.m4a").cacheRelativePath
                == "explicit.m4a"
        )
    }
}

@Suite("Volume paths")
struct VolumePathsTests {
    @Test("computes relative paths across the /private/var symlink pair")
    func privateVarSymlinkPair() {
        let root = URL(fileURLWithPath: "/var/folders/x/vol")
        let resolved = URL(fileURLWithPath: "/private/var/folders/x/vol/folder/song.m4a")
        #expect(VolumePaths.relativePath(of: resolved, under: root) == "folder/song.m4a")

        let privateRoot = URL(fileURLWithPath: "/private/var/folders/x/vol")
        let plain = URL(fileURLWithPath: "/var/folders/x/vol/song.m4a")
        #expect(VolumePaths.relativePath(of: plain, under: privateRoot) == "song.m4a")
    }

    @Test("plain volume paths are unchanged; foreign paths fall back to file name")
    func plainAndForeignPaths() {
        let root = URL(fileURLWithPath: "/Volumes/SWIM PRO")
        let nested = URL(fileURLWithPath: "/Volumes/SWIM PRO/Mixes/track.mp3")
        #expect(VolumePaths.relativePath(of: nested, under: root) == "Mixes/track.mp3")
        let foreign = URL(fileURLWithPath: "/Users/someone/track.mp3")
        #expect(VolumePaths.relativePath(of: foreign, under: root) == "track.mp3")
    }
}

@Suite("Sorted batch merge")
struct SortedBatchMergeTests {
    private func track(_ title: String) -> DeviceTrack {
        DeviceTrack(
            id: title,
            url: URL(fileURLWithPath: "/vol/\(title).m4a"),
            relativePath: "\(title).m4a",
            fileName: "\(title).m4a",
            title: title,
            artist: nil,
            duration: nil,
            fileSize: 0,
            modifiedAt: .distantPast,
            artwork: nil
        )
    }

    @Test("inserts new rows in title order without touching existing ones")
    func insertsInOrder() {
        let existing = [track("Alpha"), track("Charlie"), track("Echo")]
        let merged = LibraryScanner.mergeSortedByTitle(
            existing,
            inserting: [track("Delta"), track("Bravo")]
        )
        #expect(merged.map(\.title) == ["Alpha", "Bravo", "Charlie", "Delta", "Echo"])
    }

    @Test("duplicates by relative path are dropped; empty batches are no-ops")
    func dedupeAndEmpty() {
        let existing = [track("Alpha"), track("Bravo")]
        let merged = LibraryScanner.mergeSortedByTitle(
            existing,
            inserting: [track("Alpha")]
        )
        #expect(merged.map(\.title) == ["Alpha", "Bravo"])
        #expect(
            LibraryScanner.mergeSortedByTitle(existing, inserting: []).map(\.title)
                == ["Alpha", "Bravo"]
        )
        #expect(
            LibraryScanner.mergeSortedByTitle([], inserting: [track("Zulu"), track("Alpha")])
                .map(\.title) == ["Alpha", "Zulu"]
        )
    }
}

@Suite("Volume change token")
struct VolumeChangeTokenTests {
    @Test("failed captures never trigger a rescan")
    func failedCaptureIsQuiet() {
        let token = VolumeChangeToken(rootModified: .now, freeBytes: 1)
        #expect(!VolumeChangeToken.changed(previous: nil, current: token))
        #expect(!VolumeChangeToken.changed(previous: token, current: nil))
        #expect(!VolumeChangeToken.changed(previous: nil, current: nil))
    }

    @Test("identical observations are unchanged; different ones change")
    func changeDetection() {
        let date = Date(timeIntervalSince1970: 1_000)
        let a = VolumeChangeToken(rootModified: date, freeBytes: 500)
        let b = VolumeChangeToken(rootModified: date, freeBytes: 500)
        let c = VolumeChangeToken(rootModified: date, freeBytes: 400)
        #expect(!VolumeChangeToken.changed(previous: a, current: b))
        #expect(VolumeChangeToken.changed(previous: a, current: c))
    }

    @Test("capture observes a real root directory change")
    func captureObservesChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-Token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let before = await VolumeChangeToken.capture(root: root)
        #expect(before != nil)
        #expect(await VolumeChangeToken.capture(root: nil) == nil)

        try? await Task.sleep(for: .milliseconds(1_050))
        try Data("x".utf8).write(to: root.appendingPathComponent("new.m4a"))
        let after = await VolumeChangeToken.capture(root: root)
        #expect(VolumeChangeToken.changed(previous: before, current: after))
    }
}

@Suite("Library cache painting")
@MainActor
struct LibraryCachePaintTests {
    private func inMemoryViewModel() throws -> (LibraryViewModel, ModelContext) {
        let container = try ModelContainer(
            for: TrackState.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let vm = LibraryViewModel(
            backfill: TrackMetadataBackfill(runner: NoNetworkRunner(), writeToDisk: false)
        )
        vm.configure(modelContext: context)
        return (vm, context)
    }

    private func connectedMonitor(uuid: String? = nil) -> ShokzVolumeMonitor {
        let monitor = ShokzVolumeMonitor()
        monitor.handleDiskEvent(
            .changed(
                DiskVolumeDescription(
                    volumeName: "SWIM PRO",
                    volumePath: URL(fileURLWithPath: "/Volumes/SWIM PRO"),
                    volumeUUID: uuid,
                    isRemovableMedia: true,
                    isEjectable: true
                )
            )
        )
        return monitor
    }

    @Test("cached rows paint instantly with zero filesystem I/O")
    func cachePaintsWithoutListing() throws {
        let (vm, context) = try inMemoryViewModel()
        context.insert(
            TrackState(
                identityKey: "B Song [dQw4w9WgXcQ].m4a|10|10",
                cachedDuration: 212,
                relativePath: "B Song [dQw4w9WgXcQ].m4a",
                volumeID: "ABC-123",
                lastSeenAt: .now
            )
        )
        context.insert(
            TrackState(
                identityKey: "A Song [uTgqYeVxy2c].m4a|10|10",
                relativePath: "A Song [uTgqYeVxy2c].m4a",
                volumeID: "ABC-123",
                lastSeenAt: .now
            )
        )
        try context.save()

        // Mount point does not exist on the test machine — painting must not care.
        let monitor = connectedMonitor(uuid: "ABC-123")
        vm.paintFromCache(volume: monitor)

        #expect(vm.tracks.count == 2)
        #expect(vm.tracks[0].title.hasPrefix("A Song"), "Cache rows paint sorted by title")
        #expect(vm.displayDuration(for: vm.tracks[1]) == 212)
    }

    @Test("rows from a different device do not paint")
    func otherDeviceRowsFiltered() throws {
        let (vm, context) = try inMemoryViewModel()
        context.insert(
            TrackState(
                identityKey: "Other [dQw4w9WgXcQ].m4a|10|10",
                relativePath: "Other [dQw4w9WgXcQ].m4a",
                volumeID: "OTHER-DEVICE"
            )
        )
        try context.save()

        let monitor = connectedMonitor(uuid: "ABC-123")
        vm.paintFromCache(volume: monitor)
        #expect(vm.tracks.isEmpty)
    }

    @Test("legacy rows without explicit relativePath still paint")
    func legacyRowsPaint() throws {
        let (vm, context) = try inMemoryViewModel()
        context.insert(TrackState(identityKey: "Legacy [dQw4w9WgXcQ].m4a|123|456"))
        try context.save()

        let monitor = connectedMonitor(uuid: nil)
        vm.paintFromCache(volume: monitor)
        #expect(vm.tracks.count == 1)
        #expect(vm.tracks[0].relativePath == "Legacy [dQw4w9WgXcQ].m4a")
    }
}

@Suite("Library cache reconcile")
@MainActor
struct LibraryCacheReconcileTests {
    private func makeVolume(files: [String]) throws -> (URL, ShokzVolumeMonitor) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-Reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in files {
            try Data("audio".utf8).write(to: root.appendingPathComponent(name))
        }
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
            backfill: TrackMetadataBackfill(runner: NoNetworkRunner(), writeToDisk: false)
        )
        vm.configure(modelContext: context)
        return (vm, context)
    }

    @Test("completed listing stamps live rows and evicts stale ones")
    func reconcileStampsAndEvicts() async throws {
        let (root, monitor) = try makeVolume(files: ["real.m4a"])
        defer { try? FileManager.default.removeItem(at: root) }

        let (vm, context) = try inMemoryViewModel()
        context.insert(
            TrackState(identityKey: "ghost.m4a|1|1", relativePath: "ghost.m4a")
        )
        try context.save()

        await vm.refresh(volume: monitor)

        let states = try context.fetch(FetchDescriptor<TrackState>())
        #expect(states.count == 1, "Stale ghost row must be evicted by the listing")
        #expect(states.first?.cacheRelativePath == "real.m4a")
        #expect(states.first?.relativePath == "real.m4a", "Live rows get stamped for cache painting")
        #expect(states.first?.lastSeenAt != nil)
    }

    @Test("empty volume evicts all cached rows for this device")
    func emptyListingEvicts() async throws {
        let (root, monitor) = try makeVolume(files: [])
        defer { try? FileManager.default.removeItem(at: root) }

        let (vm, context) = try inMemoryViewModel()
        context.insert(
            TrackState(identityKey: "gone.m4a|1|1", relativePath: "gone.m4a")
        )
        context.insert(
            TrackState(
                identityKey: "other.m4a|1|1",
                relativePath: "other.m4a",
                volumeID: "SOME-OTHER-DEVICE"
            )
        )
        try context.save()

        await vm.refresh(volume: monitor)

        let states = try context.fetch(FetchDescriptor<TrackState>())
        #expect(states.count == 1, "Only the other device's row survives")
        #expect(states.first?.volumeID == "SOME-OTHER-DEVICE")
    }

    @Test("delete removes the cached row so it can never ghost-paint")
    func deleteRemovesCacheRow() async throws {
        let (root, monitor) = try makeVolume(files: ["clip.m4a"])
        defer { try? FileManager.default.removeItem(at: root) }

        let (vm, context) = try inMemoryViewModel()
        await vm.refresh(volume: monitor)
        #expect(vm.tracks.count == 1)
        #expect(try context.fetch(FetchDescriptor<TrackState>()).isEmpty == false)

        vm.selection = [vm.tracks[0].id]
        vm.deleteSelected(volume: monitor)
        #expect(vm.tracks.isEmpty)
        #expect(
            try context.fetch(FetchDescriptor<TrackState>()).isEmpty,
            "Cache row must go with the file"
        )

        // Fresh paint after the delete finds nothing.
        vm.paintFromCache(volume: monitor)
        #expect(vm.tracks.isEmpty)
    }

    @Test("recordTransfer inserts row and cache without any listing")
    func recordTransferInsertsDirectly() throws {
        let (root, monitor) = try makeVolume(files: [])
        defer { try? FileManager.default.removeItem(at: root) }

        let (vm, context) = try inMemoryViewModel()
        let info = RemoteVideoInfo(
            url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!,
            videoID: "dQw4w9WgXcQ",
            title: "New Song",
            duration: 187,
            thumbnailURL: nil,
            isPlaylist: false,
            playlistCount: nil
        )

        vm.recordTransfer(
            volume: monitor,
            relativePaths: ["New Song [dQw4w9WgXcQ].m4a"],
            info: info,
            mediaID: "dQw4w9WgXcQ"
        )

        #expect(vm.tracks.count == 1)
        #expect(vm.tracks[0].relativePath == "New Song [dQw4w9WgXcQ].m4a")
        #expect(vm.displayDuration(for: vm.tracks[0]) == 187)
        #expect(vm.existingVideoIDs.contains("dQw4w9WgXcQ"))

        let states = try context.fetch(FetchDescriptor<TrackState>())
        #expect(states.count == 1)
        #expect(states.first?.relativePath == "New Song [dQw4w9WgXcQ].m4a")
        #expect(states.first?.mediaID == "dQw4w9WgXcQ")
        #expect(states.first?.lastSeenAt != nil)

        // Re-recording the same transfer must not duplicate anything.
        vm.recordTransfer(
            volume: monitor,
            relativePaths: ["New Song [dQw4w9WgXcQ].m4a"],
            info: info,
            mediaID: "dQw4w9WgXcQ"
        )
        #expect(vm.tracks.count == 1)
        #expect(try context.fetch(FetchDescriptor<TrackState>()).count == 1)
    }
}

/// Metadata runner that never hits the network.
private actor NoNetworkRunner: AudioDownloadClient {
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
