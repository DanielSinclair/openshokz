import Foundation
import Testing
@testable import OpenShokz

@Suite("Shokz volume identity")
struct ShokzVolumeIdentityTests {
    @Test("matches OpenSwim Pro and SWIM PRO labels")
    func matchesShokzVolumeLabels() {
        #expect(ShokzVolumeIdentity.matches(name: "SWIM PRO"))
        #expect(ShokzVolumeIdentity.matches(name: "SWIMPRO"))
        #expect(ShokzVolumeIdentity.matches(name: "OpenSwim Pro"))
        #expect(ShokzVolumeIdentity.matches(name: "  SWIM PRO  "))
        #expect(ShokzVolumeIdentity.matches(name: "swim pro"))
        #expect(ShokzVolumeIdentity.matches(name: "SwimPro"))
        #expect(ShokzVolumeIdentity.matches(name: "SWIMPRO-1"))
    }

    @Test("matches original OpenSwim and legacy Xtrainerz labels")
    func matchesOpenSwimFamily() {
        #expect(ShokzVolumeIdentity.matches(name: "OpenSwim"))
        #expect(ShokzVolumeIdentity.matches(name: "OpenSwim2"))
        #expect(ShokzVolumeIdentity.matches(name: "OpenSwim (Formerly Xtrainerz)"))
        #expect(ShokzVolumeIdentity.matches(name: "Xtrainerz"))
    }

    @Test("rejects unrelated volumes")
    func rejectsUnrelated() {
        #expect(!ShokzVolumeIdentity.matches(name: "Macintosh HD"))
        #expect(!ShokzVolumeIdentity.matches(name: "Untitled"))
        #expect(!ShokzVolumeIdentity.matches(name: "USB DRIVE"))
        #expect(!ShokzVolumeIdentity.matches(name: ""))
        #expect(!ShokzVolumeIdentity.matches(name: "SWIMMING"))
        #expect(!ShokzVolumeIdentity.matches(name: "SWIMMER"))
        #expect(!ShokzVolumeIdentity.matches(name: "SWIM"))
        #expect(!ShokzVolumeIdentity.matches(name: "OPEN SWIM"))
        #expect(!ShokzVolumeIdentity.matches(name: "Open Swim"))
        #expect(!ShokzVolumeIdentity.matches(name: "open swim"))
    }

    @Test("accepts OPEN SWIM PRO folded variants")
    func acceptsOpenSwimProVariants() {
        #expect(ShokzVolumeIdentity.matches(name: "OPEN SWIM PRO"))
        #expect(ShokzVolumeIdentity.matches(name: "Open Swim Pro"))
    }

    @Test("findVolume picks the first Shokz-like mount")
    func findVolumePicksMatch() {
        let volumes = [
            URL(fileURLWithPath: "/Volumes/Macintosh HD"),
            URL(fileURLWithPath: "/Volumes/OpenSwim"),
            URL(fileURLWithPath: "/Volumes/Other")
        ]
        let names: [String: String] = [
            "/Volumes/Macintosh HD": "Macintosh HD",
            "/Volumes/OpenSwim": "OpenSwim",
            "/Volumes/Other": "Other"
        ]
        let match = ShokzVolumeIdentity.findVolume(among: volumes) { url in
            names[url.path]
        }
        #expect(match?.name == "OpenSwim")
        #expect(match?.url.lastPathComponent == "OpenSwim")
    }

    @Test("findVolume prefers removable Shokz mounts")
    func findVolumePrefersRemovable() {
        let volumes = [
            URL(fileURLWithPath: "/Volumes/OpenSwim"),
            URL(fileURLWithPath: "/Volumes/SWIM PRO")
        ]
        let names: [String: String] = [
            "/Volumes/OpenSwim": "OpenSwim",
            "/Volumes/SWIM PRO": "SWIM PRO"
        ]
        let preferred = Set(["/Volumes/SWIM PRO"])
        let match = ShokzVolumeIdentity.findVolume(
            among: volumes,
            volumeName: { names[$0.path] },
            isPreferredMount: { preferred.contains($0.path) }
        )
        #expect(match?.name == "SWIM PRO")
    }

