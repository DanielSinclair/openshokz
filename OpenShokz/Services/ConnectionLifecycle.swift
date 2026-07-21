import Foundation

/// Pure connection-lifecycle rules used by the UI — unit-tested so USB plug-in
/// flicker cannot regress into freezes or premature quits.
enum ConnectionLifecycle {
    /// Whether an observed disconnect should eventually quit the app.
    static func shouldScheduleQuit(
        hasSeenConnection: Bool,
        wasConnected: Bool,
        isConnectedNow: Bool
    ) -> Bool {
        !isConnectedNow && (hasSeenConnection || wasConnected)
    }

    /// After waiting for USB to settle, confirm we should still quit.
    static func shouldConfirmQuit(stillDisconnected: Bool) -> Bool {
        stillDisconnected
    }

    /// How long a disconnect must persist before auto-quit.
    /// Status chrome flips instantly on the DiskArbitration event; only quitting waits,
    /// so a mount/unmount flicker during USB settle can never kill the app.
    static let disconnectQuitDelay: Duration = .seconds(1.5)

    /// How often the connected loop samples the cheap volume change token
    /// (one root stat + free space — never a listing, never AVFoundation).
    static let changeSignalInterval: Duration = .seconds(30)
}
