import Foundation
import Testing
@testable import OpenShokz

@Suite("Volume access policy")
struct VolumeAccessPolicyTests {
    @Test("bookmarks key by volume UUID, falling back to name")
    func bookmarkKeys() {
        #expect(
            VolumeAccessPolicy.bookmarkKey(volumeUUID: "ABC-123", volumeName: "SWIM PRO")
                == "volume-bookmark-ABC-123"
        )
        #expect(
            VolumeAccessPolicy.bookmarkKey(volumeUUID: nil, volumeName: "SWIM PRO")
                == "volume-bookmark-name-SWIM PRO"
        )
        #expect(
            VolumeAccessPolicy.bookmarkKey(volumeUUID: "", volumeName: "OpenSwim")
                == "volume-bookmark-name-OpenSwim"
        )
    }

    @Test("only real external volumes need a grant")
    func grantScope() {
        #expect(VolumeAccessPolicy.requiresGrant(isSandboxed: true, mountPath: "/Volumes/SWIM PRO"))
        #expect(
            !VolumeAccessPolicy.requiresGrant(isSandboxed: true, mountPath: "/private/var/folders/x/tmp/vol"),
            "Container/temp paths (mock volumes, unit tests) are always readable"
        )
        #expect(!VolumeAccessPolicy.requiresGrant(isSandboxed: false, mountPath: "/Volumes/SWIM PRO"))
    }

    @Test("stored bookmarks only count when they resolve to the mounted path")
    func bookmarkMatching() {
        #expect(
            VolumeAccessPolicy.bookmarkMatches(
                resolvedPath: "/Volumes/SWIM PRO",
                mountPath: "/Volumes/SWIM PRO"
            )
        )
        #expect(
            !VolumeAccessPolicy.bookmarkMatches(
                resolvedPath: "/Volumes/SWIM PRO 1",
                mountPath: "/Volumes/SWIM PRO"
            )
        )
        #expect(!VolumeAccessPolicy.bookmarkMatches(resolvedPath: nil, mountPath: "/Volumes/SWIM PRO"))
    }

    @Test("unit-test host runs sandboxed")
    func hostIsSandboxed() {
        // The whole point of this rewrite: the app (our test host) is sandboxed.
        #expect(VolumeAccessManager.isSandboxed)
    }
}

@Suite("Volume monitor access gating")
@MainActor
struct VolumeMonitorAccessTests {
    @Test("connecting a /Volumes device without a grant flags needsAccessGrant")
    func realVolumeNeedsGrant() {
        let monitor = ShokzVolumeMonitor()
        monitor.handleDiskEvent(
            .changed(
                DiskVolumeDescription(
                    volumeName: "SWIM PRO",
                    volumePath: URL(fileURLWithPath: "/Volumes/SWIM PRO"),
                    volumeUUID: "NO-BOOKMARK-FOR-THIS",
                    isRemovableMedia: true,
                    isEjectable: true
                )
            )
        )
        #expect(monitor.isConnected)
        #expect(monitor.needsAccessGrant, "Sandboxed host has no bookmark for this volume")
    }

    @Test("container-path volumes (tests, mocks) never need a grant")
    func containerVolumeNeedsNoGrant() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-Access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let monitor = ShokzVolumeMonitor()
        monitor.applyScanResult((url: root, name: "OpenSwim"))
        #expect(monitor.isConnected)
        #expect(!monitor.needsAccessGrant)
    }

    @Test("disconnect clears the grant flag")
    func disconnectClearsFlag() {
        let monitor = ShokzVolumeMonitor()
        monitor.handleDiskEvent(
            .changed(
                DiskVolumeDescription(
                    volumeName: "SWIM PRO",
                    volumePath: URL(fileURLWithPath: "/Volumes/SWIM PRO"),
                    volumeUUID: "XYZ",
                    isRemovableMedia: true,
                    isEjectable: true
                )
            )
        )
        monitor.applyDisconnected()
        #expect(!monitor.needsAccessGrant)
    }
}
