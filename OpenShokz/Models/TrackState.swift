import Foundation
import SwiftData

@Model
final class TrackState {
    @Attribute(.unique) var identityKey: String
    @Attribute(originalName: "youtubeID") var mediaID: String?
    var titleOverride: String?
    /// Remote duration when the file itself has no readable duration tag.
    var cachedDuration: Double?
    /// JPEG bytes for cover art when the volume has no readable/embedded artwork.
    var cachedArtworkJPEG: Data?
    /// Avoid re-hitting the network every library refresh after a successful backfill.
    /// Optional for lightweight migration from older stores.
    var remoteMetadataAttempted: Bool?
    var addedAt: Date
    /// On-volume path — lets the library paint instantly from cache before any USB I/O.
    /// Optional for lightweight migration from older stores.
    var relativePath: String?
    /// Volume UUID that owned this file — keys the cache to a specific device.
    var volumeID: String?
    /// Last time a completed listing confirmed this file on the device.
    var lastSeenAt: Date?

    init(
        identityKey: String,
        mediaID: String? = nil,
        titleOverride: String? = nil,
        cachedDuration: Double? = nil,
        cachedArtworkJPEG: Data? = nil,
        remoteMetadataAttempted: Bool = false,
        addedAt: Date = .now,
        relativePath: String? = nil,
        volumeID: String? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.identityKey = identityKey
        self.mediaID = mediaID
        self.titleOverride = titleOverride
        self.cachedDuration = cachedDuration
        self.cachedArtworkJPEG = cachedArtworkJPEG
        self.remoteMetadataAttempted = remoteMetadataAttempted
        self.addedAt = addedAt
        self.relativePath = relativePath
        self.volumeID = volumeID
        self.lastSeenAt = lastSeenAt
    }

    var hasAttemptedRemoteMetadata: Bool {
        remoteMetadataAttempted == true
    }

    /// Relative path for cache painting; recovers it from a legacy
    /// identityKey (`path|size|mtime`) when the explicit field is missing.
    var cacheRelativePath: String? {
        if let relativePath, !relativePath.isEmpty { return relativePath }
        let parts = identityKey.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              Int(parts[parts.count - 1]) != nil,
              Int(parts[parts.count - 2]) != nil
        else { return nil }
        let recovered = parts.dropLast(2).joined(separator: "|")
        return recovered.isEmpty ? nil : recovered
    }

    var hasCachedVisualMetadata: Bool {
        (cachedDuration ?? 0) > 0 || cachedArtworkJPEG != nil
    }
}
