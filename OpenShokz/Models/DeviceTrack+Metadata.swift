import AppKit
import Foundation

extension DeviceTrack {
    func updating(
        title: String? = nil,
        artist: String? = nil,
        duration: TimeInterval? = nil,
        artwork: NSImage? = nil
    ) -> DeviceTrack {
        DeviceTrack(
            id: id,
            url: url,
            relativePath: relativePath,
            fileName: fileName,
            title: title ?? self.title,
            artist: artist ?? self.artist,
            duration: duration ?? self.duration,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            artwork: artwork ?? self.artwork
        )
    }

    /// Missing cover art and/or playable duration — candidates for YouTube backfill.
    var needsRemoteMetadata: Bool {
        artwork == nil || duration == nil || duration == 0
    }
}
