import Foundation

enum DeviceIOError: LocalizedError, Equatable {
    /// The volume timed out earlier this session; further I/O is refused until
    /// reconnect (or explicit Retry) instead of stacking more blocked threads.
    case volumeUnresponsive

    var errorDescription: String? {
        "Headphones stopped responding. Unplug/replug the cable, then tap Retry."
    }
}

/// Serializes every operation that touches the device volume.
///
/// FSKit `msdos` handles one request at a time per volume: overlapping
/// listing / metadata reads / copies / deletes queue up behind each other, and
/// each abandoned timeout leaves a thread blocked inside the volume queue —
/// which is precisely the feedback loop that wedges the disk. One operation at
/// a time, plus a health gate that stops issuing I/O after a timeout, keeps
/// the volume responsive and the thread pool intact.
actor DeviceIOCoordinator {
    static let shared = DeviceIOCoordinator()

    enum Health: Sendable, Equatable {
        case healthy
        case wedged
    }

    private(set) var health: Health = .healthy
    /// Tail of the FIFO chain — every operation awaits its predecessor.
    private var lastOperation: Task<Void, Never>?

    var isWedged: Bool { health == .wedged }

    /// Fresh mount (or explicit Retry): the volume gets a clean slate.
    func resetForNewConnection() {
        health = .healthy
    }

    func noteTimeout() {
        health = .wedged
    }

    func noteSuccess() {
        health = .healthy
    }

    /// Runs `operation` after every previously enqueued operation has finished.
    /// Throws `DeviceIOError.volumeUnresponsive` without touching the volume
    /// when the session is already wedged.
    func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard !isWedged else { throw DeviceIOError.volumeUnresponsive }
        let previous = lastOperation
        let task = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        lastOperation = Task { _ = try? await task.value }
        return try await task.value
    }
}
