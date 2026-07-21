import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Embeds cover art directly into the audio file's metadata — no sidecar files.
///
/// Per the ID3 conventions hardware players expect
/// (richardfarrar.com/embedding-album-art-in-mp3-files): JPEG front cover,
/// ~300px, and ID3v2.3 for MP3s — many devices ignore ffmpeg's default v2.4.
/// M4A covers land in the `covr` atom automatically via `attached_pic`.
enum ArtworkEmbedder {
    private static let timeoutSeconds: TimeInterval = 20
    /// Industry-standard cover size: compatibility and small footprint.
    private static let maxCoverPixels = 300

    /// Embed the given artwork (and optionally a title tag) into the audio file.
    /// No-ops when there is nothing to write. Never blocks forever.
    static func embed(artwork: Data?, into audioURL: URL, title: String? = nil) throws {
        let cleanTitle = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let cover = artwork.flatMap(normalizedCover)
        guard cover != nil || cleanTitle != nil else { return }

        // ffmpeg needs a file input; keep the intermediate in our own temp dir,
        // never next to the audio.
        var coverFile: URL?
        if let cover {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cover-\(UUID().uuidString).jpg")
            try cover.write(to: url)
            coverFile = url
        }
        defer {
            if let coverFile {
                try? FileManager.default.removeItem(at: coverFile)
            }
        }

        let ffmpeg = try BundledBinaries.ffmpegURL
        let ext = audioURL.pathExtension.lowercased()
        let temp = audioURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(ext)")

        defer { try? FileManager.default.removeItem(at: temp) }

        var args = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", audioURL.path
        ]
        if let coverFile {
            args += ["-i", coverFile.path]
            args += [
                "-map", "0:a:0",
                "-map", "1:v:0",
                "-c", "copy",
                "-disposition:v:0", "attached_pic",
                "-shortest"
            ]
            // Mark the APIC frame as the front cover.
            args += [
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)"
            ]
        } else {
            args += ["-map", "0:a:0", "-c", "copy"]
        }
        if ext == "mp3" {
            // Hardware players commonly read only ID3v2.3.
            args += ["-id3v2_version", "3"]
        }
        if let cleanTitle {
            args += ["-metadata", "title=\(cleanTitle)"]
        }
        args.append(temp.path)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args
        // Critical: never attach unread Pipes — ffmpeg fills them and deadlocks.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            return
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: temp.path)
        else {
            return
        }

        _ = try FileManager.default.replaceItemAt(audioURL, withItemAt: temp)
    }

    /// Downscale to the ~300px cover standard and re-encode as JPEG.
    static func normalizedCover(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxCoverPixels,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
