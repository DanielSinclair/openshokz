import Foundation
import Testing
@testable import OpenShokz

@Suite("Bundled binaries")
struct BundledBinariesTests {
    @Test("repo ffmpeg exists and is executable")
    func ffmpegExists() throws {
        let url = try BundledBinaries.ffmpegURL
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
    }

    @Test("bundled ffmpeg is universal arm64 + x86_64")
    func ffmpegUniversal() throws {
        // Sandbox-safe: parse the Mach-O fat header in-process instead of
        // spawning lipo (child processes cannot read outside the container).
        let url = try BundledBinaries.ffmpegURL
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try #require(try handle.read(upToCount: 4096))
        #expect(header.count >= 8)

        let magic = header.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
        #expect(magic == 0xCAFEBABE, "Expected a fat (universal) binary")

        let archCount = header.dropFirst(4).prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
        var cpuTypes = Set<UInt32>()
        for index in 0..<Int(archCount) {
            let offset = 8 + index * 20
            guard header.count >= offset + 4 else { break }
            let cpu = header.dropFirst(offset).prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
            cpuTypes.insert(cpu)
        }
        #expect(cpuTypes.contains(0x0100000C), "arm64 slice missing")
        #expect(cpuTypes.contains(0x01000007), "x86_64 slice missing")
    }

    @Test("BundledBinaries locates ffmpeg in repo during unit tests")
    func locatesFFmpegInDevTree() throws {
        let url = try BundledBinaries.ffmpegURL
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        #expect(url.lastPathComponent == "ffmpeg")
    }
}
