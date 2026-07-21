import Foundation
import os

/// Pure helpers for Shokz MP3 headphone volume detection — safe to unit test without USB.
enum ShokzVolumeIdentity {
    /// Official USB volume labels from Shokz documentation.
    ///
    /// - **OpenSwim Pro** → `SWIM PRO`
    /// - **OpenSwim** (incl. legacy Xtrainerz firmware) → `OpenSwim`
    ///   (some regions show `OpenSwim (Formerly Xtrainerz)`)
    static let knownLabels: Set<String> = [
        "SWIM PRO",
        "SWIMPRO",
        "OpenSwim Pro",
        "OpenSwim",
        "OpenSwim (Formerly Xtrainerz)",
        "Xtrainerz",
    ]

    /// Fold volume labels for comparison: trim, uppercase, strip spaces/hyphens/underscores.
    static func folded(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    /// True when `name` looks like a Shokz OpenSwim-family MP3 disk.
    static func matches(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if knownLabels.contains(trimmed) { return true }

        let key = folded(trimmed)
        guard !key.isEmpty else { return false }
        if isShokzFoldedIdentity(key) { return true }
        return isOpenSwimLegacyMount(key)
    }

    /// `^(OPEN)?SWIM(PRO)?\d*$` on an already-folded label.
    /// Bare `SWIM` alone is rejected — not a documented volume name.
    private static func isShokzFoldedIdentity(_ folded: String) -> Bool {
        var rest = Substring(folded)
        if rest.hasPrefix("OPEN") {
            rest = rest.dropFirst(4)
        }
        guard rest.hasPrefix("SWIM") else { return false }
        rest = rest.dropFirst(4)
        let hadProSuffix = rest.hasPrefix("PRO")
        if hadProSuffix {
            rest = rest.dropFirst(3)
        }
        guard rest.allSatisfy(\.isNumber) else { return false }
        // Require PRO suffix — bare SWIM and "OPEN SWIM" (without PRO) are not documented volume names.
        return hadProSuffix
    }

    /// Long-form OpenSwim mount strings and pre-rebrand Xtrainerz disks.
    private static func isOpenSwimLegacyMount(_ folded: String) -> Bool {
        if folded.hasPrefix("XTRAINERZ") { return true }
        guard folded.hasPrefix("OPENSWIM"), folded.count > "OPENSWIM".count else { return false }
        let suffix = folded.dropFirst("OPENSWIM".count)
        // e.g. OpenSwim (Formerly Xtrainerz) → OPENSWIM(FORMERLYXTRAINERZ)
        if suffix.first == "(" { return true }
        // e.g. OpenSwim2 → OPENSWIM2
        return suffix.allSatisfy(\.isNumber)
    }

    /// Pick the best mounted volume that looks like a Shokz MP3 disk.
    /// When `isPreferredMount` is set, removable/ejectable candidates win over others.
    static func findVolume(
        among volumes: [URL],
        volumeName: (URL) -> String?,
        isPreferredMount: ((URL) -> Bool)? = nil
    ) -> (url: URL, name: String)? {
        var fallback: (url: URL, name: String)?
        for volume in volumes {
            let name = volumeName(volume) ?? volume.lastPathComponent
            guard matches(name: name) || matches(name: volume.lastPathComponent) else {
                continue
            }
            let candidate = (url: volume, name: name)
            guard let isPreferredMount else {
                return candidate
            }
            if isPreferredMount(volume) {
                return candidate
            }
            if fallback == nil {
                fallback = candidate
            }
        }
        return fallback
    }
}

enum LibraryListError: LocalizedError, Equatable {
    case timedOut(partialCount: Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let count) where count > 0:
            return "Headphones are slow to respond — showing \(count) file\(count == 1 ? "" : "s") found so far."
        case .timedOut:
            return "Headphones aren’t responding to file listing. Unplug/replug the cable, then tap Retry."
        case .unreadable(let message):
            return message
        }
    }
}

