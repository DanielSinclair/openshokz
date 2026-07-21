import Foundation

/// Pure helpers for the add-URL bar (testable without SwiftUI).
enum AddURLControls {
    /// Send is always on-screen while the add bar is open — never gated on preview loading.
    static func shouldShowSendButton(urlText: String, isLoadingPreview: Bool = false) -> Bool {
        _ = urlText
        _ = isLoadingPreview
        return true
    }

    /// Enabled only with a non-empty URL and a connected device.
    static func isSendEnabled(urlText: String, isConnected: Bool) -> Bool {
        isConnected && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Add bar closes via Esc/submit only — never shows a × dismiss control.
    static func showsCloseButtonWhenOpen() -> Bool {
        false
    }
}

enum MediaURLResolver {
    static func normalize(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }

        if trimmed.contains("://") {
            return URL(string: trimmed)
        }

        return URL(string: "https://\(trimmed)")
    }

    /// Extracts an 11-character video id from common video URL shapes.
    static func videoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtu.be") {
            let id = url.path.split(separator: "/").first.map(String.init)
            return validatedID(id)
        }
        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "v" })?
                .value {
                return validatedID(v)
            }
            let parts = url.path.split(separator: "/").map(String.init)
            if let idx = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" || $0 == "live" }),
               parts.index(after: idx) < parts.endIndex {
                return validatedID(parts[parts.index(after: idx)])
            }
        }
        return nil
    }

    private static func validatedID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count == 11,
              id.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
              })
        else {
            return nil
        }
        return id
    }
}

/// Deduplicate by the media id embedded in our `{title} [{id}].ext` filenames.
enum TrackDeduper {
    static func videoIDs(inFileNames names: [String]) -> Set<String> {
        Set(names.compactMap { TrackFileNaming.parse($0).videoID })
    }

    static func isDuplicate(videoID: String?, existingIDs: Set<String>) -> Bool {
        guard let videoID, !videoID.isEmpty else { return false }
        return existingIDs.contains(videoID)
    }
}

/// Every link the add bar accepts, resolved deterministically — plus precise
/// reasons for everything it rejects. Pure and fully unit-tested.
enum LinkSupportPolicy {
    enum Link: Equatable, Sendable {
        /// An 11-char video id (watch/short/live/embed URL shapes).
        case video(id: String)
        /// podcasts.apple.com show link, optionally pinned to one episode.
        case applePodcast(showID: Int, episodeID: Int?)
        /// open.spotify.com/episode/<id> — resolved via oEmbed + Apple search.
        case spotifyEpisode(id: String)
        /// A podcast client's episode share page we know how to parse.
        case clientEpisodePage(host: String)
        /// A direct media file (audio or video container ffmpeg can demux).
        case directMedia
        case unsupported(reason: String)
    }

    /// Containers the transform pipeline accepts for direct links.
    static let mediaExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "m4b",
        "mp4", "mov", "m4v", "webm", "mkv", "avi",
    ]

    /// Podcast clients whose share pages deterministically carry the episode.
    static let episodePageHosts: Set<String> = [
        "overcast.fm", "pca.st", "castro.fm", "castbox.fm",
        "player.fm", "podbean.com", "iheart.com", "podcastaddict.com",
    ]

    private static let unsupportedHostHints: [String: String] = [
        "music.amazon.com": "Amazon Music episodes can’t be downloaded — paste the episode’s Apple Podcasts link instead.",
        "audible.com": "Audible content can’t be downloaded.",
        "soundcloud.com": "SoundCloud links aren’t supported yet.",
    ]

    static let genericUnsupportedMessage =
        "This link isn’t supported. Paste a video link, a podcast episode link (Apple Podcasts, Spotify, and most podcast apps), or a direct audio/video file URL."

    static func classify(_ url: URL) -> Link {
        let host = (url.host?.lowercased() ?? "").replacingOccurrences(of: "www.", with: "")

        if let id = MediaURLResolver.videoID(from: url) {
            return .video(id: id)
        }
        // A playlist link without a concrete video is not downloadable.
        if host.contains("youtube.com") || host.contains("youtu.be") {
            return .unsupported(reason: "Playlists aren’t supported — paste a specific video link.")
        }

        if host == "podcasts.apple.com" || host == "itunes.apple.com" {
            if let showID = applePodcastShowID(from: url) {
                return .applePodcast(showID: showID, episodeID: applePodcastEpisodeID(from: url))
            }
            return .unsupported(reason: "Couldn’t read that Apple Podcasts link — open the episode and copy its share link.")
        }

        if host == "open.spotify.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            if let idx = parts.firstIndex(of: "episode"), parts.index(after: idx) < parts.endIndex {
                return .spotifyEpisode(id: parts[parts.index(after: idx)])
            }
            return .unsupported(reason: "Only Spotify episode links are supported — open the episode and copy its share link.")
        }

        if episodePageHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return .clientEpisodePage(host: host)
        }

        if mediaExtensions.contains(url.pathExtension.lowercased()) {
            return .directMedia
        }

        // Feeds need an episode choice — ask for an episode link instead.
        let path = url.path.lowercased()
        if path.hasSuffix(".xml") || path.hasSuffix(".rss") || path.contains("/feed") || path.contains("/rss") {
            return .unsupported(reason: "That looks like a podcast feed — paste a specific episode link instead.")
        }

        if let hint = unsupportedHostHints.first(where: { host == $0.key || host.hasSuffix(".\($0.key)") }) {
            return .unsupported(reason: hint.value)
        }

        return .unsupported(reason: genericUnsupportedMessage)
    }

    static func applePodcastShowID(from url: URL) -> Int? {
        for part in url.path.split(separator: "/").reversed() where part.hasPrefix("id") {
            if let id = Int(part.dropFirst(2)) {
                return id
            }
        }
        return nil
    }

    static func applePodcastEpisodeID(from url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "i" })?
            .value
            .flatMap(Int.init)
    }
}
