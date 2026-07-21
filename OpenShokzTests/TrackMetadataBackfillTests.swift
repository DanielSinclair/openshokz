import AppKit
import Foundation
import Testing
@testable import OpenShokz

@Suite("Track metadata backfill")
struct TrackMetadataBackfillTests {
    @Test("detects tracks that need remote metadata")
    func needsRemoteMetadata() {
        let complete = DeviceTrack(
            id: "a",
            url: URL(fileURLWithPath: "/tmp/a.m4a"),
            relativePath: "a.m4a",
            fileName: "Song [Vyyrvna-hUY].m4a",
            title: "Song",
            artist: nil,
            duration: 120,
            fileSize: 1,
            modifiedAt: .now,
            artwork: nil
        )
        #expect(complete.needsRemoteMetadata) // no artwork

        let withArt = complete.updating(artwork: NSImage(size: NSSize(width: 1, height: 1)))
        #expect(!withArt.needsRemoteMetadata)

        let noDuration = withArt.updating(duration: nil)
        // updating(duration: nil) keeps existing duration because of `duration ?? self.duration`
        // Use a fresh track instead:
        let missingDuration = DeviceTrack(
            id: "b",
            url: URL(fileURLWithPath: "/tmp/b.m4a"),
            relativePath: "b.m4a",
            fileName: "Song [Vyyrvna-hUY].m4a",
            title: "Song",
            artist: nil,
            duration: nil,
            fileSize: 1,
            modifiedAt: .now,
            artwork: NSImage(size: NSSize(width: 1, height: 1))
        )
        #expect(missingDuration.needsRemoteMetadata)
    }

    @Test("backfill pulls duration and title from a mocked pipeline")
    @MainActor
    func backfillUsesMockMetadata() async throws {
        let url = try #require(URL(string: "https://www.youtube.com/watch?v=Vyyrvna-hUY"))
        let info = RemoteVideoInfo(
            url: url,
            videoID: "Vyyrvna-hUY",
            title: "Devin AI Guide",
            duration: 1487,
            thumbnailURL: nil,
            isPlaylist: false,
            playlistCount: nil
        )
        let runner = MockAudioDownloader(info: info)
        let backfill = TrackMetadataBackfill(
            runner: runner,
            writeToDisk: false
        )

        let track = DeviceTrack(
            id: "t",
            url: URL(fileURLWithPath: "/tmp/Devin AI Guide [Vyyrvna-hUY].m4a"),
            relativePath: "Devin AI Guide [Vyyrvna-hUY].m4a",
            fileName: "Devin AI Guide [Vyyrvna-hUY].m4a",
            title: "Devin AI Guide",
            artist: nil,
            duration: nil,
            fileSize: 10,
            modifiedAt: .now,
            artwork: nil
        )

        let result = try #require(
            await backfill.backfill(track: track, knownVideoID: "Vyyrvna-hUY")
        )
        #expect(result.videoID == "Vyyrvna-hUY")
        #expect(result.remoteDuration == 1487)
        #expect(result.track.duration == 1487)
        #expect(result.remoteTitle == "Devin AI Guide")
        #expect(await runner.metadataCallCount == 1)
    }

    @Test("skips tracks that already have artwork and duration")
    func skipsCompleteTracks() async {
        let url = URL(string: "https://www.youtube.com/watch?v=Vyyrvna-hUY")!
        let runner = MockAudioDownloader(
            info: RemoteVideoInfo(
                url: url,
                videoID: "Vyyrvna-hUY",
                title: "X",
                duration: 10,
                thumbnailURL: nil,
                isPlaylist: false,
                playlistCount: nil
            )
        )
        let backfill = TrackMetadataBackfill(runner: runner, writeToDisk: false)
        let track = DeviceTrack(
            id: "t",
            url: URL(fileURLWithPath: "/tmp/x.m4a"),
            relativePath: "x.m4a",
            fileName: "X [Vyyrvna-hUY].m4a",
            title: "X",
            artist: nil,
            duration: 10,
            fileSize: 1,
            modifiedAt: .now,
            artwork: NSImage(size: NSSize(width: 2, height: 2))
        )
        let result = await backfill.backfill(track: track, knownVideoID: "Vyyrvna-hUY")
        #expect(result == nil)
        #expect(await runner.metadataCallCount == 0)
    }
}
