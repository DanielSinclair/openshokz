import Foundation
import Testing
@testable import OpenShokz

@Suite("Add URL controls")
struct AddURLControlsTests {
    @Test("send stays visible even while preview loads and when empty")
    func sendAlwaysVisible() {
        let url = "https://www.youtube.com/watch?v=Vyyrvna-hUY"
        #expect(AddURLControls.shouldShowSendButton(urlText: url, isLoadingPreview: false))
        #expect(AddURLControls.shouldShowSendButton(urlText: url, isLoadingPreview: true))
        #expect(AddURLControls.shouldShowSendButton(urlText: "", isLoadingPreview: true))
        #expect(AddURLControls.shouldShowSendButton(urlText: "   ", isLoadingPreview: false))
    }

    @Test("send enabled only for non-empty URL when connected")
    func sendEnabledRules() {
        let url = "https://www.youtube.com/watch?v=Vyyrvna-hUY"
        #expect(AddURLControls.isSendEnabled(urlText: url, isConnected: true))
        #expect(!AddURLControls.isSendEnabled(urlText: url, isConnected: false))
        #expect(!AddURLControls.isSendEnabled(urlText: "", isConnected: true))
        #expect(!AddURLControls.isSendEnabled(urlText: "   ", isConnected: true))
    }

    @Test("add bar dismisses via Esc or submit only — no × button")
    func noCloseButtonWhenOpen() {
        #expect(!AddURLControls.showsCloseButtonWhenOpen())
    }
}

@Suite("Media URL resolver")
struct MediaURLResolverTests {
    @Test("normalizes the watch URL that failed in preview")
    func normalizesWatchURL() throws {
        let raw = "https://www.youtube.com/watch?v=Vyyrvna-hUY"
        let url = try #require(MediaURLResolver.normalize(raw))
        #expect(url.scheme == "https")
        #expect(url.host == "www.youtube.com")
        #expect(url.path == "/watch")
        #expect(url.query == "v=Vyyrvna-hUY")
        #expect(url.absoluteString == raw)
    }

    @Test("trims whitespace and adds https when missing")
    func trimsAndAddsScheme() throws {
        let url = try #require(
            MediaURLResolver.normalize("  www.youtube.com/watch?v=Vyyrvna-hUY  ")
        )
        #expect(url.absoluteString == "https://www.youtube.com/watch?v=Vyyrvna-hUY")
    }

    @Test("rejects empty input")
    func rejectsEmpty() {
        #expect(MediaURLResolver.normalize("") == nil)
        #expect(MediaURLResolver.normalize("   ") == nil)
    }

    @Test("extracts video id from watch, short, and shorts URLs")
    func extractsVideoID() throws {
        let watch = try #require(
            MediaURLResolver.normalize("https://www.youtube.com/watch?v=Vyyrvna-hUY")
        )
        #expect(MediaURLResolver.videoID(from: watch) == "Vyyrvna-hUY")

        let short = try #require(
            MediaURLResolver.normalize("https://youtu.be/Vyyrvna-hUY")
        )
        #expect(MediaURLResolver.videoID(from: short) == "Vyyrvna-hUY")

        let shorts = try #require(
            MediaURLResolver.normalize("https://www.youtube.com/shorts/Vyyrvna-hUY")
        )
        #expect(MediaURLResolver.videoID(from: shorts) == "Vyyrvna-hUY")
    }

    @Test("extracts video id even when a playlist rides along")
    func extractsFromPlaylistURLs() throws {
        let listed = try #require(MediaURLResolver.normalize(
            "https://www.youtube.com/watch?v=Vyyrvna-hUY&list=PL0uinTrqrVL6&index=2&t=17s"
        ))
        #expect(MediaURLResolver.videoID(from: listed) == "Vyyrvna-hUY")

        let shortListed = try #require(MediaURLResolver.normalize(
            "https://youtu.be/Vyyrvna-hUY?list=PL0uinTrqrVL6"
        ))
        #expect(MediaURLResolver.videoID(from: shortListed) == "Vyyrvna-hUY")
    }
}

@Suite("Track deduper")
struct TrackDeduperTests {
    @Test("collects ids from OpenShokz filenames")
    func collectsFromFileNames() {
        let ids = TrackDeduper.videoIDs(inFileNames: [
            "Song Title [Vyyrvna-hUY].m4a",
            "Other [dQw4w9WgXcQ].m4a",
            "no-id-here.m4a"
        ])
        #expect(ids == Set(["Vyyrvna-hUY", "dQw4w9WgXcQ"]))
    }

