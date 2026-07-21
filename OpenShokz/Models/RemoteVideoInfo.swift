import Foundation

struct RemoteVideoInfo: Identifiable, Equatable, Sendable {
    var id: String { videoID ?? url.absoluteString }
    let url: URL
    let videoID: String?
    let title: String
    let duration: TimeInterval?
    let thumbnailURL: URL?
    let isPlaylist: Bool
    let playlistCount: Int?
}

struct DownloadJob: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case queued
        case fetchingMetadata
        case downloading(progress: Double)
        case processing
        case transferring
        case completed(localURL: URL)
        case failed(message: String)
        case cancelled
    }

    let id: UUID
    let sourceURL: URL
    var info: RemoteVideoInfo?
    var phase: Phase
    var sendToDevice: Bool
}
