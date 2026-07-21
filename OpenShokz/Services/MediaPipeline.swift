import AVFoundation
import Foundation
import YouTubeKit

enum MediaPipelineError: LocalizedError {
    case unsupported(String)
    case noAudioStream
    case downloadFailed(String)
    case transcodeFailed

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        case .noAudioStream: return "No downloadable audio found for that link."
        case .downloadFailed(let message): return message
        case .transcodeFailed: return "Converting the audio failed."
        }
    }
}

/// Resolved media source before download and transcode.
private struct MediaSource {
    let mediaURL: URL
    let title: String
    let mediaID: String
    let artworkURL: URL?
}

/// Native replacement for the external downloader: in-process extraction
/// (video links + podcast episode links + direct media files), URLSession
/// downloads into container staging, then ffmpeg transcodes everything to the
/// canonical mp3 with ID3v2.3 tags and cover art. Fully sandbox-clean.
actor MediaPipeline: AudioDownloadClient {
    private let podcasts = PodcastResolver()
    private var activeDownload: URLSessionDownloadTask?
    private var cancelled = false

    // MARK: - Metadata (preview)

    func fetchMetadata(for url: URL) async throws -> RemoteVideoInfo {
        switch LinkSupportPolicy.classify(url) {
        case .unsupported(let reason):
            throw MediaPipelineError.unsupported(reason)

        case .video(let id):
            let video = YouTube(videoID: id, methods: [.local, .remote])
            let metadata = try? await video.metadata
            return RemoteVideoInfo(
                url: url,
                videoID: id,
                title: metadata?.title ?? "Video \(id)",
                duration: nil,
                thumbnailURL: metadata?.thumbnail?.url
                    ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"),
                isPlaylist: false,
                playlistCount: nil
            )

        case .applePodcast(let showID, let episodeID):
            let episode = try await podcasts.resolveApplePodcast(showID: showID, episodeID: episodeID)
            return info(for: episode, sourceURL: url)

        case .spotifyEpisode(let id):
            let episode = try await podcasts.resolveSpotifyEpisode(id: id)
            return info(for: episode, sourceURL: url)

        case .clientEpisodePage:
            let episode = try await podcasts.resolveEpisodePage(url: url)
            return info(for: episode, sourceURL: url)

        case .directMedia:
            let stem = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            return RemoteVideoInfo(
                url: url,
                videoID: PodcastResolver.hashID(for: url),
                title: stem.isEmpty ? "Audio" : stem,
                duration: nil,
                thumbnailURL: nil,
                isPlaylist: false,
                playlistCount: nil
            )
        }
    }

    // MARK: - Download

    func downloadAudio(
        url: URL,
        to directory: URL,
        allowPlaylist: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        cancelled = false
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let source: MediaSource
        switch LinkSupportPolicy.classify(url) {
        case .unsupported(let reason):
            throw MediaPipelineError.unsupported(reason)

        case .video(let id):
            let video = YouTube(videoID: id, methods: [.local, .remote])
            let streams = try await video.streams
            // Smallest device-friendly download: prefer the AAC/m4a audio-only
            // stream (remuxes with no re-encode), then any audio-only, then a
            // low-res (~360p) progressive stream. Higher quality is wasted on
            // swim headphones and only slows the download.
            let stream = streams
                .filterAudioOnly()
                .filter { $0.fileExtension == .m4a }
                .highestAudioBitrateStream()
                ?? streams.filterAudioOnly().highestAudioBitrateStream()
                ?? streams.filter { $0.isProgressive && $0.fileExtension == .mp4 }.lowestResolutionStream()
                ?? streams.filterVideoAndAudio().lowestResolutionStream()
            guard let stream else { throw MediaPipelineError.noAudioStream }
            let metadata = try? await video.metadata
            source = MediaSource(
                mediaURL: stream.url,
                title: metadata?.title ?? "Video \(id)",
                mediaID: id,
                artworkURL: metadata?.thumbnail?.url ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
            )

        case .applePodcast(let showID, let episodeID):
            let episode = try await podcasts.resolveApplePodcast(showID: showID, episodeID: episodeID)
            source = MediaSource(
                mediaURL: episode.audioURL,
                title: episode.title,
                mediaID: episode.mediaID,
                artworkURL: episode.artworkURL
            )

        case .spotifyEpisode(let id):
            let episode = try await podcasts.resolveSpotifyEpisode(id: id)
            source = MediaSource(
                mediaURL: episode.audioURL,
                title: episode.title,
                mediaID: episode.mediaID,
                artworkURL: episode.artworkURL
            )

        case .clientEpisodePage:
            let episode = try await podcasts.resolveEpisodePage(url: url)
            source = MediaSource(
                mediaURL: episode.audioURL,
                title: episode.title,
                mediaID: episode.mediaID,
                artworkURL: episode.artworkURL
            )

        case .directMedia:
            let stem = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            source = MediaSource(
                mediaURL: url,
                title: stem.isEmpty ? "Audio" : stem,
                mediaID: PodcastResolver.hashID(for: url),
                artworkURL: nil
            )
        }

        // 1. Download the source media into staging (0 → 0.75).
        let rawFile = directory.appendingPathComponent(
            "source-\(UUID().uuidString).\(source.mediaURL.pathExtension.isEmpty ? "bin" : source.mediaURL.pathExtension)"
        )
        try await download(from: source.mediaURL, to: rawFile) { fraction in
            onProgress(fraction * 0.75)
        }
        guard !cancelled else { throw CancellationError() }

        // 2. Pick the cheapest device-playable packaging, and fetch the cover
        //    first so it rides into the file in the same single ffmpeg pass.
        onProgress(0.78)
        let format = Self.deviceFormat(forRaw: rawFile)
        let output = directory.appendingPathComponent(
            TrackFileNaming.fileName(title: source.title, mediaID: source.mediaID, ext: format.ext)
        )
        var coverFile: URL?
        if let artworkURL = source.artworkURL,
           let raw = try? await downloadData(from: artworkURL),
           let cover = ArtworkEmbedder.normalizedCover(raw) {
            // Staging-only sidecar: seeds the library cache, never leaves staging.
            let sidecar = output.deletingPathExtension().appendingPathExtension("jpg")
            try? cover.write(to: sidecar)
            coverFile = sidecar
        }
        guard !cancelled else { throw CancellationError() }

        // 3. A single ffmpeg pass: remux (no re-encode) when the source is
        //    already device-playable, otherwise transcode to MP3 — with the
        //    cover art and ID3v2.3 title applied in the same pass.
        onProgress(0.82)
        try Self.package(
            input: rawFile,
            output: output,
            title: source.title,
            coverFile: coverFile,
            reencode: format.reencode
        )
        try? FileManager.default.removeItem(at: rawFile)
        onProgress(1.0)

        return [output]
    }

    func cancel() async {
        cancelled = true
        activeDownload?.cancel()
        activeDownload = nil
    }

    // MARK: - Internals

    private func info(for episode: ResolvedEpisode, sourceURL: URL) -> RemoteVideoInfo {
        RemoteVideoInfo(
            url: sourceURL,
            videoID: episode.mediaID,
            title: episode.title,
            duration: episode.duration,
            thumbnailURL: episode.artworkURL,
            isPlaylist: false,
            playlistCount: nil
        )
    }

    private func download(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")

        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (temp, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MediaPipelineError.downloadFailed("Download failed (HTTP \(http.statusCode)).")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    private func downloadData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    /// Cheapest device-playable packaging for the downloaded audio. Shokz
    /// OpenSwim / OpenSwim Pro play MP3, AAC/M4A, FLAC, and WAV directly, so
    /// those are remuxed with no re-encode; anything else (Opus, Vorbis, WMA,
    /// APE, a video container, or an unknown codec) transcodes to MP3.
    static func deviceFormat(forRaw url: URL) -> (ext: String, reencode: Bool) {
        guard let probe = probeAudio(url) else { return ("mp3", true) }
        if probe.hasForeignVideo { return ("mp3", true) }
        switch probe.codec {
        case "mp3": return ("mp3", false)
        case "aac": return ("m4a", false)
        case "flac": return ("flac", false)
        case "pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_u8": return ("wav", false)
        default: return ("mp3", true)
        }
    }

    /// Reads the audio codec (and whether a real video stream is present) by
    /// parsing `ffmpeg -i` stderr — no ffprobe needed. stderr is drained before
    /// waiting so the pipe can't deadlock.
    static func probeAudio(_ url: URL) -> (codec: String, hasForeignVideo: Bool)? {
        guard let ffmpeg = try? BundledBinaries.ffmpegURL else { return nil }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-i", url.path]
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do { try process.run() } catch { return nil }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var codec: String?
        var hasForeignVideo = false
        for line in text.split(separator: "\n") {
            if codec == nil, let range = line.range(of: "Audio: ") {
                codec = String(line[range.upperBound...])
                    .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    .lowercased()
            }
            if line.contains("Video:") && !line.contains("attached pic") {
                hasForeignVideo = true
            }
        }
        guard let codec, !codec.isEmpty else { return nil }
        return (codec, hasForeignVideo)
    }

    /// One ffmpeg pass: remux (`reencode == false`) or encode to MP3, attaching
    /// the front cover and an ID3v2.3 title in the same invocation.
    private static func package(
        input: URL,
        output: URL,
        title: String,
        coverFile: URL?,
        reencode: Bool
    ) throws {
        let ffmpeg = try BundledBinaries.ffmpegURL
        let ext = output.pathExtension.lowercased()
        // Cover art only rides in containers hardware players read it from.
        let withCover = coverFile != nil && (ext == "mp3" || ext == "m4a")

        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path]
        if withCover, let coverFile {
            args += ["-i", coverFile.path, "-map", "0:a:0", "-map", "1:v:0"]
        } else {
            args += ["-map", "0:a:0"]
        }
        if reencode {
            args += ["-c:a", "libmp3lame", "-b:a", "192k"]
            if withCover { args += ["-c:v", "copy", "-disposition:v:0", "attached_pic"] }
        } else {
            args += ["-c", "copy"]
            if withCover { args += ["-disposition:v:0", "attached_pic"] }
        }
        if ext == "mp3" { args += ["-id3v2_version", "3"] }
        args += ["-metadata", "title=\(title)"]
        if withCover {
            args += ["-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        }
        args.append(output.path)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: output.path)
        else {
            throw MediaPipelineError.transcodeFailed
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    // Block-based KVO: the token removes the observer on invalidate/dealloc,
    // so the Progress can never deallocate with a dangling manual observer.
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        didCreateTask task: URLSessionTask
    ) {
        let token = task.progress.observe(\.fractionCompleted, options: [.new]) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
        lock.lock()
        observation = token
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        invalidate()
    }

    deinit { invalidate() }

    private func invalidate() {
        lock.lock()
        observation?.invalidate()
        observation = nil
        lock.unlock()
    }
}
