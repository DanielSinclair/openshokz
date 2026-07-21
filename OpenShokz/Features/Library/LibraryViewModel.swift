import AppKit
import Foundation
import os
import SwiftData

@MainActor
@Observable
final class LibraryViewModel {
    /// Always mirrors the filesystem.
    private(set) var tracks: [DeviceTrack] = []
    private(set) var isScanning = false
    private(set) var lastError: String?
    var selection = Set<DeviceTrack.ID>()

    private let scanner = LibraryScanner()
    private var backfill: TrackMetadataBackfill
    private var modelContext: ModelContext?
    private var refreshGeneration = 0
    private var backfillTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?
    private let fileDeleter = DeviceFileDeleter()
    /// Paths optimistically hidden until disk delete finishes (stops periodic refresh from re-adding rows).
    private var pendingDeletePaths = Set<String>()
    /// Paths already backfilled this process — avoids re-fetch loops without blocking retries after app relaunch.
    private var backfillCompletedPaths = Set<String>()
    /// Lazily rebuilt relativePath → TrackState map (see `stateIndex()`).
    private var stateIndexCache: [String: TrackState]?
    /// Hygiene sweep (.Trashes, AppleDouble, Spotlight litter) runs once per
    /// connection — reset by `clear()` on disconnect.
    private var hygieneRan = false

    init(backfill: TrackMetadataBackfill = TrackMetadataBackfill()) {
        self.backfill = backfill
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        invalidateStateIndex()
    }

    var visibleTracks: [DeviceTrack] {
        tracks
    }

    /// Media ids already present on the device (from filenames and TrackState).
    var existingVideoIDs: Set<String> {
        var ids = TrackDeduper.videoIDs(inFileNames: tracks.map(\.fileName))
        for track in tracks {
            if let known = state(for: track)?.mediaID, !known.isEmpty {
                ids.insert(known)
            }
        }
        return ids
    }

    func clear() {
        deleteTask?.cancel()
        deleteTask = nil
        pendingDeletePaths.removeAll()
        backfillTask?.cancel()
        backfillTask = nil
        backfillCompletedPaths.removeAll()
        tracks = []
        selection.removeAll()
        isScanning = false
        lastError = nil
        hygieneRan = false
    }

    func annotateMediaID(relativePaths: [String], mediaID id: String?) {
        guard let context = modelContext, let id, !id.isEmpty else { return }
        for track in tracks where relativePaths.contains(track.relativePath) {
            if let existing = state(for: track) {
                existing.mediaID = id
            } else {
                context.insert(TrackState(identityKey: track.identityKey, mediaID: id))
                invalidateStateIndex()
            }
        }
        try? context.save()
    }

