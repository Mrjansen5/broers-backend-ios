// Media-style headset presses (AVRCP play/pause), the route a Bluetooth headset's button takes when it is NOT in a
// call. In CallKit mode the press normally arrives as an end-call request instead (see CallManager); these handlers
// stay registered in both modes so whichever way iOS delivers the press, it flips the mic.
import Foundation
import MediaPlayer
import UIKit

final class HeadsetButtons {
    static let shared = HeadsetButtons()
    private var targets: [(MPRemoteCommand, Any)] = []

    func enable(_ onPress: @escaping (String) -> Void) {
        disable()
        let cc = MPRemoteCommandCenter.shared()
        let cmds: [(MPRemoteCommand, String)] = [
            (cc.togglePlayPauseCommand, "togglePlayPause"), (cc.playCommand, "play"),
            (cc.pauseCommand, "pause"), (cc.stopCommand, "stop"),
        ]
        for (cmd, name) in cmds {
            cmd.isEnabled = true
            let t = cmd.addTarget { _ in
                DispatchQueue.main.async { onPress(name) }
                return .success
            }
            targets.append((cmd, t))
        }
        // Skip commands are swallowed (a double click must not jump into someone's music app).
        for cmd in [cc.nextTrackCommand, cc.previousTrackCommand] {
            cmd.isEnabled = true
            targets.append((cmd, cmd.addTarget { _ in .success }))
        }
        UIApplication.shared.beginReceivingRemoteControlEvents()
        nowPlaying(muted: false, count: 1)
    }

    func disable() {
        for (cmd, t) in targets { cmd.removeTarget(t) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    func nowPlaying(muted: Bool, count: Int) {
        guard !targets.isEmpty else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: muted ? "Radio — MUTED" : "Radio — mic ON",
            MPMediaItemPropertyArtist: "Broers Backend",
            MPMediaItemPropertyAlbumTitle: "\(count) on the channel",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
    }
}
