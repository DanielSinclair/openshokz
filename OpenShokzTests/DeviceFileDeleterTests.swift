import Foundation
import Testing
@testable import OpenShokz

@Suite("Device file deleter")
struct DeviceFileDeleterTests {
    @Test("permanently deletes local audio and sidecar thumbnail")
    func deletesLocalFiles() async throws {
        let root = try makeTempVolume()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = root.appendingPathComponent("clip.m4a")
        let thumb = root.appendingPathComponent("clip.jpg")
        try Data("audio".utf8).write(to: audio)
        try Data("thumb".utf8).write(to: thumb)

        let removed = await DeviceFileDeleter().delete([
            DeviceFileDeleter.Item(audioURL: audio, thumbURL: thumb)
        ])

        #expect(removed.contains(audio.path))
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
    }

    @Test("delete completes asynchronously without blocking caller")
    func asyncDeleteCompletes() async throws {
        let root = try makeTempVolume()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = root.appendingPathComponent("async.m4a")
        try Data("audio".utf8).write(to: audio)

        let removed = await DeviceFileDeleter().delete([
            DeviceFileDeleter.Item(
                audioURL: audio,
                thumbURL: audio.deletingPathExtension().appendingPathExtension("jpg")
            )
        ])

        #expect(removed.contains(audio.path))
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("batch delete removes many tracks with one invocation")
    func batchDelete() async throws {
        let root = try makeTempVolume()
        defer { try? FileManager.default.removeItem(at: root) }

        let items = try (0..<5).map { index -> DeviceFileDeleter.Item in
            let audio = root.appendingPathComponent("track-\(index).m4a")
            let thumb = root.appendingPathComponent("track-\(index).jpg")
            try Data("audio".utf8).write(to: audio)
            try Data("thumb".utf8).write(to: thumb)
            return DeviceFileDeleter.Item(audioURL: audio, thumbURL: thumb)
        }

        let removed = await DeviceFileDeleter().delete(items)
        #expect(removed.count == 5)
        for item in items {
            #expect(!FileManager.default.fileExists(atPath: item.audioURL.path))
            #expect(!FileManager.default.fileExists(atPath: item.thumbURL.path))
        }
    }

    @Test("missing thumbnails do not block audio deletion")
    func missingThumbOK() async throws {
        let root = try makeTempVolume()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = root.appendingPathComponent("solo.m4a")
        try Data("audio".utf8).write(to: audio)

        let removed = await DeviceFileDeleter().delete([
            DeviceFileDeleter.Item(
                audioURL: audio,
                thumbURL: root.appendingPathComponent("solo.jpg")
            )
        ])
        #expect(removed.contains(audio.path))
    }

    @Test("returns empty set for empty input")
    func emptyInput() async {
        let removed = await DeviceFileDeleter().delete([])
        #expect(removed.isEmpty)
    }

    private func makeTempVolume() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokzDeleteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
