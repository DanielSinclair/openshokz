import AppKit
import Foundation
import os

@MainActor
@Observable
final class ShokzVolumeMonitor {
    private static let log = Logger(subsystem: "app.openshokz.OpenShokz", category: "volume")
    private(set) var isConnected = false
    private(set) var rootURL: URL?
    private(set) var volumeName: String?
    /// Stable FAT volume serial — keys the persistent library cache across reconnects.
    private(set) var volumeUUID: String?
    private(set) var freeBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var lastError: String?
    /// Sandbox: true while the connected volume still needs its one-time grant.
    private(set) var needsAccessGrant = false

    /// Event-driven detection: DiskArbitration reports mount, unmount, and cable
    /// yanks within milliseconds. NSWorkspace notifications and a 1s off-main
    /// presence watch back it up — sandboxed delivery of DA callbacks is not
    /// guaranteed, and a yank must never leave the UI stuck on connected.
    private var diskMonitor: DiskArbitrationMonitor?
    private var rescanTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Bumped (debounced) whenever the volume's root entries change on disk —
    /// the UI refreshes the library when it moves.
    private(set) var contentGeneration = 0
    private let contentWatcher = VolumeContentWatcher()
    private var contentBumpTask: Task<Void, Never>?

    var freeSpaceDescription: String {
        ConnectionStatusPresentation.freeSpaceDescription(
            isConnected: isConnected,
            freeBytes: freeBytes
        )
    }