    func refresh(volume: ShokzVolumeMonitor, force: Bool = false) async {
        guard volume.isConnected, let root = volume.rootURL else {
            clear()
            return
        }

        // Avoid overlapping USB walks — a second refresh while the first is hung
        // would leave isScanning stuck true (older defer skips clearing).
        // Explicit Retry (force) abandons the in-flight generation.
        guard !isScanning || force else { return }

        refreshGeneration += 1
        let generation = refreshGeneration
        isScanning = true
        // Instant paint from the persistent cache before any USB I/O.
        paintFromCache(volume: volume)
        if force {
            // Explicit Retry clears the wedged gate — the user asked to try again.
            await DeviceIOCoordinator.shared.resetForNewConnection()
        }
        defer {
            if generation == refreshGeneration {
                isScanning = false
            }
        }

        var collected: [URL] = []

        do {
            let files = try await volume.listAudioFiles { [weak self] batch in
                Task { @MainActor in
                    guard let self, generation == self.refreshGeneration else { return }
                    let batch = self.excludingPendingDeletes(batch)
                    let existing = Set(self.tracks.map(\.url.path))
                    let novel = batch.filter { !existing.contains($0.path) }
                    guard !novel.isEmpty else { return }
                    // Insert only the new rows into the already-sorted list —
                    // no full rebuild/re-sort per directory batch.
                    let novelTracks = self.scanner.quickTracks(volumeRoot: root, files: novel)
                    self.publishTracks(
                        LibraryScanner.mergeSortedByTitle(self.tracks, inserting: novelTracks)
                    )
                }
            }
            guard generation == refreshGeneration else { return }

            // Release optimistic deletes the volume has now confirmed gone; keep
            // hiding any a stale FAT listing still reports (they were really
            // deleted, so this only waits out the lag — no flashing row).
            if !pendingDeletePaths.isEmpty {
                let stillPresent = Set(files.map(\.path))
                pendingDeletePaths.formIntersection(stillPresent)
            }

            collected = excludingPendingDeletes(files)
            publishTracks(scanner.quickTracks(volumeRoot: root, files: collected))

            // Successful list (even empty) clears the read-problem state.
            // Do NOT invent a timeout error just because usedBytes > 0.
            lastError = nil
            // Runs even for an empty listing — that is exactly when stale cache
            // rows must be evicted so they cannot ghost-paint the next connect.
            reconcileCache(volumeID: volume.volumeUUID)
            scheduleHygieneIfNeeded(root: root)
            guard !collected.isEmpty else { return }

            // Only read files the cache cannot fully describe — everything the app
            // transferred (or already enriched) skips AVFoundation-over-USB entirely.
            // Explicit Retry (force) re-reads everything.
            let needingRead = force ? collected : collected.filter { url in
                let relative = VolumePaths.relativePath(of: url, under: root)
                guard let state = stateForRelativePath(relative) else { return true }
                return EnrichmentPolicy.needsFileRead(
                    cachedDuration: state.cachedDuration,
                    hasCachedArtwork: state.cachedArtworkJPEG != nil
                )
            }
            // Enrichment shares the serialized I/O lane; on a wedged volume it is
            // skipped silently — rows still paint from filenames and cache.
            let localScanner = scanner
            let enriched = needingRead.isEmpty
                ? []
                : (try? await DeviceIOCoordinator.shared.run {
                    await localScanner.enrich(volumeRoot: root, files: needingRead)
                }) ?? []
            guard generation == refreshGeneration else { return }
            if !enriched.isEmpty {
                let enrichedByRelative = Dictionary(
                    enriched.map { ($0.relativePath, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                publishTracks(tracks.map { enrichedByRelative[$0.relativePath] ?? $0 })
                ensureStates(for: tracks)
                cacheArtworkFromTracks(tracks)
            } else {
                ensureStates(for: tracks)
                publishTracks(mergeTrackMetadata(tracks))
            }
            reconcileCache(volumeID: volume.volumeUUID)
            if force {
                resetRemoteMetadataAttempts(for: tracks)
                backfillCompletedPaths.removeAll()
            }
            scheduleLegacySidecarCleanup(for: collected)
            scheduleBackfill(generation: generation)
        } catch {
            guard generation == refreshGeneration else { return }
            lastError = error.localizedDescription
            // Keep any partial tracks already painted; never wipe to a false empty library.
        }
    }

    /// Optimistically removes rows, then deletes on the device off the main thread.
    func deleteSelected(volume: ShokzVolumeMonitor) {
        let selected = tracks.filter { selection.contains($0.id) }
        guard !selected.isEmpty else { return }

        let pathsToRemove = Set(selected.map(\.url.path))
        let deleteItems = selected.map { track in
            DeviceFileDeleter.Item(
                audioURL: track.url,
                thumbURL: track.url.deletingPathExtension().appendingPathExtension("jpg")
            )
        }

        selection.removeAll()
        tracks.removeAll { pathsToRemove.contains($0.url.path) }
        pendingDeletePaths.formUnion(pathsToRemove)
        backfillTask?.cancel()
        backfillTask = nil
        for path in pathsToRemove {
            backfillCompletedPaths.remove(path)
        }
        // Drop cache rows immediately so a reconnect can never ghost-paint them.
        removeCachedStates(for: selected)

        deleteTask?.cancel()
        deleteTask = Task { [weak self] in
            guard let self else { return }
            let removed = await self.fileDeleter.delete(deleteItems)
            guard !Task.isCancelled else { return }
            // Successfully-removed paths stay in pendingDeletePaths — the debounced
            // volume-content watcher will re-list ~600ms later, and a stale FAT
            // listing can still return a just-deleted entry. Keeping them hidden
            // until `refresh` confirms the volume no longer reports them stops the
            // deleted row from flashing back. `refresh` releases them once gone.
            let failed = pathsToRemove.subtracting(removed)
            guard !failed.isEmpty else { return }
            // A failed delete: stop hiding those rows and rescan so they reappear.
            pendingDeletePaths.subtract(failed)
            await self.refresh(volume: volume, force: true)
        }
    }

    func revealInFinder(_ track: DeviceTrack) {
        FinderReveal.reveal(track.url)
    }

    /// Opens the track's original source page in the default browser.
    @discardableResult
    func openOriginal(_ track: DeviceTrack) -> Bool {
        let knownID = state(for: track)?.mediaID
        guard let url = TrackFileNaming.sourceURL(
            fileName: track.fileName,
            knownVideoID: knownID
        ) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    /// Whether a source page exists to open for this track.
    func hasOriginal(_ track: DeviceTrack) -> Bool {
        TrackFileNaming.sourceURL(
            fileName: track.fileName,
            knownVideoID: state(for: track)?.mediaID
        ) != nil
    }

    func displayTitle(for track: DeviceTrack) -> String {
        if let override = state(for: track)?.titleOverride, !override.isEmpty {
            return TrackFileNaming.displayTitle(fileName: override, metadataTitle: nil)
        }
        return TrackFileNaming.displayTitle(
            fileName: track.fileName,
            metadataTitle: track.title
        )
    }

    func displayDuration(for track: DeviceTrack) -> TimeInterval? {
        if let duration = track.duration, duration > 0 { return duration }
        if let cached = state(for: track)?.cachedDuration, cached > 0 { return cached }
        return nil
    }

    /// Prefers in-memory artwork, then SwiftData JPEG cache from prior sessions.
    func displayArtwork(for track: DeviceTrack) -> NSImage? {
        if let artwork = track.artwork { return artwork }
        if let jpeg = state(for: track)?.cachedArtworkJPEG, !jpeg.isEmpty {
            return NSImage(data: jpeg)
        }
        return nil
    }

    // MARK: - Persistent library cache

    /// Paints rows from SwiftData immediately — zero USB I/O. The reconcile scan
    /// that follows corrects any drift (files changed while disconnected).
    func paintFromCache(volume: ShokzVolumeMonitor) {
        guard tracks.isEmpty, let root = volume.rootURL, let context = modelContext else { return }
        let states = (try? context.fetch(FetchDescriptor<TrackState>())) ?? []
        let rows = states.compactMap { state -> DeviceTrack? in
            guard let relative = state.cacheRelativePath,
                  LibraryCachePolicy.shouldPaint(
                    cachedVolumeID: state.volumeID,
                    currentVolumeID: volume.volumeUUID
                  )
            else { return nil }
            let url = root.appendingPathComponent(relative)
            guard !pendingDeletePaths.contains(url.path) else { return nil }
            let fileName = url.lastPathComponent
            let overrideTitle = state.titleOverride
            return DeviceTrack(
                id: relative,
                url: url,
                relativePath: relative,
                fileName: fileName,
                title: TrackFileNaming.displayTitle(
                    fileName: overrideTitle?.isEmpty == false ? overrideTitle! : fileName,
                    metadataTitle: nil
                ),
                artist: nil,
                duration: state.cachedDuration,
                fileSize: 0,
                modifiedAt: .distantPast,
                artwork: state.cachedArtworkJPEG.flatMap { NSImage(data: $0) }
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        guard !rows.isEmpty else { return }
        tracks = rows
    }

    /// Adds just-transferred files to the library and cache directly — the app
    /// knows exactly what it copied, so no device rescan is needed. Metadata
    /// (title, duration, artwork) comes from the download pipeline, so these
    /// files never need AVFoundation reads over USB or a network backfill.
    func recordTransfer(
        volume: ShokzVolumeMonitor,
        relativePaths: [String],
        localURLs: [URL] = [],
        info: RemoteVideoInfo?,
        mediaID: String?
    ) {
        guard let root = volume.rootURL, !relativePaths.isEmpty else { return }
        // Playlist sends reuse one info blob — its title/duration only describe
        // a single-file transfer.
        let isSingle = relativePaths.count == 1
        let duration = isSingle ? info?.duration : nil
        let remoteTitle = isSingle ? info?.title : nil

        var artworkByRelative: [String: Data] = [:]
        for (index, relative) in relativePaths.enumerated() where index < localURLs.count {
            let sidecar = localURLs[index]
                .deletingPathExtension()
                .appendingPathExtension("jpg")
            if let jpeg = try? Data(contentsOf: sidecar), !jpeg.isEmpty {
                artworkByRelative[relative] = jpeg
            }
        }

        let known = Set(tracks.map(\.relativePath))
        var added: [DeviceTrack] = []
        for relative in relativePaths where !known.contains(relative) {
            let url = root.appendingPathComponent(relative)
            let fileName = url.lastPathComponent
            added.append(
                DeviceTrack(
                    id: relative,
                    url: url,
                    relativePath: relative,
                    fileName: fileName,
                    title: TrackFileNaming.displayTitle(
                        fileName: fileName,
                        metadataTitle: remoteTitle
                    ),
                    artist: nil,
                    duration: duration,
                    fileSize: 0,
                    modifiedAt: .now,
                    artwork: artworkByRelative[relative].flatMap { NSImage(data: $0) }
                )
            )
        }

        if !added.isEmpty {
            tracks = mergeTrackMetadata(
                (tracks + added).sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            )
        }

        guard let context = modelContext else { return }
        for relative in relativePaths {
            let state = stateForRelativePath(relative) ?? {
                let created = TrackState(
                    identityKey: relative + "|0|0",
                    addedAt: .now
                )
                context.insert(created)
                invalidateStateIndex()
                return created
            }()
            state.relativePath = relative
            state.volumeID = volume.volumeUUID ?? state.volumeID
            state.lastSeenAt = .now
            if let mediaID, !mediaID.isEmpty {
                state.mediaID = mediaID
            }
            if let duration, duration > 0 {
                state.cachedDuration = duration
            }
            if let jpeg = artworkByRelative[relative] {
                state.cachedArtworkJPEG = jpeg
            }
            if let remoteTitle, !remoteTitle.isEmpty, state.titleOverride == nil {
                state.titleOverride = TrackFileNaming.displayTitle(
                    fileName: remoteTitle,
                    metadataTitle: remoteTitle
                )
            }
            // With duration + art in hand there is nothing left to backfill.
            if (state.cachedDuration ?? 0) > 0, state.cachedArtworkJPEG != nil {
                state.remoteMetadataAttempted = true
                backfillCompletedPaths.insert(root.appendingPathComponent(relative).path)
            }
        }
        try? context.save()
    }

    /// After a completed listing: stamp live rows, evict rows the listing no longer
    /// contains (same device only). Keeps the cache an honest mirror of the volume.
    private func reconcileCache(volumeID: String?) {
        guard let context = modelContext else { return }
        let states = (try? context.fetch(FetchDescriptor<TrackState>())) ?? []
        let liveByRelative = Set(tracks.map(\.relativePath))
        var didChange = false
        for state in states {
            guard let relative = state.cacheRelativePath else { continue }
            if liveByRelative.contains(relative) {
                if state.relativePath == nil || state.volumeID == nil || state.lastSeenAt == nil {
                    didChange = true
                }
                state.relativePath = relative
                if let volumeID { state.volumeID = volumeID }
                state.lastSeenAt = .now
            } else if LibraryCachePolicy.shouldEvictAfterReconcile(
                cachedVolumeID: state.volumeID,
                currentVolumeID: volumeID
            ) {
                context.delete(state)
                invalidateStateIndex()
                didChange = true
            }
        }
        if didChange {
            try? context.save()
        }
    }

    private func removeCachedStates(for removed: [DeviceTrack]) {
        guard let context = modelContext else { return }
        for track in removed {
            if let state = state(for: track) {
                context.delete(state)
            }
        }
        invalidateStateIndex()
        try? context.save()
    }

    private func stateForRelativePath(_ relative: String) -> TrackState? {
        stateIndex()[relative]
    }

    // MARK: - Backfill

    private func scheduleBackfill(generation: Int) {
        guard !UITestingSupport.isEnabled else { return }
        backfillTask?.cancel()
        backfillTask = Task { [weak self] in
            await self?.runBackfill(generation: generation)
        }
    }

    private func runBackfill(generation: Int) async {
        let candidates = tracks.filter { track in
            guard track.needsRemoteMetadata else { return false }
            guard TrackMetadataBackfill.videoID(
                for: track,
                knownID: state(for: track)?.mediaID
            ) != nil else {
                return false
            }
            if backfillCompletedPaths.contains(track.url.path) {
                return false
            }
            // Skip only when a prior attempt already cached both duration and art.
            if let state = state(for: track),
               state.hasAttemptedRemoteMetadata,
               (state.cachedDuration ?? 0) > 0,
               state.cachedArtworkJPEG != nil {
                return false
            }
            return true
        }
        guard !candidates.isEmpty else { return }

        struct WorkItem: Sendable {
            var path: String
            var track: DeviceTrack
            var knownID: String?
        }
        let work: [WorkItem] = candidates.map { track in
            WorkItem(
                path: track.url.path,
                track: track,
                knownID: state(for: track)?.mediaID
            )
        }
        let backfillService = backfill

        await withTaskGroup(of: (String, TrackMetadataBackfill.Result?).self) { group in
            var iterator = work.makeIterator()
            var inFlight = 0
            let limit = 2

            func enqueue() {
                while inFlight < limit, let item = iterator.next() {
                    inFlight += 1
                    group.addTask {
                        let result = await backfillService.backfill(
                            track: item.track,
                            knownVideoID: item.knownID
                        )
                        return (item.path, result)
                    }
                }
            }

            enqueue()
            for await (path, result) in group {
                inFlight -= 1
                enqueue()
                guard generation == refreshGeneration else {
                    group.cancelAll()
                    return
                }
                backfillCompletedPaths.insert(path)
                if let result {
                    applyBackfillResult(path: path, result: result)
                } else {
                    markRemoteMetadataAttempted(path: path)
                }
            }
        }
    }

    private func markRemoteMetadataAttempted(path: String) {
        guard let track = tracks.first(where: { $0.url.path == path }) else { return }
        if let existing = state(for: track) {
            existing.remoteMetadataAttempted = true
        } else if let context = modelContext {
            context.insert(
                TrackState(
                    identityKey: track.identityKey,
                    mediaID: TrackFileNaming.parse(track.fileName).videoID,
                    remoteMetadataAttempted: true
                )
            )
            invalidateStateIndex()
        }
        try? modelContext?.save()
    }

    private func applyBackfillResult(path: String, result: TrackMetadataBackfill.Result) {
        guard let index = tracks.firstIndex(where: { $0.url.path == path }) else { return }
        tracks[index] = result.track

        guard modelContext != nil else { return }
        let track = result.track
        if let existing = state(for: track) {
            existing.mediaID = result.videoID
            existing.remoteMetadataAttempted = true
            if let duration = result.remoteDuration, duration > 0 {
                existing.cachedDuration = duration
            }
            if let jpeg = result.artworkJPEG, !jpeg.isEmpty {
                existing.cachedArtworkJPEG = jpeg
            }
            if let title = result.remoteTitle, !title.isEmpty, existing.titleOverride == nil {
                existing.titleOverride = TrackFileNaming.displayTitle(
                    fileName: title,
                    metadataTitle: title
                )
            }
        } else if let context = modelContext {
            context.insert(
                TrackState(
                    identityKey: track.identityKey,
                    mediaID: result.videoID,
                    titleOverride: result.remoteTitle.map {
                        TrackFileNaming.displayTitle(fileName: $0, metadataTitle: $0)
                    },
                    cachedDuration: result.remoteDuration,
                    cachedArtworkJPEG: result.artworkJPEG,
                    remoteMetadataAttempted: true
                )
            )
            invalidateStateIndex()
        }
        try? modelContext?.save()
    }

    private func publishTracks(_ incoming: [DeviceTrack]) {
        tracks = mergeTrackMetadata(incoming)
    }

    private func excludingPendingDeletes(_ urls: [URL]) -> [URL] {
        guard !pendingDeletePaths.isEmpty else { return urls }
        return urls.filter { !pendingDeletePaths.contains($0.path) }
    }

    private func mergeTrackMetadata(_ incoming: [DeviceTrack]) -> [DeviceTrack] {
        let previousByPath = Dictionary(uniqueKeysWithValues: tracks.map { ($0.url.path, $0) })
        return incoming.map { track in
            var merged = track
            if merged.artwork == nil, let previous = previousByPath[track.url.path]?.artwork {
                merged = merged.updating(artwork: previous)
            }
            let cached = state(for: merged)
            let duration: TimeInterval? = {
                if let duration = merged.duration, duration > 0 { return duration }
                if let cachedDuration = cached?.cachedDuration, cachedDuration > 0 {
                    return cachedDuration
                }
                return merged.duration
            }()
            let artwork = merged.artwork
                ?? cached?.cachedArtworkJPEG.flatMap { NSImage(data: $0) }
            return merged.updating(duration: duration, artwork: artwork)
        }
    }

    /// Persist cover art loaded from the file into SwiftData for cross-session cache.
    private func cacheArtworkFromTracks(_ tracks: [DeviceTrack]) {
        guard modelContext != nil else { return }
        var didChange = false
        for track in tracks {
            guard let jpeg = jpegData(from: track.artwork), !jpeg.isEmpty else { continue }
            if let existing = state(for: track) {
                if existing.cachedArtworkJPEG == nil {
                    existing.cachedArtworkJPEG = jpeg
                    didChange = true
                }
            } else if let context = modelContext {
                context.insert(
                    TrackState(
                        identityKey: track.identityKey,
                        mediaID: TrackFileNaming.parse(track.fileName).videoID,
                        cachedArtworkJPEG: jpeg
                    )
                )
                invalidateStateIndex()
                didChange = true
            }
            scheduleArtworkEmbed(for: track.url, jpeg: jpeg)
        }
        if didChange {
            try? modelContext?.save()
        }
    }

    /// One hygiene sweep per connection, after the first successful listing —
    /// the volume is provably readable at that point. Serialized on the I/O lane.
    private func scheduleHygieneIfNeeded(root: URL) {
        guard !hygieneRan, !UITestingSupport.isEnabled else { return }
        guard root.path.hasPrefix("/Volumes/") else { return }
        hygieneRan = true
        Task.detached(priority: .utility) {
            let result = try? await DeviceIOCoordinator.shared.run {
                DeviceHygiene.cleanup(volumeRoot: root)
            }
            if let result, result.removedItems > 0 {
                let freed = ByteCountFormatter.string(
                    fromByteCount: result.reclaimedBytes, countStyle: .file
                )
                Logger(subsystem: "app.openshokz.OpenShokz", category: "hygiene").info(
                    "Removed \(result.removedItems) junk items, reclaimed \(freed)"
                )
            }
        }
    }

    /// Migration: older versions saved cover art as .jpg sidecars on the
    /// device. Fold each one into its track's metadata, then delete it.
    /// Runs on the serialized I/O lane at utility priority; sidecars exist at
    /// most once per file, so later connects no-op on cheap existence checks.
    private func scheduleLegacySidecarCleanup(for files: [URL]) {
        guard !UITestingSupport.isEnabled else { return }
        Task.detached(priority: .utility) {
            try? await DeviceIOCoordinator.shared.run {
                for audio in files {
                    for ext in ["jpg", "png"] {
                        let sidecar = audio.deletingPathExtension().appendingPathExtension(ext)
                        guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
                        if let data = try? Data(contentsOf: sidecar) {
                            try? ArtworkEmbedder.embed(artwork: data, into: audio)
                        }
                        try? FileManager.default.removeItem(at: sidecar)
                    }
                }
            }
        }
    }

    /// Best-effort: embed cover art into the audio file's metadata
    /// (background, never blocks UI). No sidecar files.
    private func scheduleArtworkEmbed(for audioURL: URL, jpeg: Data) {
        Task.detached(priority: .utility) {
            try? ArtworkEmbedder.embed(artwork: jpeg, into: audioURL)
        }
    }

    private func jpegData(from image: NSImage?) -> Data? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private func resetRemoteMetadataAttempts(for tracks: [DeviceTrack]) {
        for track in tracks where track.needsRemoteMetadata {
            state(for: track)?.remoteMetadataAttempted = false
            state(for: track)?.cachedArtworkJPEG = nil
            state(for: track)?.cachedDuration = nil
        }
        try? modelContext?.save()
    }

    private func ensureStates(for tracks: [DeviceTrack]) {
        guard let context = modelContext else { return }
        for track in tracks where state(for: track) == nil {
            let parsedID = TrackFileNaming.parse(track.fileName).videoID
            context.insert(
                TrackState(
                    identityKey: track.identityKey,
                    mediaID: parsedID,
                    addedAt: .now
                )
            )
            invalidateStateIndex()
        }
        try? context.save()
    }

    // MARK: - State lookup index

    /// One fetch per generation instead of a full-table fetch per `state(for:)`
    /// call — display helpers hit this on every row render.
    private func stateIndex() -> [String: TrackState] {
        if let stateIndexCache { return stateIndexCache }
        guard let context = modelContext else { return [:] }
        let all = (try? context.fetch(FetchDescriptor<TrackState>())) ?? []
        var index: [String: TrackState] = [:]
        for state in all {
            guard let relative = state.cacheRelativePath else { continue }
            if index[relative] == nil {
                index[relative] = state
            }
        }
        stateIndexCache = index
        return index
    }

    /// Call after any TrackState insert/delete so the index rebuilds lazily.
    private func invalidateStateIndex() {
        stateIndexCache = nil
    }

    private func state(for track: DeviceTrack) -> TrackState? {
        stateIndex()[track.relativePath]
    }
}
