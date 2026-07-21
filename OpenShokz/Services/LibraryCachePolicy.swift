import Foundation

/// Pure rules for painting the library from the persistent cache — unit-tested without USB.
enum LibraryCachePolicy {
    /// Whether a cached row belongs to the currently connected device.
    /// Unknown UUIDs (legacy rows, volumes that report none) get the benefit of the
    /// doubt — a wrong ghost row is corrected by the reconcile scan moments later,
    /// while refusing to paint costs the near-instant library on every connect.
    static func shouldPaint(cachedVolumeID: String?, currentVolumeID: String?) -> Bool {
        guard let cachedVolumeID, let currentVolumeID else { return true }
        return cachedVolumeID == currentVolumeID
    }

    /// Whether a cached row should be dropped after a completed listing that
    /// did not include it. Rows owned by a different device must survive.
    static func shouldEvictAfterReconcile(
        cachedVolumeID: String?,
        currentVolumeID: String?
    ) -> Bool {
        // Unowned rows always reconcile against the mounted volume.
        guard let cachedVolumeID else { return true }
        // The current volume's UUID is captured asynchronously after connect;
        // while it is still unknown, another device's rows must never be
        // evicted — that race wiped the second device's cache.
        guard let currentVolumeID else { return false }
        return cachedVolumeID == currentVolumeID
    }
}

/// Decides which files still need an AVFoundation read over USB.
/// Files the app put there (or already enriched once) are fully described by the
/// cache — re-reading them every scan was the single largest source of USB traffic.
enum EnrichmentPolicy {
    static func needsFileRead(cachedDuration: Double?, hasCachedArtwork: Bool) -> Bool {
        !((cachedDuration ?? 0) > 0 && hasCachedArtwork)
    }
}

/// Path identity helpers for files on the device volume.
enum VolumePaths {
    /// Relative path of `fileURL` under `root`, tolerant of the `/private/var`
    /// ↔ `/var` symlink pair (temp dirs resolve differently between APIs).
    /// Pure string work — never touches the filesystem, safe on wedged volumes.
    static func relativePath(of fileURL: URL, under root: URL) -> String {
        let file = normalized(fileURL.path)
        let rootPath = normalized(root.path)
        guard file.hasPrefix(rootPath) else {
            return fileURL.lastPathComponent
        }
        return String(file.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func normalized(_ path: String) -> String {
        for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"]
        where path.hasPrefix(prefix) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}

/// Cheap change signal for the connected volume: one `stat` of the root plus free
/// space. Replaces the old full re-list + AVFoundation re-read every 10 seconds —
/// the library only rescans when this token actually changes.
struct VolumeChangeToken: Equatable, Sendable {
    var rootModified: Date?
    var freeBytes: Int64?

    /// True only when both observations exist and differ — a failed capture
    /// (wedged volume, unmount race) must never trigger a rescan by itself.
    static func changed(previous: VolumeChangeToken?, current: VolumeChangeToken?) -> Bool {
        guard let previous, let current else { return false }
        return previous != current
    }

    /// Runs off the MainActor; `nil` when the root is missing or unreadable.
    nonisolated static func capture(root: URL?) async -> VolumeChangeToken? {
        guard let root else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: root.path)
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let modified = attributes?[.modificationDate] as? Date
        let free = values?.volumeAvailableCapacity.map(Int64.init)
        guard modified != nil || free != nil else { return nil }
        return VolumeChangeToken(rootModified: modified, freeBytes: free)
    }
}