    var capacityDescription: String {
        guard isConnected else { return "" }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// Approx. occupied space — used to avoid a false “No videos” when listing hangs
    /// on a volume that clearly has data (common with wedged FAT USB).
    var usedBytes: Int64 {
        max(0, totalBytes - freeBytes)
    }

    func start() {
        if UITestingSupport.forceDisconnected || UITestingSupport.isSimulatingDisconnected {
            applyDisconnected()
            return
        }
        if UITestingSupport.simulateConnected {
            applySimulatedConnected()
            scheduleUITestAutoDisconnectIfNeeded()
            return
        }

        guard diskMonitor == nil else { return }
        let monitor = DiskArbitrationMonitor { [weak self] event in
            self?.handleDiskEvent(event)
        }
        diskMonitor = monitor
        monitor.start()

        // Notification-center fallback: reliably delivered to sandboxed apps.
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            NSWorkspace.didMountNotification,
            NSWorkspace.willUnmountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rescan() }
            }
        }

        rescan()
    }

    func stop() {
        rescanTask?.cancel()
        rescanTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        contentWatcher.stop()
        contentBumpTask?.cancel()
        contentBumpTask = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        diskMonitor?.stop()
        diskMonitor = nil
    }

    /// Applies a DiskArbitration event. Connect and disconnect both flip state
    /// immediately on the event; capacity fills in from a background read.
    func handleDiskEvent(_ event: DiskEvent) {
        switch event {
        case .appeared(let description), .changed(let description):
            if let update = ShokzDiskPolicy.connectionUpdate(for: description) {
                applyConnected(url: update.url, name: update.name, uuid: update.uuid)
            } else if description.volumePath == nil,
                      isConnected,
                      ShokzDiskPolicy.indicatesOurDisconnect(
                        description,
                        currentRoot: rootURL,
                        currentUUID: volumeUUID
                      ) {
                // Unmounted (volume path dropped) — flip now, then confirm nothing else matches.
                applyDisconnected()
                rescan()
            }
        case .disappeared(let description):
            if ShokzDiskPolicy.indicatesOurDisconnect(
                description,
                currentRoot: rootURL,
                currentUUID: volumeUUID
            ) {
                applyDisconnected()
                rescan()
            }
        }
    }

    /// Reconciles against the mounted-volume list on a background executor.
    /// Never enumerates volumes on the MainActor — statfs on a dying FAT volume can hang.
    func rescan() {
        if UITestingSupport.forceDisconnected || UITestingSupport.isSimulatingDisconnected {
            applyDisconnected()
            return
        }
        if UITestingSupport.simulateConnected {
            applySimulatedConnected()
            return
        }

        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            let snapshot = await Self.scanForShokzVolume()
            guard !Task.isCancelled else { return }
            self?.apply(snapshot)
        }
    }

    /// Testable pure application of a volume scan result.
    func applyScanResult(_ match: (url: URL, name: String)?) {
        guard let match else {
            applyDisconnected()
            return
        }
        applyConnected(url: match.url, name: match.name, uuid: nil)
    }

    func applyConnected(url: URL, name: String, uuid: String?) {
        let wasConnected = isConnected
        isConnected = true
        rootURL = url
        volumeName = name
        if let uuid {
            volumeUUID = uuid
        }
        if !wasConnected {
            // Fresh mount → clean I/O slate (healthy).
            Task { await DeviceIOCoordinator.shared.resetForNewConnection() }
        }
        updateAccessState()
        refreshCapacityInBackground(for: url)
        startPresenceWatch()
        startContentWatch()
    }

    /// Watches the volume root for direct file changes (Finder deletes, drags).
    /// Needs the sandbox grant to open the directory, so it starts post-grant.
    private func startContentWatch() {
        guard let rootURL, !needsAccessGrant else { return }
        contentWatcher.watch(rootURL) { [weak self] in
            Task { @MainActor in self?.scheduleContentBump() }
        }
    }

    /// Coalesces event bursts (one delete = several kqueue writes) into a
    /// single generation bump.
    private func scheduleContentBump() {
        guard contentBumpTask == nil else { return }
        contentBumpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            self.contentBumpTask = nil
            guard self.isConnected else { return }
            self.contentGeneration += 1
        }
    }

    /// Last line of defense: one cheap existence check per second, off the
    /// MainActor. If every notification path misses the yank, the UI still
    /// resets within ~a second.
    private func startPresenceWatch() {
        presenceTask?.cancel()
        presenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.isConnected, let root = self.rootURL else { return }
                let exists = await Self.rootExists(root)
                guard !Task.isCancelled, self.isConnected, self.rootURL == root else { continue }
                if !exists {
                    self.applyDisconnected()
                    self.rescan()
                    return
                }
            }
        }
    }

    nonisolated static func rootExists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Sandbox gate: resolve the stored grant for this volume, or surface the
    /// grant UI. Container paths (mock/test volumes) never need one.
    private func updateAccessState() {
        guard let rootURL, isConnected else {
            needsAccessGrant = false
            return
        }
        if UITestingSupport.isEnabled {
            needsAccessGrant = UITestingSupport.forceNeedsGrant
            return
        }
        needsAccessGrant = !VolumeAccessManager.shared.ensureAccess(
            to: rootURL,
            volumeUUID: volumeUUID,
            volumeName: volumeName ?? rootURL.lastPathComponent
        )
    }

    /// Runs the grant panel; on success the library can list immediately.
    func requestAccessGrant() async -> Bool {
        guard let rootURL else { return false }
        let granted = await VolumeAccessManager.shared.requestAccess(
            to: rootURL,
            volumeUUID: volumeUUID,
            volumeName: volumeName ?? rootURL.lastPathComponent
        )
        if granted {
            needsAccessGrant = false
            startContentWatch()
        }
        return granted
    }

    func applyDisconnected() {
        isConnected = false
        rootURL = nil
        volumeName = nil
        volumeUUID = nil
        freeBytes = 0
        totalBytes = 0
        needsAccessGrant = false
        presenceTask?.cancel()
        presenceTask = nil
        contentWatcher.stop()
        contentBumpTask?.cancel()
        contentBumpTask = nil
        if !UITestingSupport.isEnabled {
            VolumeAccessManager.shared.stopAccess()
        }
    }

    func eject() {
        guard let rootURL else { return }
        lastError = nil
        // unmountAndEjectDevice blocks until the volume lets go — never on the MainActor.
        Task { [weak self] in
            let error = await Self.ejectVolume(at: rootURL)
            guard let self else { return }
            if let error {
                self.lastError = error
            } else {
                self.applyDisconnected()
            }
        }
    }

    private func apply(_ snapshot: VolumeSnapshot?) {
        guard let snapshot else {
            applyDisconnected()
            return
        }
        isConnected = true
        rootURL = snapshot.url
        volumeName = snapshot.name
        volumeUUID = snapshot.uuid ?? volumeUUID
        freeBytes = snapshot.freeBytes
        totalBytes = snapshot.totalBytes
        updateAccessState()
        startPresenceWatch()
        startContentWatch()
    }

    private func refreshCapacityInBackground(for url: URL) {
        Task { [weak self] in
            guard let capacity = await Self.readCapacity(at: url) else { return }
            guard let self, self.rootURL == url else { return }
            self.freeBytes = capacity.free
            self.totalBytes = capacity.total
            if let uuid = capacity.uuid, self.volumeUUID == nil {
                self.volumeUUID = uuid
            }
        }
    }

    private func applySimulatedConnected() {
        isConnected = true
        rootURL = UITestingSupport.mockVolumeURL
        volumeName = "OpenSwim"
        volumeUUID = UITestingSupport.mockVolumeUUID
        needsAccessGrant = UITestingSupport.forceNeedsGrant
        startContentWatch()
        // Empty mock volume — usedBytes must stay 0 so UI shows real empty state.
        freeBytes = 2_000_000_000
        totalBytes = 2_000_000_000
    }

    private func scheduleUITestAutoDisconnectIfNeeded() {
        guard UITestingSupport.autoDisconnectAfterLaunch else { return }
        Task { @MainActor in
            // Long enough for XCUITest to attach and observe the connected
            // phase before the simulated yank flips the UI.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            UITestingSupport.simulateDisconnectForUITest()
            applyDisconnected()

            guard UITestingSupport.autoReconnectAfterDisconnect else { return }
            // Disconnected phase must also be long enough to observe.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            UITestingSupport.resetSimulationOverrides()
            applySimulatedConnected()
        }
    }

    // MARK: - Background volume I/O (never on MainActor)

    struct VolumeSnapshot: Sendable {
        var url: URL
        var name: String
        var uuid: String?
        var freeBytes: Int64
        var totalBytes: Int64
    }

    nonisolated static func scanForShokzVolume() async -> VolumeSnapshot? {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeNameKey,
                .volumeAvailableCapacityKey,
                .volumeTotalCapacityKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeUUIDStringKey
            ],
            options: [.skipHiddenVolumes]
        ) ?? []

        let match = ShokzVolumeIdentity.findVolume(
            among: volumes,
            volumeName: { url in
                let pathName = url.lastPathComponent
                if ShokzVolumeIdentity.matches(name: pathName) {
                    return pathName
                }
                return try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
            },
            isPreferredMount: { url in
                let values = try? url.resourceValues(forKeys: [
                    .volumeIsRemovableKey,
                    .volumeIsEjectableKey
                ])
                return values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
            }
        )

        guard let match else { return nil }
        // Volume list can briefly retain a ghost path after yank — require the root to exist.
        guard FileManager.default.fileExists(atPath: match.url.path) else { return nil }

        let capacity = await readCapacity(at: match.url)
        return VolumeSnapshot(
            url: match.url,
            name: match.name,
            uuid: capacity?.uuid,
            freeBytes: capacity?.free ?? 0,
            totalBytes: capacity?.total ?? 0
        )
    }

    struct VolumeCapacity: Sendable {
        var free: Int64
        var total: Int64
        var uuid: String?
    }

    nonisolated static func readCapacity(at url: URL) async -> VolumeCapacity? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
            .volumeUUIDStringKey
        ]) else {
            return nil
        }
        return VolumeCapacity(
            free: Int64(values.volumeAvailableCapacity ?? 0),
            total: Int64(values.volumeTotalCapacity ?? 0),
            uuid: values.volumeUUIDString
        )
    }

    nonisolated static func ejectVolume(at url: URL) async -> String? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Matching helpers

    static func looksLikeOurVolume(_ url: URL, currentRoot: URL?) -> Bool {
        if let currentRoot, currentRoot.standardizedFileURL == url.standardizedFileURL {
            return true
        }
        return ShokzVolumeIdentity.matches(name: url.lastPathComponent)
    }

    /// Enumerate audio files on a background queue so USB directory I/O
    /// cannot block the main thread (this was freezing the app on plug-in).
    ///
    /// - Publishes each directory batch via `onBatch` as soon as it is found.
    /// - On timeout: returns any partial results; if none, throws `LibraryListError.timedOut`
    ///   (never silent `[]` — that caused a false “No videos” empty state).
    func listAudioFiles(
        timeoutSeconds: TimeInterval = 25,
        onBatch: (@Sendable ([URL]) -> Void)? = nil
    ) async throws -> [URL] {
        guard let rootURL, !needsAccessGrant else {
            Self.log.info("list skipped: root=\(self.rootURL?.path ?? "nil", privacy: .public) needsGrant=\(self.needsAccessGrant)")
            return []
        }
        Self.log.info("list start: \(rootURL.path, privacy: .public)")
        // UI-test mock volume: empty unless seeded for list/delete UI coverage.
        if UITestingSupport.simulateConnected {
            if UITestingSupport.slowListing {
                // Simulated wedged/slow disk: cache-painted rows must already be
                // on screen long before this listing returns.
                try? await Task.sleep(for: UITestingSupport.slowListingDelay)
            }
            if UITestingSupport.seedMockLibrary {
                UITestingSupport.seedMockVolumeIfNeeded()
                return try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let files = try ShokzFileEnumerator.listAudioFiles(at: rootURL) { batch in
                                onBatch?(batch)
                            }
                            continuation.resume(returning: files)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
            return []
        }
        // One volume operation at a time, refused outright once the session is
        // wedged — stacking more I/O onto a hung FSKit volume is what wedges it.
        let coordinator = DeviceIOCoordinator.shared
        do {
            let files = try await coordinator.run {
                try await Self.performListing(
                    root: rootURL,
                    timeoutSeconds: timeoutSeconds,
                    onBatch: onBatch
                )
            }
            await coordinator.noteSuccess()
            Self.log.info("list done: \(files.count) files")
            return files
        } catch let error as LibraryListError {
            Self.log.error("list failed: \(error.localizedDescription, privacy: .public)")
            if case .timedOut = error {
                await coordinator.noteTimeout()
            }
            throw error
        }
    }

    /// Enumerates on a background queue with a hard overall timeout.
    /// The hung worker (if any) is abandoned exactly once — the coordinator's
    /// health gate prevents piling further threads onto the wedged volume.
    nonisolated static func performListing(
        root: URL,
        timeoutSeconds: TimeInterval,
        onBatch: (@Sendable ([URL]) -> Void)?
    ) async throws -> [URL] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[URL], Error>) in
            let lock = NSLock()
            var finished = false
            var partial: [URL] = []
            let finish: (Result<[URL], Error>) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let files = try ShokzFileEnumerator.listAudioFiles(at: root) { batch in
                        lock.lock()
                        partial.append(contentsOf: batch)
                        lock.unlock()
                        onBatch?(batch)
                    }
                    finish(.success(files))
                } catch {
                    finish(.failure(error))
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                lock.lock()
                let snap = partial
                let alreadyFinished = finished
                lock.unlock()
                guard !alreadyFinished else { return }
                // Partial success still paints the library — only hard-fail when nothing found.
                if snap.isEmpty {
                    finish(.failure(LibraryListError.timedOut(partialCount: 0)))
                } else {
                    finish(.success(snap))
                }
            }
        }
    }
}

/// Status chrome copy derived from connection state — unit-tested without USB.
enum ConnectionStatusPresentation {
    static func label(isConnected: Bool, volumeName: String?) -> String {
        guard isConnected else { return "Not connected" }
        let trimmed = volumeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Shokz" : trimmed
    }

    static func freeSpaceDescription(isConnected: Bool, freeBytes: Int64) -> String {
        guard isConnected else { return "Not connected" }
        return "\(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) free"
    }
}
