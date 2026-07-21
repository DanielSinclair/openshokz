import FeedKit
import Foundation

/// A podcast episode resolved to a directly downloadable enclosure.
struct ResolvedEpisode: Sendable, Equatable {
    var audioURL: URL
    var title: String
    var showTitle: String?
    var duration: TimeInterval?
    var artworkURL: URL?
    /// Stable id for naming/dedupe: `p<trackId>` or a URL hash.
    var mediaID: String
}

enum PodcastResolverError: LocalizedError {
    case episodeNotFound
    case noPublicFeed(String)
    case pageParseFailed(String)

    var errorDescription: String? {
        switch self {
        case .episodeNotFound:
            return "Couldn’t find that episode in the show’s public feed."
        case .noPublicFeed(let show):
            return "“\(show)” has no public feed — it may be a platform exclusive."
        case .pageParseFailed(let host):
            return "Couldn’t read the episode from \(host) — try the episode’s Apple Podcasts link instead."
        }
    }
}

/// Deterministic podcast episode resolution: Apple's no-auth lookup APIs,
/// Spotify's official oEmbed + Apple cross-match, and per-client share-page
/// parsers. No generic scraping.
struct PodcastResolver: Sendable {
    var session: URLSession = .shared

    // MARK: - Apple Podcasts

    /// One lookup call returns the show's feed and every recent episode with
    /// its enclosure (`episodeUrl`) — usually no feed parse needed.
    func resolveApplePodcast(showID: Int, episodeID: Int?) async throws -> ResolvedEpisode {
        let lookup = try await appleLookup(showID: showID)
        let episodes = lookup.episodes

        if let episodeID {
            if let hit = episodes.first(where: { $0.trackId == episodeID }) {
                return try resolved(from: hit, show: lookup.show)
            }
            // Older than the lookup window: fall back to the feed by GUID.
            if let feedURL = lookup.show?.feedUrl.flatMap(URL.init(string:)) {
                return try await resolveFromFeed(
                    feedURL: feedURL,
                    episodeID: episodeID,
                    lookupGuid: nil,
                    show: lookup.show
                )
            }
            throw PodcastResolverError.episodeNotFound
        }

        guard let latest = episodes.max(by: { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }) else {
            throw PodcastResolverError.episodeNotFound
        }
        return try resolved(from: latest, show: lookup.show)
    }

    // MARK: - Spotify (official oEmbed → Apple cross-match)

    func resolveSpotifyEpisode(id: String) async throws -> ResolvedEpisode {
        struct OEmbed: Decodable {
            var title: String?
            var provider_name: String?
        }
        var request = URLRequest(
            url: URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/episode/\(id)")!
        )
        request.timeoutInterval = 15
        let (data, _) = try await session.data(for: request)
        let embed = try JSONDecoder().decode(OEmbed.self, from: data)
        guard let episodeTitle = embed.title, !episodeTitle.isEmpty else {
            throw PodcastResolverError.episodeNotFound
        }

        // Search Apple's catalog for an episode with this exact (normalized)
        // title. Episode titles are distinctive enough for an exact match.
        let query = episodeTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? episodeTitle
        let searchURL = URL(string: "https://itunes.apple.com/search?term=\(query)&media=podcast&entity=podcastEpisode&limit=25")!
        let (searchData, _) = try await session.data(from: searchURL)
        let results = try JSONDecoder().decode(AppleResults.self, from: searchData).results

        let wanted = Self.normalized(episodeTitle)
        guard let hit = results.first(where: {
            $0.wrapperType == "podcastEpisode" && Self.normalized($0.trackName ?? "") == wanted
        }) else {
            throw PodcastResolverError.noPublicFeed(episodeTitle)
        }
        return try resolved(from: hit, show: nil)
    }

    // MARK: - Client share pages (per-host, deterministic)

    /// Overcast/Castro/Pocket Casts/etc. episode pages carry the enclosure
    /// (or Apple ids) in their static HTML. Each host is an explicit,
    /// fixture-tested extraction — failures surface as clear errors.
    func resolveEpisodePage(url: URL) async throws -> ResolvedEpisode {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw PodcastResolverError.pageParseFailed(url.host ?? "the page")
        }

        // Apple id handoff (many pages deep-link podcasts.apple.com).
        if let appleURL = Self.firstMatch(
            in: html,
            pattern: #"https://podcasts\.apple\.com/[^"'\s]+\?i=\d+"#
        ).flatMap(URL.init(string:)),
            let showID = LinkSupportPolicy.applePodcastShowID(from: appleURL) {
            return try await resolveApplePodcast(
                showID: showID,
                episodeID: LinkSupportPolicy.applePodcastEpisodeID(from: appleURL)
            )
        }

