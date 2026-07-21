import AppKit
import Foundation

@MainActor
@Observable
final class DownloadService {
    private(set) var urlText = ""
    private(set) var preview: RemoteVideoInfo?
    private(set) var isLoadingPreview = false
    private(set) var job: DownloadJob?
    private(set) var statusMessage: String?
    private(set) var lastError: String?
    /// Relative paths (on device) written by the most recent successful send.
    private(set) var lastTransferredRelativePaths: [String] = []
    /// Staging files matching `lastTransferredRelativePaths` by index — the local
    /// copies whose sidecar art/metadata seed the library cache without USB reads.
    private(set) var lastTransferredLocalURLs: [URL] = []
    private(set) var lastTransferredMediaID: String?

    private let runner: any AudioDownloadClient
    private let transfer: any DeviceTransferClient
    private var downloadTask: Task<Void, Never>?
    private var previewTask: Task<RemoteVideoInfo, Error>?

    init(
        runner: any AudioDownloadClient = MediaPipeline(),
        transfer: any DeviceTransferClient = TransferService()
    ) {
        self.runner = runner
        self.transfer = transfer
    }

    /// True only while a download/transfer job is active — never while preview loads.
    var isBusy: Bool {
        guard let phase = job?.phase else { return false }
        switch phase {
        case .queued, .fetchingMetadata, .downloading, .processing, .transferring:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    var progress: Double? {
        guard case .downloading(let value) = job?.phase else { return nil }
        return value
    }

    func setURLText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != urlText else { return }
        urlText = trimmed
        lastError = nil
        preview = nil
    }

    /// Clears the paste/draft URL state. Does not cancel an in-flight download job.
    /// Drops preview unless a job is actively using it for the download row.
    func clearURLDraft() {
        previewTask?.cancel()
        previewTask = nil
        isLoadingPreview = false
        urlText = ""
        lastError = nil
        if !isBusy {
            preview = nil
            // Stop a stray metadata fetch; never touch an active download process.
            Task { await runner.cancel() }
        }
    }

    func pasteFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string), !string.isEmpty {
            setURLText(string)
            Task { await loadPreview() }
        }
    }

    func loadPreview() async {
        lastError = nil
        guard let url = MediaURLResolver.normalize(urlText) else {
            preview = nil
            lastError = "Enter a valid link."
            return
        }
        // Keep any existing preview until the new one arrives — clearing first forces
        // extra Observable churn that can reflow the add-bar TextField.
        if UITestingSupport.skipNetworkPreview {
            isLoadingPreview = true
            defer { isLoadingPreview = false }
            try? await Task.sleep(for: .milliseconds(80))
            return
        }
        previewTask?.cancel()
        let task = Task {
            try await runner.fetchMetadata(for: url)
        }
        previewTask = task
        isLoadingPreview = true
        defer {
            if previewTask == task {
                isLoadingPreview = false
            }
        }
        do {
            preview = try await task.value
        } catch is CancellationError {
            return
        } catch {
            preview = nil
            lastError = error.localizedDescription
        }
    }

    func download(
        sendToDevice: Bool,
        volumeRoot: URL?,
        existingVideoIDs: Set<String> = []
    ) {
        lastError = nil
        statusMessage = nil
        guard let url = MediaURLResolver.normalize(urlText) else {
            lastError = "Enter a valid link."
            return
        }
        // Unsupported links fail loudly and instantly — before any job starts.
        if case .unsupported(let reason) = LinkSupportPolicy.classify(url) {
            lastError = reason
            return
        }

        let jobID = UUID()
        job = DownloadJob(
            id: jobID,
            sourceURL: url,
            info: preview,
            phase: .fetchingMetadata,
            sendToDevice: sendToDevice
        )

        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            await self?.runDownload(
                jobID: jobID,
                url: url,
                sendToDevice: sendToDevice,
                volumeRoot: volumeRoot,
                existingVideoIDs: existingVideoIDs
            )
        }
    }

    /// Waits for the in-flight download task (used by unit tests).
    func awaitCompletion() async {
        await downloadTask?.value
    }

    func cancel() {
        downloadTask?.cancel()
        previewTask?.cancel()
        Task { await runner.cancel() }
        if var current = job {
            current.phase = .cancelled
            job = current
        }
        statusMessage = "Cancelled."
    }

    private func runDownload(
        jobID: UUID,
        url: URL,
        sendToDevice: Bool,
        volumeRoot: URL?,
        existingVideoIDs: Set<String>
    ) async {
        do {
            // Fast path: URL already encodes an id we have — skip network entirely.
            let urlVideoID = MediaURLResolver.videoID(from: url)
            if sendToDevice,
               TrackDeduper.isDuplicate(videoID: urlVideoID, existingIDs: existingVideoIDs) {
                lastTransferredRelativePaths = []
                lastTransferredLocalURLs = []
                lastTransferredMediaID = urlVideoID
                updatePhase(.completed(localURL: volumeRoot ?? url))
                statusMessage = "Already on headphones."
                return
            }

            var info = preview
            if info == nil {
                updatePhase(.fetchingMetadata)
                statusMessage = "Fetching video info…"
                info = try await runner.fetchMetadata(for: url)
                preview = info
                if var current = job {
                    current.info = info
                    job = current
                }
            }

            let videoID = info?.videoID ?? urlVideoID
            if sendToDevice,
               TrackDeduper.isDuplicate(videoID: videoID, existingIDs: existingVideoIDs) {
                lastTransferredRelativePaths = []
                lastTransferredLocalURLs = []
                lastTransferredMediaID = videoID
                updatePhase(.completed(localURL: volumeRoot ?? url))
                statusMessage = "Already on headphones."
                return
            }

            let staging = AppPaths.stagingDirectory(for: jobID)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            updatePhase(.downloading(progress: 0))
            statusMessage = "Downloading…"
            let allowPlaylist = info?.isPlaylist == true
            let files = try await runner.downloadAudio(
                url: url,
                to: staging,
                allowPlaylist: allowPlaylist
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.updatePhase(.downloading(progress: progress))
                    if progress >= 0.99 {
                        self?.statusMessage = "Converting audio…"
                    } else {
                        self?.statusMessage = "Downloading…"
                    }
                }
            }

            guard let primary = files.first else {
                throw MediaPipelineError.downloadFailed("No audio file was produced.")
            }

            // Cover art + tags are already baked in by MediaPipeline's single
            // ffmpeg pass — no separate embed step here.

            if sendToDevice {
                guard let volumeRoot else {
                    throw TransferError.deviceNotConnected
                }
                // Re-check after download in case library listed mid-flight.
                if TrackDeduper.isDuplicate(videoID: videoID, existingIDs: existingVideoIDs) {
                    lastTransferredRelativePaths = []
                    lastTransferredLocalURLs = []
                    lastTransferredMediaID = videoID
                    updatePhase(.completed(localURL: volumeRoot))
                    statusMessage = "Already on headphones."
                    return
                }
                updatePhase(.transferring)
                statusMessage = "Copying to headphones…"
                var lastCopied = primary
                var relativePaths: [String] = []
                for (index, file) in files.enumerated() {
                    if files.count > 1 {
                        statusMessage = "Copying to headphones… (\(index + 1)/\(files.count))"
                    }
                    let destination = try await transfer.copyToDevice(
                        fileURL: file,
                        volumeRoot: volumeRoot,
                        destinationFolder: nil,
                        timeoutSeconds: 90
                    )
                    lastCopied = destination
                    relativePaths.append(
                        VolumePaths.relativePath(of: destination, under: volumeRoot)
                    )
                }
                lastTransferredRelativePaths = relativePaths
                lastTransferredLocalURLs = files
                lastTransferredMediaID = videoID
                updatePhase(.completed(localURL: lastCopied))
                statusMessage = files.count == 1
                    ? "Saved to headphones."
                    : "Saved \(files.count) tracks to headphones."
            } else {
                lastTransferredRelativePaths = []
                lastTransferredLocalURLs = []
                lastTransferredMediaID = videoID
                updatePhase(.completed(localURL: primary))
                statusMessage = "Downloaded to staging folder."
            }
        } catch is CancellationError {
            updatePhase(.cancelled)
            statusMessage = "Cancelled."
        } catch {
            updatePhase(.failed(message: error.localizedDescription))
            lastError = error.localizedDescription
        }
    }

    private func updatePhase(_ phase: DownloadJob.Phase) {
        guard var current = job else { return }
        current.phase = phase
        job = current
    }
}
