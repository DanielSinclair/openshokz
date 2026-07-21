import Foundation

/// kqueue-backed watch on a directory's entries — fires when files are added
/// or removed directly on the volume (e.g. deletes in Finder), so the library
/// can refresh immediately instead of waiting for the periodic change token.
final class VolumeContentWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "app.openshokz.volume-watch")

    func watch(_ url: URL, onChange: @escaping @Sendable () -> Void) {
        stop()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
