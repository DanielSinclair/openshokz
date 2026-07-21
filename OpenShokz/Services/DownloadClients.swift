import Foundation

/// Abstraction over the media pipeline so downloads can be mocked in unit tests.
protocol AudioDownloadClient: Sendable {
    func fetchMetadata(for url: URL) async throws -> RemoteVideoInfo
    func downloadAudio(
        url: URL,
        to directory: URL,
        allowPlaylist: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL]
    func cancel() async
}

/// Abstraction over copying finished audio onto the headphones volume.
protocol DeviceTransferClient: Sendable {
    func copyToDevice(
        fileURL: URL,
        volumeRoot: URL,
        destinationFolder: URL?,
        timeoutSeconds: TimeInterval
    ) async throws -> URL
}
