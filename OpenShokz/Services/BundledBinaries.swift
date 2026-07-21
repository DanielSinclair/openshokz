import Foundation

enum BundledBinariesError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "Bundled binary “\(name)” was not found in the app. Run scripts/fetch-binaries.sh and rebuild."
        }
    }
}

enum BundledBinaries {
    static var ffmpegURL: URL {
        get throws {
            try locate(named: "ffmpeg")
        }
    }

    static var ffmpegDirectoryURL: URL {
        get throws {
            try ffmpegURL.deletingLastPathComponent()
        }
    }

    private static func locate(named name: String) throws -> URL {
        let candidates: [URL?] = [
            Bundle.main.url(forAuxiliaryExecutable: name),
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Binaries"),
            Bundle.main.resourceURL?.appendingPathComponent("Binaries/\(name)"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/Binaries/\(name)"),
            // Dev fallback when running from Xcode before resources copy settles
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/Binaries/\(name)")
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw BundledBinariesError.missing(name)
    }
}