        // Direct enclosure in the page (og:audio, <audio src>, or a bare URL).
        let enclosurePatterns = [
            #"property="og:audio(?::secure_url)?" content="([^"]+)""#,
            #"<audio[^>]+src="([^"]+)""#,
            #"<source[^>]+src="([^"]+\.mp3[^"]*)""#,
            #""(https://[^"]+\.mp3(?:\?[^"]*)?)""#,
        ]
        for pattern in enclosurePatterns {
            if let raw = Self.firstMatch(in: html, pattern: pattern, group: 1),
               let audio = URL(string: raw.replacingOccurrences(of: "&amp;", with: "&")) {
                let title = Self.firstMatch(
                    in: html,
                    pattern: #"property="og:title" content="([^"]+)""#,
                    group: 1
                ) ?? url.lastPathComponent
                let artwork = Self.firstMatch(
                    in: html,
                    pattern: #"property="og:image" content="([^"]+)""#,
                    group: 1
                ).flatMap(URL.init(string:))
                return ResolvedEpisode(
                    audioURL: audio,
                    title: Self.decodeHTMLEntities(title),
                    showTitle: nil,
                    duration: nil,
                    artworkURL: artwork,
                    mediaID: Self.hashID(for: audio)
                )
            }
        }
        throw PodcastResolverError.pageParseFailed(url.host ?? "the page")
    }

    // MARK: - Apple lookup plumbing

    struct AppleItem: Decodable, Sendable {
        var wrapperType: String?
        var kind: String?
        var trackId: Int?
        var trackName: String?
        var collectionName: String?
        var feedUrl: String?
        var episodeUrl: String?
        var episodeGuid: String?
        var trackTimeMillis: Int?
        var artworkUrl600: String?
        var releaseDate: String?
    }

    struct AppleResults: Decodable, Sendable {
        var results: [AppleItem]
    }

    private func appleLookup(showID: Int) async throws -> (show: AppleItem?, episodes: [AppleItem]) {
        let url = URL(string: "https://itunes.apple.com/lookup?id=\(showID)&entity=podcastEpisode&limit=300")!
        let (data, _) = try await session.data(from: url)
        let items = try JSONDecoder().decode(AppleResults.self, from: data).results
        let show = items.first(where: { $0.wrapperType == "track" || $0.feedUrl != nil })
        let episodes = items.filter { $0.wrapperType == "podcastEpisode" }
        return (show, episodes)
    }

    private func resolved(from item: AppleItem, show: AppleItem?) throws -> ResolvedEpisode {
        guard let raw = item.episodeUrl, let audio = URL(string: raw) else {
            throw PodcastResolverError.episodeNotFound
        }
        return ResolvedEpisode(
            audioURL: audio,
            title: item.trackName ?? "Episode",
            showTitle: item.collectionName ?? show?.collectionName,
            duration: item.trackTimeMillis.map { TimeInterval($0) / 1000 },
            artworkURL: item.artworkUrl600.flatMap(URL.init(string:)),
            mediaID: item.trackId.map { "p\($0)" } ?? Self.hashID(for: audio)
        )
    }

    private func resolveFromFeed(
        feedURL: URL,
        episodeID: Int?,
        lookupGuid: String?,
        show: AppleItem?
    ) async throws -> ResolvedEpisode {
        let (data, _) = try await session.data(from: feedURL)
        guard case .success(.rss(let rss)) = FeedParser(data: data).parse(),
              let items = rss.items
        else {
            throw PodcastResolverError.episodeNotFound
        }
        // Without a GUID from the lookup, an old episode id cannot be safely
        // matched in the feed — surface that honestly.
        guard let lookupGuid else { throw PodcastResolverError.episodeNotFound }
        guard let item = items.first(where: { $0.guid?.value == lookupGuid }),
              let enclosure = item.enclosure?.attributes?.url,
              let audio = URL(string: enclosure)
        else {
            throw PodcastResolverError.episodeNotFound
        }
        return ResolvedEpisode(
            audioURL: audio,
            title: item.title ?? "Episode",
            showTitle: rss.title ?? show?.collectionName,
            duration: item.iTunes?.iTunesDuration,
            artworkURL: (item.iTunes?.iTunesImage?.attributes?.href ?? rss.iTunes?.iTunesImage?.attributes?.href)
                .flatMap(URL.init(string:)),
            mediaID: episodeID.map { "p\($0)" } ?? Self.hashID(for: audio)
        )
    }

    // MARK: - Helpers

    static func normalized(_ title: String) -> String {
        title.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func hashID(for url: URL) -> String {
        // Stable 12-char id derived from the enclosure URL.
        var hash: UInt64 = 5381
        for byte in url.absoluteString.utf8 {
            hash = (hash << 5) &+ hash &+ UInt64(byte)
        }
        return "u" + String(hash, radix: 36)
    }

    static func firstMatch(in text: String, pattern: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
