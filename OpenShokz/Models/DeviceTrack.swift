import AppKit
import Foundation

struct DeviceTrack: Identifiable, Hashable {
    let id: String
    let url: URL
    let relativePath: String
    let fileName: String
    let title: String
    let artist: String?
    let duration: TimeInterval?
    let fileSize: Int64
    let modifiedAt: Date
    let artwork: NSImage?

    var identityKey: String {
        "\(relativePath)|\(fileSize)|\(Int(modifiedAt.timeIntervalSince1970))"
    }

    static func == (lhs: DeviceTrack, rhs: DeviceTrack) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum AudioFileSupport {
    static let extensions: Set<String> = [
        "m4a", "mp3", "aac", "flac", "wav", "wma", "ape", "m4b"
    ]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
