import Foundation
import Testing
@testable import OpenShokz

@Suite("Transfer service")
struct TransferServiceTests {
    @Test("local destination copies quickly without Finder")
    func localCopySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-Transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.m4a")
        try Data("audio".utf8).write(to: source)

        let transfer = TransferService()
        let started = ContinuousClock.now
        let destination = try await transfer.copyToDevice(
            fileURL: source,
            volumeRoot: root,
            destinationFolder: nil,
            timeoutSeconds: 5
        )
        let elapsed = ContinuousClock.now - started

        #expect(destination.lastPathComponent == "source.m4a")
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(elapsed < .seconds(2))
    }

    @Test("local duplicate basename returns existing file")
    func localDuplicateShortCircuits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-TransferDup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("track.m4a")
        try Data("on-device".utf8).write(to: existing)
        // Same sanitized basename as existing — write source with same name in subfolder.
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("track.m4a")
        try Data("new".utf8).write(to: staged)

        let destination = try await TransferService().copyToDevice(
            fileURL: staged,
            volumeRoot: root,
            timeoutSeconds: 5
        )
        #expect(destination.path == existing.path)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "on-device")
    }

    @Test("rejects destination folders deeper than Shokz limit")
    func destinationTooDeep() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-TransferDeep-\(UUID().uuidString)", isDirectory: true)
        let deep = root
            .appendingPathComponent("a/b/c/d", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.m4a")
        try Data("audio".utf8).write(to: source)

        do {
            _ = try await TransferService().copyToDevice(
                fileURL: source,
                volumeRoot: root,
                destinationFolder: deep,
                timeoutSeconds: 5
            )
            Issue.record("Expected destinationTooDeep error")
        } catch let error as TransferError {
            if case .destinationTooDeep = error {
                #expect(Bool(true))
            } else {
                Issue.record("Wrong TransferError: \(error)")
            }
        }
    }
}
