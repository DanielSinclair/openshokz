import Foundation

struct TransferService: DeviceTransferClient, Sendable {
    /// Copy with a hard timeout.
    ///
    /// Sandbox-safe: plain FileManager I/O (the volume is reachable through the
    /// user's security-scoped grant). Copies to a device volume run on the
    /// serialized DeviceIOCoordinator lane so they never race a listing or
    /// delete on the same FSKit `msdos` volume.
    func copyToDevice(
        fileURL: URL,
        volumeRoot: URL,
        destinationFolder: URL? = nil,
        timeoutSeconds: TimeInterval = 90
    ) async throws -> URL {
        let destDir = destinationFolder ?? volumeRoot
        try validateDestinationDepth(destDir: destDir, volumeRoot: volumeRoot)

        let safeName = sanitizeFileName(fileURL.lastPathComponent)
        let preferred = destDir.appendingPathComponent(safeName)

        if isDeviceVolume(volumeRoot) {
            return try await DeviceIOCoordinator.shared.run {
                try await copyViaFileManager(
                    fileURL: fileURL,
                    destDir: destDir,
                    preferred: preferred,
                    timeoutSeconds: timeoutSeconds
                )
            }
        }

        return try await copyViaFileManager(
            fileURL: fileURL,
            destDir: destDir,
            preferred: preferred,
            timeoutSeconds: timeoutSeconds
        )
    }

    // MARK: - FileManager copy

    private func copyViaFileManager(
        fileURL: URL,
        destDir: URL,
        preferred: URL,
        timeoutSeconds: TimeInterval
    ) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try self.copyToDeviceSync(
                    fileURL: fileURL,
                    destDir: destDir,
                    preferred: preferred
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw TransferError.copyFailed(
                    "Copy to headphones timed out. Unplug/replug the cable and try again."
                )
            }
            guard let result = try await group.next() else {
                throw TransferError.copyFailed("Copy failed.")
            }
            group.cancelAll()
            return result
        }
    }

    private func copyToDeviceSync(
        fileURL: URL,
        destDir: URL,
        preferred: URL
    ) throws -> URL {
        if !FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Same basename already present → treat as resolved duplicate (no `(2)` copy).
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }

        do {
            // Settlement contract: chunked write → F_FULLFSYNC → read-back
            // verify. "Done" means the bytes are on the media and correct.
            try SettledCopy.copyAndVerify(from: fileURL, to: preferred)
        } catch let error as SettledCopyError {
            throw TransferError.copyFailed(error.localizedDescription)
        } catch {
            if FileManager.default.fileExists(atPath: preferred.path) {
                return preferred
            }
            throw TransferError.copyFailed(error.localizedDescription)
        }

        // Cover art travels inside the audio file's metadata — never copy
        // sidecar images onto the device.
        return preferred
    }

    // MARK: - Shared helpers

    private func validateDestinationDepth(destDir: URL, volumeRoot: URL) throws {
        let relative = destDir.path.replacingOccurrences(of: volumeRoot.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let folderDepth = relative.isEmpty ? 0 : relative.split(separator: "/").count
        if folderDepth > 2 {
            throw TransferError.destinationTooDeep
        }
    }

    private func isDeviceVolume(_ url: URL) -> Bool {
        url.path.hasPrefix("/Volumes/")
    }

    private func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "track.m4a" : cleaned
    }
}

enum TransferError: LocalizedError {
    case deviceNotConnected
    case destinationTooDeep
    case copyFailed(String)
    case alreadyOnDevice

    var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "No Shokz device connected."
        case .destinationTooDeep:
            return "Destination folder is too deep. Shokz headphones only read up to 3 folder levels."
        case .copyFailed(let message):
            return message
        case .alreadyOnDevice:
            return "Already on headphones."
        }
    }
}
