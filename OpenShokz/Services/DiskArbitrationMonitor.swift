import DiskArbitration
import Foundation

/// Sendable snapshot of the DiskArbitration description for one disk.
/// Parsed once on the DA queue so policy code never touches CF types.
struct DiskVolumeDescription: Sendable, Equatable {
    var volumeName: String?
    /// Mount point. `nil` until the volume is actually mounted (raw media appears first).
    var volumePath: URL?
    var volumeUUID: String?
    var isRemovableMedia: Bool
    var isEjectable: Bool
}

/// Disk lifecycle event as seen by DiskArbitration, already parsed and Sendable.
enum DiskEvent: Sendable, Equatable {
    /// Disk registered with the system (may not be mounted yet).
    case appeared(DiskVolumeDescription)
    /// Watched description keys changed — fires when the volume mounts or unmounts.
    case changed(DiskVolumeDescription)
    /// Device gone (eject or cable yank). Fires even when no unmount notification is sent.
    case disappeared(DiskVolumeDescription)
}

/// Pure decisions about DiskArbitration events — unit-tested without hardware.
enum ShokzDiskPolicy {
    /// True when the description looks like a mounted-or-mounting Shokz MP3 disk.
    static func isShokzVolume(_ description: DiskVolumeDescription) -> Bool {
        if let name = description.volumeName, ShokzVolumeIdentity.matches(name: name) {
            return true
        }
        if let path = description.volumePath,
           ShokzVolumeIdentity.matches(name: path.lastPathComponent) {
            return true
        }
        return false
    }

    /// Connection state to apply when this disk finishes mounting.
    struct ShokzConnection: Sendable, Equatable {
        var url: URL
        var name: String
        var uuid: String?
    }

    /// `nil` when the disk has no mount point yet or is not a Shokz volume.
    static func connectionUpdate(
        for description: DiskVolumeDescription
    ) -> ShokzConnection? {
        guard isShokzVolume(description), let path = description.volumePath else {
            return nil
        }
        let name = description.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShokzConnection(
            url: path,
            name: (name?.isEmpty == false ? name! : path.lastPathComponent),
            uuid: description.volumeUUID
        )
    }

    /// True when a disappear/unmount event refers to the volume we are showing.
    static func indicatesOurDisconnect(
        _ description: DiskVolumeDescription,
        currentRoot: URL?,
        currentUUID: String?
    ) -> Bool {
        if let uuid = description.volumeUUID, let currentUUID, uuid == currentUUID {
            return true
        }
        if let path = description.volumePath, let currentRoot,
           path.standardizedFileURL == currentRoot.standardizedFileURL {
            return true
        }
        return isShokzVolume(description)
    }

    /// Parses a raw DiskArbitration description dictionary. Pure; testable with plain dictionaries.
    static func parse(_ dictionary: [String: Any]) -> DiskVolumeDescription {
        let name = dictionary[kDADiskDescriptionVolumeNameKey as String] as? String
        let path = dictionary[kDADiskDescriptionVolumePathKey as String] as? URL
        let removable = dictionary[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
        let ejectable = dictionary[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false

        let uuid: String? = {
            guard let value = dictionary[kDADiskDescriptionVolumeUUIDKey as String] else {
                return nil
            }
            let ref = value as CFTypeRef
            guard CFGetTypeID(ref) == CFUUIDGetTypeID() else { return value as? String }
            // swiftlint:disable:next force_cast
            return CFUUIDCreateString(nil, (ref as! CFUUID)) as String
        }()

        return DiskVolumeDescription(
            volumeName: name,
            volumePath: path,
            volumeUUID: uuid,
            isRemovableMedia: removable,
            isEjectable: ejectable
        )
    }
}

/// Callback-driven disk monitoring: mount, unmount, and cable yanks all arrive as
/// DiskArbitration events within milliseconds — no NSWorkspace debounce, no polling,
/// and no main-thread `stat()` against a possibly dead volume.
final class DiskArbitrationMonitor: @unchecked Sendable {
    typealias EventHandler = @MainActor @Sendable (DiskEvent) -> Void

    private let onEvent: EventHandler
    private let queue = DispatchQueue(label: "app.openshokz.disk-arbitration")
    private var session: DASession?

    init(onEvent: @escaping EventHandler) {
        self.onEvent = onEvent
    }

    deinit {
        stop()
    }

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, diskAppearedCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, diskDisappearedCallback, context)
        // Volume path flips nil ↔ mount point exactly at mount/unmount time.
        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,
            [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeNameKey] as CFArray,
            diskDescriptionChangedCallback,
            context
        )
        DASessionSetDispatchQueue(session, queue)
    }

    func stop() {
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DAUnregisterCallback(session, unsafeBitCast(diskAppearedCallback, to: UnsafeMutableRawPointer.self), context)
        DAUnregisterCallback(session, unsafeBitCast(diskDisappearedCallback, to: UnsafeMutableRawPointer.self), context)
        DAUnregisterCallback(session, unsafeBitCast(diskDescriptionChangedCallback, to: UnsafeMutableRawPointer.self), context)
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
    }

    /// Runs on the DA queue: parse into a Sendable value, then hop to MainActor.
    fileprivate func deliver(disk: DADisk, kind: DiskDeliveryKind) {
        guard let raw = DADiskCopyDescription(disk) as? [String: Any] else { return }
        let description = ShokzDiskPolicy.parse(raw)
        let event: DiskEvent
        switch kind {
        case .appeared: event = .appeared(description)
        case .changed: event = .changed(description)
        case .disappeared: event = .disappeared(description)
        }
        let handler = onEvent
        Task { @MainActor in
            handler(event)
        }
    }
}

enum DiskDeliveryKind {
    case appeared
    case changed
    case disappeared
}

private func monitor(from context: UnsafeMutableRawPointer?) -> DiskArbitrationMonitor? {
    guard let context else { return nil }
    return Unmanaged<DiskArbitrationMonitor>.fromOpaque(context).takeUnretainedValue()
}

private let diskAppearedCallback: DADiskAppearedCallback = { disk, context in
    monitor(from: context)?.deliver(disk: disk, kind: .appeared)
}

private let diskDisappearedCallback: DADiskDisappearedCallback = { disk, context in
    monitor(from: context)?.deliver(disk: disk, kind: .disappeared)
}

private let diskDescriptionChangedCallback: DADiskDescriptionChangedCallback = { disk, _, context in
    monitor(from: context)?.deliver(disk: disk, kind: .changed)
}
