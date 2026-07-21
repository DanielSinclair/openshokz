import AppKit
import Foundation

/// Pure sandbox/bookmark decisions — unit-tested without panels or volumes.
enum VolumeAccessPolicy {
    /// Bookmarks are keyed by the FAT volume serial when available so a grant
    /// survives renames; the name is the fallback for volumes without a UUID.
    static func bookmarkKey(volumeUUID: String?, volumeName: String) -> String {
        if let volumeUUID, !volumeUUID.isEmpty {
            return "volume-bookmark-\(volumeUUID)"
        }
        return "volume-bookmark-name-\(volumeName)"
    }

    /// Only real external volumes need a grant — container paths (mock volumes,
    /// unit-test temp dirs) are always readable inside the sandbox.
    static func requiresGrant(isSandboxed: Bool, mountPath: String) -> Bool {
        isSandboxed && mountPath.hasPrefix("/Volumes/")
    }

    /// A stored bookmark is only usable when it resolves to the mounted path.
    static func bookmarkMatches(resolvedPath: String?, mountPath: String) -> Bool {
        guard let resolvedPath else { return false }
        return resolvedPath == mountPath
    }
}

/// Resolves, requests, and holds the security-scoped grant for the connected
/// Shokz volume. All methods are cheap no-ops outside the sandbox.
@MainActor
final class VolumeAccessManager {
    static let shared = VolumeAccessManager()

    private var activeURL: URL?

    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// True when the app can read the volume right now (not sandboxed, grant
    /// already active, or a stored bookmark resolves and starts).
    func ensureAccess(to mount: URL, volumeUUID: String?, volumeName: String) -> Bool {
        guard VolumeAccessPolicy.requiresGrant(
            isSandboxed: Self.isSandboxed,
            mountPath: mount.path
        ) else { return true }

        if VolumeAccessPolicy.bookmarkMatches(resolvedPath: activeURL?.path, mountPath: mount.path) {
            return true
        }

        let key = VolumeAccessPolicy.bookmarkKey(volumeUUID: volumeUUID, volumeName: volumeName)
        guard let data = UserDefaults.standard.data(forKey: key) else { return false }

        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ),
            VolumeAccessPolicy.bookmarkMatches(resolvedPath: resolved.path, mountPath: mount.path),
            resolved.startAccessingSecurityScopedResource()
        else {
            return false
        }

        stopAccess()
        activeURL = resolved
        if stale, let fresh = try? resolved.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return true
    }

    /// One-time grant panel, anchored at the volume root. Stores the bookmark
    /// so future connects resolve silently.
    func requestAccess(to mount: URL, volumeUUID: String?, volumeName: String) async -> Bool {
        guard VolumeAccessPolicy.requiresGrant(
            isSandboxed: Self.isSandboxed,
            mountPath: mount.path
        ) else { return true }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = mount
        panel.message = "Grant OpenShokz access to “\(volumeName)” so it can manage your library. Just click Grant Access."
        panel.prompt = "Grant Access"

        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let granted = panel.url else { return false }
        guard let data = try? granted.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }

        UserDefaults.standard.set(
            data,
            forKey: VolumeAccessPolicy.bookmarkKey(volumeUUID: volumeUUID, volumeName: volumeName)
        )
        stopAccess()
        guard granted.startAccessingSecurityScopedResource() else { return false }
        activeURL = granted
        return true
    }

    func stopAccess() {
        activeURL?.stopAccessingSecurityScopedResource()
        activeURL = nil
    }
}
