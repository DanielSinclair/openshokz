import Foundation
import Testing
@testable import OpenShokz

// MARK: - Mocks

actor MockAudioDownloader: AudioDownloadClient {
    var info: RemoteVideoInfo
    var progressSteps: [Double]
    var failDownloadWith: Error?
    var downloadCallCount = 0
    var metadataCallCount = 0
    var lastAllowPlaylist: Bool?

    init(
        info: RemoteVideoInfo,
        progressSteps: [Double] = [0.25, 0.5, 1.0],
        failDownloadWith: Error? = nil
    ) {
        self.info = info
        self.progressSteps = progressSteps
        self.failDownloadWith = failDownloadWith
    }

    func fetchMetadata(for url: URL) async throws -> RemoteVideoInfo {
        metadataCallCount += 1
        return RemoteVideoInfo(
            url: url,
            videoID: info.videoID,
            title: info.title,
            duration: info.duration,
            thumbnailURL: info.thumbnailURL,
            isPlaylist: info.isPlaylist,
            playlistCount: info.playlistCount
        )
    }

    func downloadAudio(
        url: URL,
        to directory: URL,
        allowPlaylist: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        downloadCallCount += 1
        lastAllowPlaylist = allowPlaylist
        if let failDownloadWith {
            throw failDownloadWith
        }
        for step in progressSteps {
            onProgress(step)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = info.videoID ?? "dQw4w9WgXcQ"
        let fileName = "\(info.title) [\(id)].m4a"
        let fileURL = directory.appendingPathComponent(fileName)
        let payload = Data("mock-audio".utf8)
        try payload.write(to: fileURL, options: .atomic)
        return [fileURL]
    }

    func cancel() async {}
}

actor MockDeviceTransfer: DeviceTransferClient {
    var copyCallCount = 0
    var lastSource: URL?
    var failWith: Error?

    func copyToDevice(
        fileURL: URL,
        volumeRoot: URL,
        destinationFolder: URL?,
        timeoutSeconds: TimeInterval
    ) async throws -> URL {
        copyCallCount += 1
        lastSource = fileURL
        if let failWith { throw failWith }

        let destDir = destinationFolder ?? volumeRoot
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destination = destDir.appendingPathComponent(fileURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: fileURL, to: destination)
        return destination
    }
}

// MARK: - Tests

@Suite("Download service (mocked)")
@MainActor
struct DownloadServiceMockTests {
    private func sampleInfo(url: URL) -> RemoteVideoInfo {
        RemoteVideoInfo(
            url: url,
            videoID: "Vyyrvna-hUY",
            title: "Devin AI Guide",
            duration: 1487,
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/Vyyrvna-hUY/hqdefault.jpg"),
            isPlaylist: false,
            playlistCount: nil
        )
    }

    @Test("mocked download reports progress then completes with transfer")
    func downloadAndTransferSucceeds() async throws {
        let url = try #require(
            URL(string: "https://www.youtube.com/watch?v=Vyyrvna-hUY")
        )
        let info = sampleInfo(url: url)
        let downloader = MockAudioDownloader(info: info)
        let transfer = MockDeviceTransfer()
        let volume = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-MockVolume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volume) }

        let service = DownloadService(
            runner: downloader,
            transfer: transfer
        )
        service.setURLText(url.absoluteString)
        service.download(sendToDevice: true, volumeRoot: volume)
        await service.awaitCompletion()

        #expect(service.isBusy == false)
        #expect(service.lastError == nil)
        guard case .completed(let localURL) = service.job?.phase else {
            Issue.record("Expected completed phase, got \(String(describing: service.job?.phase))")
            return
        }
        #expect(localURL.path.hasPrefix(volume.path))
        #expect(FileManager.default.fileExists(atPath: localURL.path))
        #expect(service.lastTransferredMediaID == "Vyyrvna-hUY")
        #expect(service.lastTransferredRelativePaths.count == 1)
        #expect(service.statusMessage == "Saved to headphones.")
        #expect(await downloader.downloadCallCount == 1)
        #expect(await transfer.copyCallCount == 1)
    }

    @Test("mocked download without device skips transfer")
    func downloadOnlySkipsTransfer() async throws {
        let url = try #require(
            URL(string: "https://www.youtube.com/watch?v=Vyyrvna-hUY")
        )
        let downloader = MockAudioDownloader(info: sampleInfo(url: url))
        let transfer = MockDeviceTransfer()
        let service = DownloadService(
            runner: downloader,
            transfer: transfer
        )
        service.setURLText(url.absoluteString)
        service.download(sendToDevice: false, volumeRoot: nil)
        await service.awaitCompletion()

        guard case .completed = service.job?.phase else {
            Issue.record("Expected completed phase, got \(String(describing: service.job?.phase))")
            return
        }
        #expect(service.lastTransferredRelativePaths.isEmpty)
        #expect(service.statusMessage == "Downloaded to staging folder.")
        #expect(await transfer.copyCallCount == 0)
    }

    @Test("mocked download failure surfaces failed phase")
    func downloadFailureIsReported() async throws {
        let url = try #require(
            URL(string: "https://www.youtube.com/watch?v=Vyyrvna-hUY")
        )
        let downloader = MockAudioDownloader(
            info: sampleInfo(url: url),
            failDownloadWith: MediaPipelineError.noAudioStream
        )
        let service = DownloadService(
            runner: downloader,
            transfer: MockDeviceTransfer()
        )
        service.setURLText(url.absoluteString)
        service.download(sendToDevice: false, volumeRoot: nil)
        await service.awaitCompletion()

        guard case .failed(let message) = service.job?.phase else {
            Issue.record("Expected failed phase, got \(String(describing: service.job?.phase))")
            return
        }
        #expect(message.contains("no audio file") || service.lastError != nil)
        #expect(service.isBusy == false)
    }

    @Test("empty URL never starts a download job")
    func emptyURLDoesNotStartJob() async {
        let downloader = MockAudioDownloader(
            info: RemoteVideoInfo(
                url: URL(string: "https://example.com")!,
                videoID: nil,
                title: "x",
                duration: nil,
                thumbnailURL: nil,
                isPlaylist: false,
                playlistCount: nil
            )
        )
        let service = DownloadService(
            runner: downloader,
            transfer: MockDeviceTransfer()
        )
        service.setURLText("   ")
        service.download(sendToDevice: false, volumeRoot: nil)
        await service.awaitCompletion()
        #expect(service.job == nil)
        #expect(service.lastError == "Enter a valid link.")
        #expect(await downloader.downloadCallCount == 0)
    }

    @Test("skips download when video id already on device")
    func skipsDuplicateVideoID() async throws {
        let url = try #require(
            URL(string: "https://www.youtube.com/watch?v=Vyyrvna-hUY")
        )
        let downloader = MockAudioDownloader(info: sampleInfo(url: url))
        let transfer = MockDeviceTransfer()
        let volume = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenShokz-Dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volume) }

        let service = DownloadService(
            runner: downloader,
            transfer: transfer
        )
        service.setURLText(url.absoluteString)
        service.download(
            sendToDevice: true,
            volumeRoot: volume,
            existingVideoIDs: ["Vyyrvna-hUY"]
        )
        await service.awaitCompletion()

        guard case .completed = service.job?.phase else {
            Issue.record("Expected completed phase, got \(String(describing: service.job?.phase))")
            return
        }
        #expect(service.statusMessage == "Already on headphones.")
        #expect(service.lastTransferredMediaID == "Vyyrvna-hUY")
        #expect(service.lastTransferredRelativePaths.isEmpty)
        #expect(await downloader.downloadCallCount == 0)
        #expect(await transfer.copyCallCount == 0)
    }
}
