import DiskArbitration
import Foundation
import Testing
@testable import OpenShokz

@Suite("Disk description parsing")
struct DiskDescriptionParsingTests {
    @Test("parses name, path, flags, and CFUUID volume id")
    func parsesFullDescription() {
        let uuid = CFUUIDCreateFromString(nil, "D8A2117B-33B1-4B49-B42B-88F9D564DE21" as CFString)!
        let description = ShokzDiskPolicy.parse([
            kDADiskDescriptionVolumeNameKey as String: "SWIM PRO",
            kDADiskDescriptionVolumePathKey as String: URL(fileURLWithPath: "/Volumes/SWIM PRO"),
            kDADiskDescriptionMediaRemovableKey as String: true,
            kDADiskDescriptionMediaEjectableKey as String: true,
            kDADiskDescriptionVolumeUUIDKey as String: uuid
        ])

        #expect(description.volumeName == "SWIM PRO")
        #expect(description.volumePath?.path == "/Volumes/SWIM PRO")
        #expect(description.isRemovableMedia)
        #expect(description.isEjectable)
        #expect(description.volumeUUID == "D8A2117B-33B1-4B49-B42B-88F9D564DE21")
    }

    @Test("unmounted raw media parses with nil path and no crash")
    func parsesRawMedia() {
        let description = ShokzDiskPolicy.parse([
            kDADiskDescriptionMediaRemovableKey as String: true
        ])
        #expect(description.volumeName == nil)
        #expect(description.volumePath == nil)
        #expect(description.volumeUUID == nil)
    }
}

@Suite("Shokz disk policy")
struct ShokzDiskPolicyTests {
    private func description(
        name: String? = nil,
        path: String? = nil,
        uuid: String? = nil
    ) -> DiskVolumeDescription {
        DiskVolumeDescription(
            volumeName: name,
            volumePath: path.map { URL(fileURLWithPath: $0) },
            volumeUUID: uuid,
            isRemovableMedia: true,
            isEjectable: true
        )
    }

    @Test("recognizes Shokz volumes by name or mount path")
    func recognizesShokzVolumes() {
        #expect(ShokzDiskPolicy.isShokzVolume(description(name: "SWIM PRO")))
        #expect(ShokzDiskPolicy.isShokzVolume(description(name: "OpenSwim")))
        #expect(ShokzDiskPolicy.isShokzVolume(description(path: "/Volumes/SWIM PRO")))
        #expect(!ShokzDiskPolicy.isShokzVolume(description(name: "Untitled", path: "/Volumes/Untitled")))
        #expect(!ShokzDiskPolicy.isShokzVolume(description()))
    }

    @Test("connectionUpdate requires a mount point")
    func connectionUpdateRequiresMount() {
        // Disk appeared but volume not mounted yet — must not flip UI to connected.
        #expect(ShokzDiskPolicy.connectionUpdate(for: description(name: "SWIM PRO")) == nil)

        let update = ShokzDiskPolicy.connectionUpdate(
            for: description(name: "SWIM PRO", path: "/Volumes/SWIM PRO", uuid: "ABC-123")
        )
        #expect(update?.url.path == "/Volumes/SWIM PRO")
        #expect(update?.name == "SWIM PRO")
        #expect(update?.uuid == "ABC-123")
    }

    @Test("connectionUpdate falls back to path component when name is empty")
    func connectionUpdateNameFallback() {
        let update = ShokzDiskPolicy.connectionUpdate(
            for: description(name: "  ", path: "/Volumes/SWIM PRO")
        )
        #expect(update?.name == "SWIM PRO")
    }

    @Test("connectionUpdate rejects non-Shokz volumes")
    func connectionUpdateRejectsOthers() {
        #expect(
            ShokzDiskPolicy.connectionUpdate(
                for: description(name: "BackupDrive", path: "/Volumes/BackupDrive")
            ) == nil
        )
    }

    @Test("disconnect matches by UUID, path, or Shokz identity")
    func disconnectMatching() {
        let root = URL(fileURLWithPath: "/Volumes/SWIM PRO")

        #expect(
            ShokzDiskPolicy.indicatesOurDisconnect(
                description(uuid: "ABC-123"),
                currentRoot: root,
                currentUUID: "ABC-123"
            ),
            "Cable yank often reports no path/name — UUID must still match"
        )
        #expect(
            ShokzDiskPolicy.indicatesOurDisconnect(
                description(path: "/Volumes/SWIM PRO"),
                currentRoot: root,
                currentUUID: nil
            )
        )
        #expect(
            ShokzDiskPolicy.indicatesOurDisconnect(
                description(name: "SWIM PRO"),
                currentRoot: nil,
                currentUUID: nil
            )
        )
        #expect(
            !ShokzDiskPolicy.indicatesOurDisconnect(
                description(name: "OtherDisk", path: "/Volumes/OtherDisk", uuid: "ZZZ"),
                currentRoot: root,
                currentUUID: "ABC-123"
            ),
            "Removing an unrelated USB drive must not disconnect the Shokz UI"
        )
    }
}

