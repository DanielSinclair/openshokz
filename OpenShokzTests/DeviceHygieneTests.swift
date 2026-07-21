import Foundation
import Testing
@testable import OpenShokz

@Suite("Device hygiene")
struct DeviceHygieneTests {
    private func makeVolume() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-Hygiene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ relative: String, in root: URL, bytes: Int = 4) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    @Test("removes macOS litter and keeps real tracks")
    func removesLitter() throws {
        let root = try makeVolume()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("Track One [uTgqYeVxy2c].mp3", in: root)
        try write("Podcasts/Episode [p123456].mp3", in: root)
        try write(".Trashes/501/deleted-song.mp3", in: root, bytes: 1000)
        try write(".Spotlight-V100/Store-V2/index.db", in: root)
        try write(".TemporaryItems/folders.501/x", in: root)
        try write("._Track One [uTgqYeVxy2c].mp3", in: root)
        try write("Podcasts/._Episode [p123456].mp3", in: root)
        try write(".DS_Store", in: root)
        try write("Podcasts/.DS_Store", in: root)
        try write(".fseventsd/0000000000abc.log", in: root)

        let result = DeviceHygiene.cleanup(volumeRoot: root)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Track One [uTgqYeVxy2c].mp3").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Podcasts/Episode [p123456].mp3").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".Trashes").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".Spotlight-V100").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".TemporaryItems").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("._Track One [uTgqYeVxy2c].mp3").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Podcasts/._Episode [p123456].mp3").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".DS_Store").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Podcasts/.DS_Store").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".fseventsd/0000000000abc.log").path))
        #expect(result.removedItems >= 8)
        #expect(result.reclaimedBytes >= 1000, "Trashed track bytes count as reclaimed")
    }

    @Test("writes the Spotlight and fsevents opt-out markers")
    func writesMarkers() throws {
        let root = try makeVolume()
        defer { try? FileManager.default.removeItem(at: root) }

        DeviceHygiene.cleanup(volumeRoot: root)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent(".metadata_never_index").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent(".fseventsd/no_log").path))
    }

    @Test("idempotent: a second sweep on a clean volume removes nothing")
    func idempotent() throws {
        let root = try makeVolume()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Track [uTgqYeVxy2c].mp3", in: root)

        DeviceHygiene.cleanup(volumeRoot: root)
        let second = DeviceHygiene.cleanup(volumeRoot: root)

        #expect(second == DeviceHygiene.Result())
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Track [uTgqYeVxy2c].mp3").path
        ))
    }

    @Test("junk classification is precise")
    func classification() {
        #expect(DeviceHygiene.isJunkFile("._song.mp3"))
        #expect(DeviceHygiene.isJunkFile(".DS_Store"))
        #expect(!DeviceHygiene.isJunkFile("song.mp3"))
        #expect(!DeviceHygiene.isJunkFile(".metadata_never_index"))
        #expect(DeviceHygiene.junkRootDirectories.contains(".Trashes"))
        #expect(!DeviceHygiene.junkRootDirectories.contains(".fseventsd"))
    }
}
