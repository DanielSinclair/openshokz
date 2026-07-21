import Foundation

/// Canonical on-disk naming shared by the pipeline and the library UI.
///
/// Format: `{title} [{mediaID}].{ext}`
/// Example: `Training Composer 2 [uTgqYeVxy2c].mp3`
enum TrackFileNaming {
    /// Media ids: 11-char video ids, `p<trackId>` episodes, or url hashes.
    private static let idPattern = #"^(.+?) \[([A-Za-z0-9_-]{6,24})\](?: \(\d+\))?$"#

    /// Builds the canonical mp3 file name for a downloaded track.
    static func fileName(title: String, mediaID: String, ext: String = "mp3") -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        var clean = title
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > 200 {
            clean = String(clean.prefix(200)).trimmingCharacters(in: .whitespaces)
        }
        if clean.isEmpty { clean = "Track" }
        return "\(clean) [\(mediaID)].\(ext)"
    }

    struct ParsedName: Equatable, Sendable {
        var title: String
        var videoID: String?
    }

    /// Parse a file name or stem into display title + optional media id.
    static func parse(_ fileNameOrStem: String) -> ParsedName {
        let stem = (fileNameOrStem as NSString).deletingPathExtension
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedName(title: fileNameOrStem, videoID: nil)
        }

        guard let regex = try? NSRegularExpression(pattern: idPattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              match.numberOfRanges == 3,
              let titleRange = Range(match.range(at: 1), in: trimmed),
              let idRange = Range(match.range(at: 2), in: trimmed)
        else {
            return ParsedName(title: trimmed, videoID: nil)
        }

        let title = String(trimmed[titleRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let videoID = String(trimmed[idRange])
        return ParsedName(
            title: title.isEmpty ? trimmed : title,
            videoID: videoID
        )
    }

    /// Prefer a clean display title: strip `[mediaID]` from our naming convention.
    /// Falls back to metadata only when the file name has no id suffix.
    static func displayTitle(fileName: String, metadataTitle: String?) -> String {
        let fromFile = parse(fileName)
        if fromFile.videoID != nil {
            return fromFile.title
        }

        if let metadataTitle {
            let fromMeta = parse(metadataTitle)
            if fromMeta.videoID != nil {
                return fromMeta.title
            }
            let clean = metadataTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                return clean
            }
        }

        return fromFile.title
    }

    /// Source page URL for an 11-character video id, if valid.
    static func sourceURL(videoID: String) -> URL? {
        let id = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count == 11,
              id.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
              })
        else {
            return nil
        }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    /// Resolve a source URL from our on-disk naming (and optional known id).
    static func sourceURL(fileName: String, knownVideoID: String? = nil) -> URL? {
        if let knownVideoID, let url = sourceURL(videoID: knownVideoID) {
            return url
        }
        guard let id = parse(fileName).videoID else { return nil }
        return sourceURL(videoID: id)
    }
}
