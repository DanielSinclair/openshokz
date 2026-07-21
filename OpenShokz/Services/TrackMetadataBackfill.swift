import AppKit
import Foundation

/// Fetches remote title / duration / thumbnail for on-device files that lack metadata.
struct TrackMetadataBackfill: Sendable {
    var runner: any AudioDownloadClient
    var session: URLSession
    /// When true, best-effort sidecar/embed writes run in the background (never block UI).
    var writeToDisk: Bool

    init(
        runner: any AudioDownloadClient = MediaPipeline(),
        session: URLSession = .shared,
        writeToDisk: Bool = true
    ) {
        self.runner = runner
        self.session = session
        self.writeToDisk = writeToDisk
    }

    struct Result: Sendable {
        var track: DeviceTrack
        var videoID: String
        var remoteTitle: String?
        var remoteDuration: TimeInterval?
        var artworkJPEG: Data?
    }

    static func videoID(for track: DeviceTrack, knownID: String?) -> String? {
        if let knownID, !knownID.isEmpty { return knownID }
        return TrackFileNaming.parse(track.fileName).videoID
    }

    /// Backfill a single track. Returns `nil` when there is nothing to do or no media id.
    func backfill(
        track: DeviceTrack,
        knownVideoID: String?
    ) async -> Result? {
        guard track.needsRemoteMetadata else { return nil }
        guard let videoID = Self.videoID(for: track, knownID: knownVideoID),
              let sourceURL = TrackFileNaming.sourceURL(videoID: videoID)
        else {
            return nil
        }

        let fallbackThumb = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!

        // Thumbnail first (fast CDN) in parallel with remote metadata.
        async let thumbTask: Data? = track.artwork == nil
            ? downloadThumbnail(from: fallbackThumb)
            : nil
        async let infoTask: RemoteVideoInfo? = {
            try? await runner.fetchMetadata(for: sourceURL)
        }()

        let info = await infoTask
        var jpeg = await thumbTask

        if jpeg == nil, track.artwork == nil, let thumbURL = info?.thumbnailURL {
            jpeg = await downloadThumbnail(from: thumbURL)
        }
        if jpeg == nil, track.artwork == nil {
            // One more try: mqdefault / hqdefault already attempted; try maxres then hq.
            jpeg = await downloadThumbnail(
                from: URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")
            )
        }

        let remoteTitle = info?.title
        let remoteDuration = info?.duration

        if jpeg == nil,
           remoteDuration == nil,
           remoteTitle == nil {
            return nil
        }

        let artwork = jpeg.flatMap { NSImage(data: $0) } ?? track.artwork
        let displayTitle: String? = {
            guard let remoteTitle, !remoteTitle.isEmpty else { return nil }
            return TrackFileNaming.displayTitle(fileName: remoteTitle, metadataTitle: remoteTitle)
        }()
        let needsDuration = track.duration == nil || track.duration == 0

        let updated = track.updating(
            title: displayTitle,
            duration: needsDuration ? remoteDuration : nil,
            artwork: artwork
        )

        // Never await FAT writes — they hang on FSKit and block the UI from updating.
        if writeToDisk, jpeg != nil || remoteTitle != nil {
            let audioURL = track.url
            let title = remoteTitle
            let jpegData = jpeg
            Task.detached(priority: .utility) {
                await Self.persistToDiskBestEffort(
                    audioURL: audioURL,
                    jpeg: jpegData,
                    title: title
                )
            }
        }

        return Result(
            track: updated,
            videoID: videoID,
            remoteTitle: remoteTitle,
            remoteDuration: remoteDuration,
            artworkJPEG: jpeg
        )
    }

    private func downloadThumbnail(from url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                return nil
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    private static func persistToDiskBestEffort(
        audioURL: URL,
        jpeg: Data?,
        title: String?
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Task.detached(priority: .utility) {
                    // Cover art goes into the file's metadata — no sidecars.
                    try? ArtworkEmbedder.embed(artwork: jpeg, into: audioURL, title: title)
                }.value
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
