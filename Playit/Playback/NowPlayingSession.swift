import Foundation
import MediaPlayer

/// Bridges AirPods, wired remotes and Control Center to the active player.
/// Only the newest session owns the system "Now Playing" information.
@MainActor
final class NowPlayingSession {
    struct Handlers {
        var play: @MainActor () -> Void
        var pause: @MainActor () -> Void
        var toggle: @MainActor () -> Void
        var seek: @MainActor (Double) -> Void
        /// Nil when there is no list to move through.
        var track: (@MainActor (Int) -> Void)?
    }

    private static var owner: ObjectIdentifier?
    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    private var title = ""

    var isActive: Bool { Self.owner == ObjectIdentifier(self) }

    func activate(title: String, handlers: Handlers) {
        deactivate()
        Self.owner = ObjectIdentifier(self)
        self.title = title
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand, Self.target(center.playCommand, handlers.play))
        add(center.pauseCommand, Self.target(center.pauseCommand, handlers.pause))
        add(center.togglePlayPauseCommand, Self.target(center.togglePlayPauseCommand, handlers.toggle))
        add(center.changePlaybackPositionCommand, Self.positionTarget(center.changePlaybackPositionCommand, handlers.seek))
        if let track = handlers.track {
            add(center.nextTrackCommand, Self.target(center.nextTrackCommand) { track(1) })
            add(center.previousTrackCommand, Self.target(center.previousTrackCommand) { track(-1) })
        } else {
            center.nextTrackCommand.isEnabled = false
            center.previousTrackCommand.isEnabled = false
        }
    }

    /// Updates the system's progress and rate. Call on state changes, not every frame:
    /// the system extrapolates the elapsed time from the rate.
    func update(elapsed: Double, duration: Double, rate: Double, isPlaying: Bool) {
        guard isActive else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? max(0, elapsed) : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && rate.isFinite ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func deactivate() {
        // A newer player may already own the shared commands; leave them enabled.
        let owned = isActive
        for target in targets {
            target.command.removeTarget(target.token)
            if owned { target.command.isEnabled = false }
        }
        targets.removeAll()
        if owned {
            Self.owner = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func add(_ command: MPRemoteCommand, _ token: Any) {
        command.isEnabled = true
        targets.append((command: command, token: token))
    }

    // Remote command handlers may arrive on any thread; they only schedule work
    // on the main actor and report success immediately.
    nonisolated private static func target(_ command: MPRemoteCommand,
                                           _ action: @escaping @MainActor () -> Void) -> Any {
        command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    nonisolated private static func positionTarget(_ command: MPRemoteCommand,
                                                   _ action: @escaping @MainActor (Double) -> Void) -> Any {
        command.addTarget { event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime,
                  position.isFinite else { return .commandFailed }
            Task { @MainActor in action(position) }
            return .success
        }
    }
}
