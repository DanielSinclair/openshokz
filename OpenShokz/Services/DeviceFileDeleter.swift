import Foundation

/// Permanently delete audio (and optional sidecar art) from a Shokz volume without blocking the UI.
///
/// Sandbox-safe: in-process FileManager removal — a spawned `/bin/rm` would not
/// inherit the security-scoped volume grant. Runs on the serialized device-I/O
/// lane so deletes never race a listing or copy; a wedged session returns `[]`.
struct DeviceFileDeleter: Sendable {
    struct Item: Sendable {
        let audioURL: URL
        let thumbURL: URL
    }

    /// Returns audio paths that no longer exist on disk after deletion.
    func delete(_ items: [Item], timeoutSeconds: TimeInterval = 30) async -> Set<String> {
        guard !items.isEmpty else { return [] }
        let result = try? await DeviceIOCoordinator.shared.run {
            await Task.detached(priority: .userInitiated) {
                var removed = Set<String>()
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                for item in items {
                    guard Date() < deadline else { break }
                    try? FileManager.default.removeItem(at: item.audioURL)
                    try? FileManager.default.removeItem(at: item.thumbURL)
                    if !FileManager.default.fileExists(atPath: item.audioURL.path) {
                        removed.insert(item.audioURL.path)
                    }
                }
                return removed
            }.value
        }
        return result ?? []
    }
}