    @Test("findVolume returns nil when nothing matches")
    func findVolumeNil() {
        let volumes = [URL(fileURLWithPath: "/Volumes/Macintosh HD")]
        let match = ShokzVolumeIdentity.findVolume(among: volumes) { _ in "Macintosh HD" }
        #expect(match == nil)
    }
}

@Suite("Shokz file enumerator")
struct ShokzFileEnumeratorTests {
    @Test("lists supported audio files within depth limit")
    func listsAudioWithinDepth() throws {
        let root = try makeTempVolume()
        defer { try? FileManager.default.removeItem(at: root) }

        try touch(root.appendingPathComponent("song.m4a"))
        try touch(root.appendingPathComponent("nested/deep/track.mp3"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder"),
            withIntermediateDirectories: true
        )
        try touch(root.appendingPathComponent("folder/clip.aac"))
        try touch(root.appendingPathComponent("readme.txt"))
        try touch(root.appendingPathComponent("photo.jpg"))

        let files = try ShokzFileEnumerator.listAudioFiles(at: root)
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.contains("song.m4a"))
        #expect(names.contains("clip.aac"))
        #expect(names.contains("track.mp3"))
        #expect(!names.contains("readme.txt"))
        #expect(!names.contains("photo.jpg"))
    }

    @Test("publishes top-level batch before nested files")
    func publishesTopLevelFirst() throws {
        let root = try makeTempVolume()
        defer { try? FileManager.default.removeItem(at: root) }

        try touch(root.appendingPathComponent("root.m4a"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder"),
            withIntermediateDirectories: true
        )
        try touch(root.appendingPathComponent("folder/nested.mp3"))

        var batches: [[String]] = []
        _ = try ShokzFileEnumerator.listAudioFiles(at: root) { batch in
            batches.append(batch.map(\.lastPathComponent))
        }

        #expect(batches.count >= 2)
        #expect(batches[0] == ["root.m4a"])
        #expect(batches.contains(where: { $0.contains("nested.mp3") }))
    }

    @Test("skips files deeper than Shokz three-folder limit")
    func skipsTooDeep() throws {
        let root = try makeTempVolume()
        defer { try? FileManager.default.removeItem(at: root) }

        // depth 5 path components under root → skipped (limit is 4)
        let deep = root.appendingPathComponent("a/b/c/d/too-deep.m4a")
        try FileManager.default.createDirectory(
            at: deep.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try touch(deep)
        try touch(root.appendingPathComponent("ok.m4a"))

        let files = try ShokzFileEnumerator.listAudioFiles(at: root)
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.contains("ok.m4a"))
        #expect(!names.contains("too-deep.m4a"))
    }

    private func makeTempVolume() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokzTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }
}

@Suite("Library display policy")
struct LibraryDisplayPolicyTests {
    @Test("empty library only when scan finished, no error, negligible used space")
    func emptyOnlyWhenTrulyEmpty() {
        #expect(
            LibraryDisplayPolicy.showsEmptyLibrary(
                trackCount: 0,
                isScanning: false,
                lastError: nil,
                usedBytes: 0,
                isDownloadBusy: false
            )
        )
        #expect(
            !LibraryDisplayPolicy.showsEmptyLibrary(
                trackCount: 0,
                isScanning: true,
                lastError: nil,
                usedBytes: 0,
                isDownloadBusy: false
            )
        )
        #expect(
            !LibraryDisplayPolicy.showsEmptyLibrary(
                trackCount: 0,
                isScanning: false,
                lastError: "timed out",
                usedBytes: 0,
                isDownloadBusy: false
            )
        )
        #expect(
            LibraryDisplayPolicy.showsEmptyLibrary(
                trackCount: 0,
                isScanning: false,
                lastError: nil,
                usedBytes: 1_400_000_000,
                isDownloadBusy: false
            ),
            "Used space alone must not block the empty state — only an explicit list error does"
        )
    }

    @Test("read problem only when listing failed with an explicit error")
    func readProblem() {
        #expect(
            LibraryDisplayPolicy.showsReadProblem(
                trackCount: 0,
                isScanning: false,
                lastError: "timed out",
                usedBytes: 0
            )
        )
        #expect(
            LibraryDisplayPolicy.showsReadProblem(
                trackCount: 0,
                isScanning: true,
                lastError: "timed out",
                usedBytes: 0
            ),
            "Keep read-error UI visible while a retry scan runs"
        )
        #expect(
            !LibraryDisplayPolicy.showsReadProblem(
                trackCount: 0,
                isScanning: false,
                lastError: nil,
                usedBytes: 1_400_000_000
            ),
            "Do not show Can't read library just because the volume has used space"
        )
        #expect(
            !LibraryDisplayPolicy.showsReadProblem(
                trackCount: 3,
                isScanning: false,
                lastError: "timed out",
                usedBytes: 1_400_000_000
            )
        )
    }
}

