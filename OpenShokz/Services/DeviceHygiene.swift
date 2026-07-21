import Foundation

/// Keeps the FAT volume clean of macOS litter the headphones can't use.
///
/// Finder and Spotlight scatter `.Trashes`, AppleDouble `._*` files,
/// `.DS_Store`, `.Spotlight-V100`, and `.fseventsd` onto every removable
/// volume. On a 4 GB device that is wasted space (Finder "deletes" land in
/// `.Trashes` and keep occupying the disk), and some players even try to
/// play AppleDouble files. Cleanup runs once per connect on the serialized
/// I/O lane, and writes the two standard opt-out markers so macOS stops
/// re-littering: `.metadata_never_index` (Spotlight) and
/// `.fseventsd/no_log` (filesystem events).
enum DeviceHygiene {
    /// Root-level directories that are safe to remove wholesale.
    static let junkRootDirectories: Set<String> = [
        ".Trashes", ".Spotlight-V100", ".TemporaryItems"
    ]

    /// Junk anywhere in the tree.
    static func isJunkFile(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store"
    }

    struct Result: Equatable, Sendable {
        var removedItems = 0
        var reclaimedBytes: Int64 = 0
    }

    /// Deletes junk and writes the opt-out markers. Best-effort per item —
    /// one locked file must not abort the rest of the sweep.
    @discardableResult
    static func cleanup(volumeRoot: URL) -> Result {
        let fm = FileManager.default
        var result = Result()

        func remove(_ url: URL) {
            let size = allocatedSize(of: url)
            do {
                try fm.removeItem(at: url)
                result.removedItems += 1
                result.reclaimedBytes += size
            } catch {
                // Best-effort: skip and continue.
            }
        }

        // Root-level junk directories.
        let rootEntries = (try? fm.contentsOfDirectory(
            at: volumeRoot,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        for entry in rootEntries where junkRootDirectories.contains(entry.lastPathComponent) {
            remove(entry)
        }

        // AppleDouble + .DS_Store litter through the whole tree.
        if let walker = fm.enumerator(
            at: volumeRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) {
            for case let url as URL in walker {
                let name = url.lastPathComponent
                if name == ".fseventsd" {
                    walker.skipDescendants()
                    continue
                }
                if isJunkFile(name) {
                    remove(url)
                    continue
                }
                // AppleDouble companions are real files on FAT (caught above),
                // but APFS synthesizes them from xattrs and hides them from
                // enumeration — probe for each entry's `._` sibling explicitly.
                let companion = url.deletingLastPathComponent()
                    .appendingPathComponent("._\(name)")
                if fm.fileExists(atPath: companion.path) {
                    remove(companion)
                }
            }
        }

        // Stop Spotlight from rebuilding its index on this volume.
        let neverIndex = volumeRoot.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: neverIndex.path) {
            fm.createFile(atPath: neverIndex.path, contents: Data())
        }

        // Keep .fseventsd but empty it down to the no_log marker.
        let fseventsd = volumeRoot.appendingPathComponent(".fseventsd", isDirectory: true)
        if !fm.fileExists(atPath: fseventsd.path) {
            try? fm.createDirectory(at: fseventsd, withIntermediateDirectories: false)
        }
        let logs = (try? fm.contentsOfDirectory(
            at: fseventsd,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        for log in logs where log.lastPathComponent != "no_log" {
            remove(log)
        }
        let noLog = fseventsd.appendingPathComponent("no_log")
        if !fm.fileExists(atPath: noLog.path) {
            fm.createFile(atPath: noLog.path, contents: Data())
        }

        return result
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in walker {
                let attrs = try? fm.attributesOfItem(atPath: file.path)
                total += (attrs?[.size] as? Int64) ?? 0
            }
        }
        return total
    }
}
