import Foundation
import Testing
@testable import OpenShokz

@Suite("Settled copy")
struct SettledCopyTests {
    private func tempFile(_ name: String, bytes: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("settled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    @Test("round-trips bytes exactly, including multi-chunk files")
    func roundTrip() throws {
        // > 1 MiB so the chunk loop runs more than once.
        var bytes = Data(count: (1 << 20) * 3 + 12345)
        bytes.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        }
        let source = try tempFile("in.mp3", bytes: bytes)
        let destination = source.deletingLastPathComponent().appendingPathComponent("out.mp3")

        try SettledCopy.copyAndVerify(from: source, to: destination)

        let copied = try Data(contentsOf: destination)
        #expect(copied == bytes)
    }

    @Test("verifies small files (head/tail probe collapses to whole file)")
    func smallFileVerifies() throws {
        let source = try tempFile("a.mp3", bytes: Data("hello settlement".utf8))
        let destination = source.deletingLastPathComponent().appendingPathComponent("b.mp3")
        try SettledCopy.copyAndVerify(from: source, to: destination)
        #expect(try Data(contentsOf: destination) == Data("hello settlement".utf8))
    }

    @Test("verifies a file larger than the head+tail probe window")
    func verifiesBeyondProbeWindow() throws {
        // 300 KiB > 2×64 KiB probe, so head and tail cover distinct regions.
        var bytes = Data(count: 300 * 1024)
        bytes.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 17 &+ 3) }
        }
        let source = try tempFile("big.mp3", bytes: bytes)
        let destination = source.deletingLastPathComponent().appendingPathComponent("big-out.mp3")
        try SettledCopy.copyAndVerify(from: source, to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test("missing source fails loudly, leaving no destination")
    func missingSource() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("settled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("missing.mp3")
        let destination = dir.appendingPathComponent("out.mp3")
        #expect(throws: SettledCopyError.self) {
            try SettledCopy.copyAndVerify(from: source, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