@Suite("Connection lifecycle")
struct ConnectionLifecycleTests {
    @Test("does not quit before the device has ever connected")
    func noQuitBeforeFirstConnect() {
        #expect(
            !ConnectionLifecycle.shouldScheduleQuit(
                hasSeenConnection: false,
                wasConnected: false,
                isConnectedNow: false
            )
        )
    }

    @Test("schedules quit after a real disconnect")
    func schedulesQuitAfterDisconnect() {
        #expect(
            ConnectionLifecycle.shouldScheduleQuit(
                hasSeenConnection: true,
                wasConnected: true,
                isConnectedNow: false
            )
        )
        #expect(
            ConnectionLifecycle.shouldScheduleQuit(
                hasSeenConnection: true,
                wasConnected: false,
                isConnectedNow: false
            )
        )
    }

    @Test("does not schedule quit while still connected")
    func noQuitWhileConnected() {
        #expect(
            !ConnectionLifecycle.shouldScheduleQuit(
                hasSeenConnection: true,
                wasConnected: false,
                isConnectedNow: true
            )
        )
    }

    @Test("confirm quit only when still disconnected after settle")
    func confirmQuitAfterSettle() {
        #expect(ConnectionLifecycle.shouldConfirmQuit(stillDisconnected: true))
        #expect(!ConnectionLifecycle.shouldConfirmQuit(stillDisconnected: false))
    }

    @Test("USB plug-in flicker: reconnect cancels quit")
    func plugInFlickerCancelsQuit() {
        // Mount event briefly reports disconnected then connected again.
        let shouldSchedule = ConnectionLifecycle.shouldScheduleQuit(
            hasSeenConnection: true,
            wasConnected: true,
            isConnectedNow: false
        )
        #expect(shouldSchedule)
        // After settle delay the volume is back — do not quit.
        #expect(!ConnectionLifecycle.shouldConfirmQuit(stillDisconnected: false))
    }

    @Test("quit debounce absorbs USB settle flicker")
    func quitDebounceAbsorbsFlicker() {
        // Status flips instantly on DiskArbitration events; only quitting is delayed.
        #expect(ConnectionLifecycle.disconnectQuitDelay >= .seconds(1))
    }
}

@Suite("Connection status presentation")
struct ConnectionStatusPresentationTests {
    @Test("disconnected label is Not connected")
    func disconnectedLabel() {
        #expect(
            ConnectionStatusPresentation.label(isConnected: false, volumeName: "SWIM PRO")
                == "Not connected"
        )
        #expect(
            ConnectionStatusPresentation.label(isConnected: false, volumeName: nil)
                == "Not connected"
        )
    }

    @Test("connected label prefers volume name")
    func connectedLabel() {
        #expect(
            ConnectionStatusPresentation.label(isConnected: true, volumeName: "SWIM PRO")
                == "SWIM PRO"
        )
        #expect(
            ConnectionStatusPresentation.label(isConnected: true, volumeName: "OpenSwim")
                == "OpenSwim"
        )
        #expect(
            ConnectionStatusPresentation.label(isConnected: true, volumeName: nil)
                == "Shokz"
        )
        #expect(
            ConnectionStatusPresentation.label(isConnected: true, volumeName: "  ")
                == "Shokz"
        )
    }
}

