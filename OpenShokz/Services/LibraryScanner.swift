import AppKit
import AVFoundation
import Foundation

struct LibraryScanner: Sendable {
    /// Cap parallel AVFoundation work — USB devices choke under unbounded load.
    private let maxConcurrentLoads = 3

    /// Instant filesystem → rows (filename only). No AVFoundation.
    func quickTracks(volumeRoot: URL, files: [URL]) -> [DeviceTrack] {
        files.compactMap { fileURL in
            let relative = VolumePaths.relativePath(of: fileURL, under: volumeRoot)
            let title = TrackFileNaming.displayTitle(
                fileName: fileURL.lastPathComponent,
                metadataTitle: nil
            )
            let identity = relative
            return DeviceTrack(
                id: identity,
                url: fileURL,
                relativePath: relative,
                fileName: fileURL.lastPathComponent,
                title: title,
                artist: nil,
                duration: nil,
                fileSize: 0,
                modifiedAt: .distantPast,
                artwork: nil
            )
        }
        .sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Merge a title-sorted row list with a batch of new rows (O(n+m), no full
    /// re-sort per listing batch). Rows already present by relative path win.
    static func mergeSortedByTitle(
        _ existing: [DeviceTrack],
        inserting incoming: [DeviceTrack]
    ) -> [DeviceTrack] {
        guard !incoming.isEmpty else { return existing }
        let known = Set(existing.map(\.relativePath))
        let fresh = incoming
            .filter { !known.contains($0.relativePath) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        guard !fresh.isEmpty else { return existing }

        var merged: [DeviceTrack] = []
        merged.reserveCapacity(existing.count + fresh.count)
        var lhs = 0
        var rhs = 0
        while lhs < existing.count && rhs < fresh.count {
            let ascending = existing[lhs].title
                .localizedCaseInsensitiveCompare(fresh[rhs].title) != .orderedDescending
            merged.append(ascending ? existing[lhs] : fresh[rhs])
            if ascending { lhs += 1 } else { rhs += 1 }
        }
        merged.append(contentsOf: existing[lhs...])
        merged.append(contentsOf: fresh[rhs...])
        return merged
    }

    /// Enrich titles / duration / artwork with timeouts. Safe to call after quickTracks.
    func enrich(volumeRoot: URL, files: [URL]) async -> [DeviceTrack] {
        await withTaskGroup(of: DeviceTrack?.self, returning: [DeviceTrack].self) { group in
            var iterator = files.makeIterator()
            var inFlight = 0
            var tracks: [DeviceTrack] = []

            func enqueueNext() {
                while inFlight < maxConcurrentLoads, let file = iterator.next() {
                    inFlight += 1
                    group.addTask {
                        await self.loadTrack(fileURL: file, volumeRoot: volumeRoot)
                    }
                }
            }

            enqueueNext()
            for await track in group {
                inFlight -= 1
                if let track { tracks.append(track) }
                enqueueNext()
            }

            return tracks.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private func loadTrack(fileURL: URL, volumeRoot: URL) async -> DeviceTrack? {
        let relative = VolumePaths.relativePath(of: fileURL, under: volumeRoot)
        var fileSize: Int64 = 0
        var modified = Date.distantPast
        if let values = try? fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ]) {
            fileSize = Int64(values.fileSize ?? 0)
            modified = values.contentModificationDate ?? .distantPast
        }

        let enriched = await withTimeout(seconds: 1.5) {
            Optional(await self.loadTextMetadata(fileURL: fileURL))
        }
        let artworkData = await withTimeout(seconds: 1.0) {
            await self.loadArtworkData(fileURL: fileURL)
        }
        let artwork = artworkData.flatMap { NSImage(data: $0) }
        let title = TrackFileNaming.displayTitle(
            fileName: fileURL.lastPathComponent,
            metadataTitle: enriched?.title
        )

        let identity = relative
        return DeviceTrack(
            id: identity,
            url: fileURL,
            relativePath: relative,
            fileName: fileURL.lastPathComponent,
            title: title,
            artist: enriched?.artist,
            duration: enriched?.duration,
            fileSize: fileSize,
            modifiedAt: modified,
            artwork: artwork
        )
    }

    private struct TextMetadata: Sendable {
        let title: String?
        let artist: String?
        let duration: TimeInterval?
    }

    private func loadTextMetadata(fileURL: URL) async -> TextMetadata {
        let asset = AVURLAsset(url: fileURL)
        let title = await metadataString(asset: asset, key: .commonKeyTitle)
        let artist = await metadataString(asset: asset, key: .commonKeyArtist)
        let durationSeconds = try? await asset.load(.duration).seconds
        let duration = (durationSeconds?.isFinite == true) ? durationSeconds : nil
        return TextMetadata(title: title, artist: artist, duration: duration)
    }

    private func metadataString(asset: AVURLAsset, key: AVMetadataKey) async -> String? {
        do {
            let items = try await asset.load(.metadata)
            for item in items {
                guard item.commonKey == key else { continue }
                if let value = try await item.load(.stringValue), !value.isEmpty {
                    return value
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func loadArtworkData(fileURL: URL) async -> Data? {
        let asset = AVURLAsset(url: fileURL)
        do {
            let items = try await asset.load(.metadata)
            for item in items {
                guard item.commonKey == .commonKeyArtwork else { continue }
                if let data = try await item.load(.dataValue) {
                    return data
                }
            }
        } catch {
            // fall through to sidecar
        }

        let jpg = fileURL.deletingPathExtension().appendingPathExtension("jpg")
        if let data = try? Data(contentsOf: jpg) { return data }
        let png = fileURL.deletingPathExtension().appendingPathExtension("png")
        if let data = try? Data(contentsOf: png) { return data }
        return nil
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            if let result = await group.next() {
                group.cancelAll()
                return result
            }
            group.cancelAll()
            return nil
        }
    }
}
