import Foundation
import Testing
@testable import OpenShokz

@Suite("Device IO coordinator")
struct DeviceIOCoordinatorTests {
    /// Thread-safe op log for observing execution order across tasks.
    private final class OpLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []

        func record(_ event: String) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    @Test("operations run strictly one at a time, in FIFO order")
    func serializesOperations() async throws {
        let coordinator = DeviceIOCoordinator()
        let log = OpLog()

        async let first: Void = {
            _ = try? await coordinator.run {
                log.record("first-start")
                try? await Task.sleep(for: .milliseconds(120))
                log.record("first-end")
            }
        }()
        // Give the first op a head start so submission order is deterministic.
        try await Task.sleep(for: .milliseconds(30))
        async let second: Void = {
            _ = try? await coordinator.run {
                log.record("second-start")
                log.record("second-end")
            }
        }()

        _ = await (first, second)
        #expect(
            log.snapshot == ["first-start", "first-end", "second-start", "second-end"],
            "A queued op must never start before its predecessor finishes"
        )
    }

    @Test("wedged session refuses I/O instantly instead of stacking threads")
    func wedgedGate() async {
        let coordinator = DeviceIOCoordinator()
        await coordinator.noteTimeout()
        #expect(await coordinator.isWedged)

        do {
            _ = try await coordinator.run { "touched the volume" }
            Issue.record("Wedged coordinator must not run operations")
        } catch let error as DeviceIOError {
            #expect(error == .volumeUnresponsive)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("reconnect (or Retry) clears the gate")
    func resetRestoresService() async throws {
        let coordinator = DeviceIOCoordinator()
        await coordinator.noteTimeout()
        await coordinator.resetForNewConnection()
        #expect(await !coordinator.isWedged)

        let value = try await coordinator.run { 42 }
        #expect(value == 42)
    }

    @Test("a successful op after transient trouble restores health")
    func successRestoresHealth() async {
        let coordinator = DeviceIOCoordinator()
        await coordinator.noteTimeout()
        await coordinator.noteSuccess()
        #expect(await !coordinator.isWedged)
    }

    @Test("operation errors propagate but do not poison the queue")
    func errorsDoNotPoisonQueue() async throws {
        struct Boom: Error {}
        let coordinator = DeviceIOCoordinator()

        await #expect(throws: Boom.self) {
            try await coordinator.run { throw Boom() }
        }
        let value = try await coordinator.run { "still works" }
        #expect(value == "still works")
    }
}
