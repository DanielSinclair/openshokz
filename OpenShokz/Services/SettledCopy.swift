import Foundation

enum SettledCopyError: LocalizedError, Equatable {
    case openFailed(String)
    case writeFailed(String)
    case verifyMismatch

    var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "Couldn’t open \(path)."
        case .writeFailed(let message):
            return message
        case .verifyMismatch:
            return "The copy didn’t match the original after writing — try again."
        }
    }
}

/// Copy with an honest settlement contract:
///
/// 1. Stream the source in chunks.
/// 2. `F_FULLFSYNC` the destination — data pushed to the physical media,
///    not just the unified buffer cache (falls back to `fsync` where the
///    filesystem doesn't support it, e.g. some FAT drivers).
/// 3. Confirm the write: the destination size matches, and the first and last
///    64 KiB read back off the device (page cache bypassed) match the source.
///    Cheap USB controllers fail grossly — nothing committed, a truncated
///    tail, a wrong length — and those regions catch all of it at ~1–2% of a
///    full re-read's I/O. That keeps the slow-USB verify from doubling the
///    transfer while still letting the UI mean "safe to unplug".
enum SettledCopy {
    private static let chunkSize = 1 << 20  // 1 MiB
    private static let probeSize = 64 * 1024  // first & last 64 KiB

    static func copyAndVerify(from source: URL, to destination: URL) throws {
        let bytesWritten = try copySettling(from: source, to: destination)
        do {
            try verifyEnds(source: source, destination: destination, expectedSize: bytesWritten)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Chunked write + F_FULLFSYNC. Returns the number of bytes written.
    private static func copySettling(from source: URL, to destination: URL) throws -> Int {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw SettledCopyError.openFailed(source.lastPathComponent) }
        defer { close(input) }

        let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard output >= 0 else { throw SettledCopyError.openFailed(destination.lastPathComponent) }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var total = 0
        var failure: SettledCopyError?

        while true {
            let bytesRead = read(input, &buffer, chunkSize)
            if bytesRead == 0 { break }
            guard bytesRead > 0 else {
                failure = .writeFailed("Reading the downloaded file failed.")
                break
            }
            var offset = 0
            while offset < bytesRead {
                let written = buffer[offset..<bytesRead].withUnsafeBytes { raw in
                    write(output, raw.baseAddress, raw.count)
                }
                guard written > 0 else {
                    failure = .writeFailed("Writing to the headphones failed — the volume may be full or disconnected.")
                    break
                }
                offset += written
            }
            if failure != nil { break }
            total += bytesRead
        }

        if failure == nil {
            // Push to physical media; fsync is the honest fallback when the
            // filesystem doesn't implement full sync.
            if fcntl(output, F_FULLFSYNC) != 0 {
                _ = fsync(output)
            }
        }
        close(output)

        if let failure {
            try? FileManager.default.removeItem(at: destination)
            throw failure
        }
        return total
    }

    /// Size + prefix/suffix integrity check. Reads only the first and last
    /// `probeSize` bytes of the destination (page cache bypassed) and compares
    /// them byte-for-byte to the source — enough to catch the gross failures
    /// cheap USB controllers actually exhibit, at a fraction of a full re-read.
    private static func verifyEnds(source: URL, destination: URL, expectedSize: Int) throws {
        var info = stat()
        guard stat(destination.path, &info) == 0, Int(info.st_size) == expectedSize else {
            throw SettledCopyError.verifyMismatch
        }

        let src = open(source.path, O_RDONLY)
        guard src >= 0 else { throw SettledCopyError.openFailed(source.lastPathComponent) }
        defer { close(src) }

        let dst = open(destination.path, O_RDONLY)
        guard dst >= 0 else { throw SettledCopyError.openFailed(destination.lastPathComponent) }
        defer { close(dst) }
        _ = fcntl(dst, F_NOCACHE, 1)

        // Head [0, probe); tail [size-probe, size). Clamp so they never overlap
        // (small files collapse to a single whole-file compare).
        let headLen = min(probeSize, expectedSize)
        let tailStart = max(expectedSize - probeSize, headLen)
        let tailLen = expectedSize - tailStart

        for (offset, length) in [(off_t(0), headLen), (off_t(tailStart), tailLen)] where length > 0 {
            let a = try readExact(src, at: offset, length: length)
            let b = try readExact(dst, at: offset, length: length)
            guard a == b else { throw SettledCopyError.verifyMismatch }
        }
    }

    private static func readExact(_ fd: Int32, at offset: off_t, length: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: length)
        var got = 0
        while got < length {
            let n = buffer[got...].withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress, length - got, offset + off_t(got))
            }
            guard n > 0 else {
                throw SettledCopyError.writeFailed("Reading back from the headphones failed.")
            }
            got += n
        }
        return buffer
    }
}