@Suite("Volume connection lifecycle")
@MainActor
struct VolumeConnectionLifecycleTests {
    @Test("findVolume nil applies as disconnected")
    func findVolumeNilMeansDisconnected() {
        let volumes = [URL(fileURLWithPath: "/Volumes/Macintosh HD")]
        let match = ShokzVolumeIdentity.findVolume(among: volumes) { _ in "Macintosh HD" }
        #expect(match == nil)

        let monitor = ShokzVolumeMonitor()
        monitor.applyScanResult(match)
        #expect(!monitor.isConnected)
        #expect(monitor.rootURL == nil)
        #expect(monitor.volumeName == nil)
        #expect(
            ConnectionStatusPresentation.label(
                isConnected: monitor.isConnected,
                volumeName: monitor.volumeName
            ) == "Not connected"
        )
    }

    @Test("losing Shokz volume from list flips connected to false")
    func losingShokzVolumeFlipsDisconnected() {
        let monitor = ShokzVolumeMonitor()
        let connected = (
            url: URL(fileURLWithPath: "/Volumes/SWIM PRO"),
            name: "SWIM PRO"
        )
        monitor.applyScanResult(connected)
        #expect(monitor.isConnected)
        #expect(monitor.volumeName == "SWIM PRO")
        #expect(
            ConnectionStatusPresentation.label(
                isConnected: monitor.isConnected,
                volumeName: monitor.volumeName
            ) == "SWIM PRO"
        )

        let remaining = [URL(fileURLWithPath: "/Volumes/Macintosh HD")]
        let match = ShokzVolumeIdentity.findVolume(among: remaining) { _ in "Macintosh HD" }
        #expect(match == nil)
        monitor.applyScanResult(match)
        #expect(!monitor.isConnected)
        #expect(
            ConnectionStatusPresentation.label(
                isConnected: monitor.isConnected,
                volumeName: monitor.volumeName
            ) == "Not connected"
        )
    }

    @Test("unmount URL matching recognizes our Shokz root")
    func unmountURLMatching() {
        let root = URL(fileURLWithPath: "/Volumes/SWIM PRO")
        #expect(
            ShokzVolumeMonitor.looksLikeOurVolume(
                URL(fileURLWithPath: "/Volumes/SWIM PRO"),
                currentRoot: root
            )
        )
        #expect(
            ShokzVolumeMonitor.looksLikeOurVolume(
                URL(fileURLWithPath: "/Volumes/SWIM PRO"),
                currentRoot: nil
            )
        )
        #expect(
            !ShokzVolumeMonitor.looksLikeOurVolume(
                URL(fileURLWithPath: "/Volumes/Macintosh HD"),
                currentRoot: root
            )
        )
    }

    @Test("applyDisconnected clears connection state promptly")
    func applyDisconnectedClearsState() {
        let monitor = ShokzVolumeMonitor()
        monitor.applyScanResult((
            url: URL(fileURLWithPath: "/Volumes/SWIM PRO"),
            name: "SWIM PRO"
        ))
        monitor.applyDisconnected()
        #expect(!monitor.isConnected)
        #expect(monitor.rootURL == nil)
        #expect(monitor.volumeName == nil)
        #expect(monitor.freeBytes == 0)
        #expect(monitor.totalBytes == 0)
    }
}

@Suite("Audio file support")
struct AudioFileSupportTests {
    @Test("recognizes OpenSwim Pro formats")
    func supportedFormats() {
        #expect(AudioFileSupport.isSupported(URL(fileURLWithPath: "/t.m4a")))
        #expect(AudioFileSupport.isSupported(URL(fileURLWithPath: "/t.mp3")))
        #expect(AudioFileSupport.isSupported(URL(fileURLWithPath: "/t.flac")))
        #expect(AudioFileSupport.isSupported(URL(fileURLWithPath: "/t.M4A")))
        #expect(!AudioFileSupport.isSupported(URL(fileURLWithPath: "/t.txt")))
        #expect(!AudioFileSupport.isSupported(URL(fileURLWithPath: "/t.mov")))
    }
}