/// File-system enumeration kept off the main actor so USB I/O cannot freeze the UI.
///
/// POSIX-only (sandbox-safe): every directory read runs with a per-directory
/// timeout, and the DeviceIOCoordinator serializes operations so listings never
/// compete with copies or deletes on the same FSKit `msdos` volume — the
/// historical cause of wedged readdir calls.
enum ShokzFileEnumerator {
    /// file + up to 3 folders → max 4 path components under root (Shokz limit).
    static let maxPathComponents = 4
    static let posixDirectoryTimeout: TimeInterval = 2.0

    /// Walks breadth-first: root first, then deeper folders.
    /// Calls `onBatch` as soon as each directory yields audio files so the UI can paint early.
    static func listAudioFiles(
        at rootURL: URL,
        onBatch: (([URL]) -> Void)? = nil
    ) throws -> [URL] {
        var results: [URL] = []
        var queue: [(url: URL, depth: Int)] = []
        var cursor = 0

        guard let rootChildren = contentsOfDirectoryTimed(
            at: rootURL,
            timeout: posixDirectoryTimeout
        ) else {
            throw LibraryListError.timedOut(partialCount: 0)
        }

        func consume(children: [URL], depth: Int) {
            var batch: [URL] = []
            for item in children {
                if AudioFileSupport.isSupported(item) {
                    batch.append(item)
                    continue
                }
                guard depth + 1 < maxPathComponents else { continue }
                // Extension-less / non-audio: treat as possible folder without resourceValues.
                if item.pathExtension.isEmpty || !AudioFileSupport.isSupported(item) {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        queue.append((item, depth + 1))
                    }
                }
            }
            if !batch.isEmpty {
                results.append(contentsOf: batch)
                onBatch?(batch)
            }
        }

        consume(children: rootChildren, depth: 0)
        while cursor < queue.count {
            let (dir, depth) = queue[cursor]
            cursor += 1
            guard let children = contentsOfDirectoryTimed(
                at: dir,
                timeout: posixDirectoryTimeout
            ) else {
                continue // skip hung folder; keep what we have
            }
            consume(children: children, depth: depth)
        }

        return results.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// `nil` means timeout (thread abandoned — do not wait on it).
    static func contentsOfDirectoryTimed(
        at url: URL,
        timeout: TimeInterval
    ) -> [URL]? {
        let lock = NSLock()
        var result: [URL]?
        var done = false
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                let items = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                lock.lock()
                if !done {
                    result = items
                }
                lock.unlock()
            } catch {
                Logger(subsystem: "app.openshokz.OpenShokz", category: "volume")
                    .error("readdir failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            done = true
            lock.unlock()
            return nil
        }
        lock.lock()
        let value = result
        lock.unlock()
        return value
    }
}

/// Pure display rules for the connected library surface.
enum LibraryDisplayPolicy {
    /// FAT overhead / stray clusters can look like a few hundred KB; real libraries are larger.
    static let significantUsedBytes: Int64 = 512_000

    static func showsEmptyLibrary(
        trackCount: Int,
        isScanning: Bool,
        lastError: String?,
        usedBytes: Int64,
        isDownloadBusy: Bool
    ) -> Bool {
        guard trackCount == 0, !isDownloadBusy, !isScanning else { return false }
        if lastError != nil { return false }
        // Do not treat "has used space" alone as non-empty — only an explicit list error
        // should block the empty state (Finder/POSIX decide emptiness).
        _ = usedBytes
        return true
    }

    /// Only when listing truly failed (explicit error) and we have nothing to show.
    static func showsReadProblem(
        trackCount: Int,
        isScanning: Bool,
        lastError: String?,
        usedBytes: Int64
    ) -> Bool {
        guard trackCount == 0 else { return false }
        _ = usedBytes
        if lastError != nil { return true }
        guard !isScanning else { return false }
        return false
    }
}
