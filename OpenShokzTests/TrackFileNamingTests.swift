import Foundation
import Testing
@testable import OpenShokz

@Suite("Track file naming")
struct TrackFileNamingTests {
    @Test("parses disk-style OpenSwim filenames")
    func parsesDiskNames() {
        let samples: [(String, String, String)] = [
            (
                "Training Composer 2 [uTgqYeVxy2c].mp3",
                "Training Composer 2",
                "uTgqYeVxy2c"
            ),
            (
                "Personalization in the Era of LLMs - Shivam Verma, Spotify [5YSJEP0HWzM].mp3",
                "Personalization in the Era of LLMs - Shivam Verma, Spotify",
                "5YSJEP0HWzM"
            ),
            (
                "State of AI in 2026： LLMs, Coding, Scaling Laws, China, Agents, GPUs, AGI ｜ Lex Fridman Podcast #490 [EV7WhVT270Q].mp3",
                "State of AI in 2026： LLMs, Coding, Scaling Laws, China, Agents, GPUs, AGI ｜ Lex Fridman Podcast #490",
                "EV7WhVT270Q"
            )
        ]
        for (fileName, title, id) in samples {
            let parsed = TrackFileNaming.parse(fileName)
            #expect(parsed.title == title)
            #expect(parsed.videoID == id)
            #expect(
                TrackFileNaming.displayTitle(fileName: fileName, metadataTitle: nil) == title
            )
        }
    }

    @Test("strips collision suffix from uniquified names")
    func stripsCollisionSuffix() {
        let parsed = TrackFileNaming.parse("Training Composer 2 [uTgqYeVxy2c] (2).m4a")
        #expect(parsed.title == "Training Composer 2")
        #expect(parsed.videoID == "uTgqYeVxy2c")
    }

    @Test("falls back to metadata when file has no id suffix")
    func metadataFallback() {
        #expect(
            TrackFileNaming.displayTitle(
                fileName: "podcast-episode.m4a",
                metadataTitle: "Clean Title"
            ) == "Clean Title"
        )
        #expect(
            TrackFileNaming.displayTitle(
                fileName: "podcast-episode.m4a",
                metadataTitle: "Dirty [uTgqYeVxy2c]"
            ) == "Dirty"
        )
    }

    @Test("builds canonical mp3 names and sanitizes titles")
    func buildsFileNames() {
        #expect(
            TrackFileNaming.fileName(title: "Training Composer 2", mediaID: "uTgqYeVxy2c")
                == "Training Composer 2 [uTgqYeVxy2c].mp3"
        )
        #expect(
            TrackFileNaming.fileName(title: "A/B: what?", mediaID: "p1000715999288")
                == "A-B- what- [p1000715999288].mp3"
        )
        let long = String(repeating: "x", count: 300)
        let name = TrackFileNaming.fileName(title: long, mediaID: "uTgqYeVxy2c")
        #expect(name.count <= 200 + " [uTgqYeVxy2c].mp3".count)
        #expect(
            TrackFileNaming.fileName(title: "   ", mediaID: "uTgqYeVxy2c")
                == "Track [uTgqYeVxy2c].mp3"
        )
    }

    @Test("round-trips podcast ids through parse")
    func parsesPodcastIDs() {
        let parsed = TrackFileNaming.parse("ACQ2: Costco [p1000715999288].mp3")
        #expect(parsed.title == "ACQ2: Costco")
        #expect(parsed.videoID == "p1000715999288")
    }

    @Test("builds source URLs from file names")
    func sourceURLFromFileName() {
        let url = TrackFileNaming.sourceURL(
            fileName: "Training Composer 2 [uTgqYeVxy2c].mp3"
        )
        #expect(url?.absoluteString == "https://www.youtube.com/watch?v=uTgqYeVxy2c")
        #expect(TrackFileNaming.sourceURL(fileName: "no-id.m4a") == nil)
        #expect(
            TrackFileNaming.sourceURL(fileName: "x.m4a", knownVideoID: "Vyyrvna-hUY")?
                .absoluteString == "https://www.youtube.com/watch?v=Vyyrvna-hUY"
        )
        // Podcast ids have no watch page — no source URL.
        #expect(TrackFileNaming.sourceURL(fileName: "Ep [p1000715999288].mp3") == nil)
    }
}

@Suite("Video duration format")
struct VideoDurationTests {
    @Test("formats minutes and hours")
    func formats() {
        #expect(VideoDuration.format(65) == "1:05")
        #expect(VideoDuration.format(1487) == "24:47")
        #expect(VideoDuration.format(3661) == "1:01:01")
    }
}