@Suite("Volume monitor disk events")
@MainActor
struct VolumeMonitorDiskEventTests {
    private func shokzDescription(
        path: String? = "/Volumes/SWIM PRO",
        uuid: String? = "ABC-123"
    ) -> DiskVolumeDescription {
        DiskVolumeDescription(
            volumeName: "SWIM PRO",
            volumePath: path.map { URL(fileURLWithPath: $0) },
            volumeUUID: uuid,
            isRemovableMedia: true,
            isEjectable: true
        )
    }

    @Test("mount event connects immediately with UUID")
    func mountEventConnects() {
        let monitor = ShokzVolumeMonitor()
        monitor.handleDiskEvent(.changed(shokzDescription()))
        #expect(monitor.isConnected)
        #expect(monitor.rootURL?.path == "/Volumes/SWIM PRO")
        #expect(monitor.volumeName == "SWIM PRO")
        #expect(monitor.volumeUUID == "ABC-123")
    }

    @Test("appeared without mount point does not connect")
    func rawMediaDoesNotConnect() {
        let monitor = ShokzVolumeMonitor()
        monitor.handleDiskEvent(.appeared(shokzDescription(path: nil)))
        #expect(!monitor.isConnected)
    }

    @Test("disappeared event disconnects instantly")
    func disappearDisconnects() {
        let monitor = ShokzVolumeMonitor()
        monitor.handleDiskEvent(.changed(shokzDescription()))
        #expect(monitor.isConnected)

        monitor.handleDiskEvent(.disappeared(shokzDescription(path: nil)))
        #expect(!monitor.isConnected)
        #expect(monitor.rootURL == nil)
        #expect(monitor.volumeUUID == nil)
    }

    @Test("unmount (path dropped) disconnects instantly")
    func unmountDisconnects() {
        let monitor = ShokzVolumeMonitor()
        monitor.handleDiskEvent(.changed(shokzDescription()))
        #expect(monitor.isConnected)

        monitor.handleDiskEvent(.changed(shokzDescription(path: nil)))
        #expect(!monitor.isConnected)
    }

    @Test("unrelated disk removal keeps Shokz connected")
    func unrelatedRemovalIgnored() {
        let monitor = ShokzVolumeMonitor()
        monitor.handleDiskEvent(.changed(shokzDescription()))

        let other = DiskVolumeDescription(
            volumeName: "BackupDrive",
            volumePath: nil,
            volumeUUID: "OTHER-999",
            isRemovableMedia: true,
            isEjectable: true
        )
        monitor.handleDiskEvent(.disappeared(other))
        #expect(monitor.isConnected)
    }
}

@Suite("Presence watch")
@MainActor
struct PresenceWatchTests {
    @Test("a vanished volume root flips the monitor to disconnected within ~2s")
    func vanishedRootDisconnects() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-Presence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let monitor = ShokzVolumeMonitor()
        monitor.applyScanResult((url: root, name: "OpenSwim"))
        #expect(monitor.isConnected)

        try FileManager.default.removeItem(at: root)

        // The watch flips disconnected, then rescan may legitimately reconnect
        // to a REAL device on the test machine — the invariant is that the
        // vanished root never survives as the current one.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, monitor.isConnected, monitor.rootURL?.path == root.path {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(
            monitor.rootURL?.path != root.path,
            "Presence watch should clear the vanished root"
        )
    }
}

@Suite("Volume content watch")
@MainActor
struct VolumeContentWatchTests {
    @Test("direct file changes on the volume bump the content generation")
    func directChangeBumpsGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-Watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let monitor = ShokzVolumeMonitor()
        monitor.applyScanResult((url: root, name: "OpenSwim"))
        let initial = monitor.contentGeneration

        let file = root.appendingPathComponent("dropped.m4a")
        try Data("x".utf8).write(to: file)

        var deadline = Date().addingTimeInterval(3)
        while Date() < deadline, monitor.contentGeneration == initial {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(monitor.contentGeneration > initial, "Create should bump the generation")

        let afterCreate = monitor.contentGeneration
        try FileManager.default.removeItem(at: file)
        deadline = Date().addingTimeInterval(3)
        while Date() < deadline, monitor.contentGeneration == afterCreate {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(monitor.contentGeneration > afterCreate, "Delete should bump the generation")
    }
}