    @Test("duplicate detection requires a known id")
    func duplicateRules() {
        let existing: Set<String> = ["Vyyrvna-hUY"]
        #expect(TrackDeduper.isDuplicate(videoID: "Vyyrvna-hUY", existingIDs: existing))
        #expect(!TrackDeduper.isDuplicate(videoID: "dQw4w9WgXcQ", existingIDs: existing))
        #expect(!TrackDeduper.isDuplicate(videoID: nil, existingIDs: existing))
        #expect(!TrackDeduper.isDuplicate(videoID: "", existingIDs: existing))
    }
}

@Suite("Link support policy")
struct LinkSupportPolicyTests {
    private func classify(_ raw: String) -> LinkSupportPolicy.Link {
        LinkSupportPolicy.classify(URL(string: raw)!)
    }

    @Test("video links classify with their id")
    func videoLinks() {
        #expect(classify("https://www.youtube.com/watch?v=Vyyrvna-hUY") == .video(id: "Vyyrvna-hUY"))
        #expect(classify("https://youtu.be/Vyyrvna-hUY?list=PL0uinTrqrVL6") == .video(id: "Vyyrvna-hUY"))
    }

    @Test("playlist-only links are rejected with a clear reason")
    func playlistOnly() {
        guard case .unsupported(let reason) =
            classify("https://www.youtube.com/playlist?list=PL0uinTrqrVL6") else {
            Issue.record("expected unsupported")
            return
        }
        #expect(reason.contains("specific video"))
    }

    @Test("Apple Podcasts episode links carry show and episode ids")
    func applePodcastLinks() {
        #expect(
            classify("https://podcasts.apple.com/us/podcast/acquired/id1050462261?i=1000715999288")
                == .applePodcast(showID: 1050462261, episodeID: 1000715999288)
        )
        #expect(
            classify("https://podcasts.apple.com/us/podcast/acquired/id1050462261")
                == .applePodcast(showID: 1050462261, episodeID: nil)
        )
    }

    @Test("Spotify episode links carry the episode id")
    func spotifyLinks() {
        #expect(
            classify("https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk?si=abc")
                == .spotifyEpisode(id: "4rOoJ6Egrf8K2IrywzwOMk")
        )
        guard case .unsupported = classify("https://open.spotify.com/show/4rOoJ6Egrf8K2Irywzw") else {
            Issue.record("show links need an episode")
            return
        }
    }

    @Test("known podcast client share pages are accepted")
    func clientEpisodePages() {
        #expect(classify("https://overcast.fm/+AAAA_bcdEfg") == .clientEpisodePage(host: "overcast.fm"))
        #expect(classify("https://pca.st/episode/abcdef12") == .clientEpisodePage(host: "pca.st"))
        #expect(classify("https://castro.fm/episode/abcdef") == .clientEpisodePage(host: "castro.fm"))
    }

    @Test("direct media files route to the transform pipeline")
    func directMedia() {
        #expect(classify("https://example.com/episodes/show.mp3") == .directMedia)
        #expect(classify("https://example.com/talks/keynote.mp4?dl=1") == .directMedia)
        #expect(classify("https://example.com/raw/audio.flac") == .directMedia)
    }

    @Test("feeds are rejected asking for an episode link")
    func feedsRejected() {
        for raw in [
            "https://example.com/podcast/feed.xml",
            "https://example.com/rss/show",
            "https://feeds.megaphone.fm/feed"
        ] {
            guard case .unsupported(let reason) = classify(raw) else {
                Issue.record("expected unsupported for \(raw)")
                continue
            }
            #expect(reason.contains("episode link"))
        }
    }

    @Test("unknown links fail with the generic guidance message")
    func genericRejection() {
        guard case .unsupported(let reason) = classify("https://example.com/some/page") else {
            Issue.record("expected unsupported")
            return
        }
        #expect(reason == LinkSupportPolicy.genericUnsupportedMessage)
    }
}

@Suite("Download draft clearing")
@MainActor
struct DownloadDraftClearTests {
    @Test("clearURLDraft wipes urlText preview and errors")
    func clearURLDraftResetsFieldState() async {
        let service = DownloadService()
        service.setURLText("https://www.youtube.com/watch?v=Vyyrvna-hUY")
        #expect(service.urlText.contains("Vyyrvna-hUY"))
        service.clearURLDraft()
        #expect(service.urlText.isEmpty)
        #expect(service.preview == nil)
        #expect(service.lastError == nil)
        #expect(service.isLoadingPreview == false)
    }

    @Test("setURLText does not restore after clearURLDraft")
    func noStaleRestoreAfterClear() {
        let service = DownloadService()
        service.setURLText("https://www.youtube.com/watch?v=Vyyrvna-hUY")
        service.clearURLDraft()
        #expect(service.urlText.isEmpty)
        // Opening a fresh session must not see the prior draft.
        #expect(MediaURLResolver.normalize(service.urlText) == nil)
    }
}
