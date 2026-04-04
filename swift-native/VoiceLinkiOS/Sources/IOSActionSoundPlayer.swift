import AVFoundation
import Foundation

enum IOSActionSoundPlayer {
    private static var activePlayers: [AVAudioPlayer] = []
    private static var didPlayStartupIntro = false
    private static var didScheduleStartupRetry = false

    private static var soundsEnabled: Bool {
        UserDefaults.standard.object(forKey: "systemActionNotificationSound") as? Bool ?? true
    }

    static func playToggle() {
        guard soundsEnabled else { return }
        playFirstAvailableBundledSound(
            names: ["button-click", "switch_button_push_small_04", "notification"],
            extensions: ["wav", "m4a", "mp3", "flac"]
        )
    }

    static func playConfirm() {
        guard soundsEnabled else { return }
        playFirstAvailableBundledSound(
            names: ["success", "notification", "button-click"],
            extensions: ["wav", "m4a", "mp3", "flac"]
        )
    }

    static func playClose() {
        guard soundsEnabled else { return }
        playFirstAvailableBundledSound(
            names: ["whoosh_fast2", "whoosh_fast1", "Peek-Out-Of-Room-Blinds-Lowered-Fast"],
            extensions: ["wav", "m4a", "mp3", "flac"]
        )
    }

    static func playPreviewStart() {
        guard soundsEnabled else { return }
        playFirstAvailableBundledSound(
            names: [
                "Peek-In-To-Room-Raised-Fast",
                "Peek-In-Of-Room-Blinds-Raised-Fast",
                "whoosh_fast1",
                "button-click",
                "success"
            ],
            extensions: ["wav", "m4a", "mp3", "flac"]
        )
    }

    static func playPreviewStop() {
        guard soundsEnabled else { return }
        playFirstAvailableBundledSound(
            names: ["Peek-Out-Of-Room-Blinds-Lowered-Fast", "whoosh_fast2", "button-click"],
            extensions: ["wav", "m4a", "mp3", "flac"]
        )
    }

    static func playTest() {
        guard soundsEnabled else { return }
        playFirstAvailableBundledSound(
            names: ["your-sound-test", "success", "notification"],
            extensions: ["wav", "m4a", "mp3", "flac"]
        )
    }

    static func playStartupIntroIfNeeded() {
        guard soundsEnabled, !didPlayStartupIntro else { return }
        if playFirstAvailableBundledSound(
            names: ["voicelink1", "voicelink2", "voicelink3", "voicelink4", "intro-connected", "connected"],
            extensions: ["wav", "m4a", "mp3"]
        ) {
            didPlayStartupIntro = true
        } else if !didScheduleStartupRetry {
            didScheduleStartupRetry = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                didScheduleStartupRetry = false
                playStartupIntroIfNeeded()
            }
        }
    }

    static func playRoomJoin() {
        guard soundsEnabled else { return }
        playFirstAvailableBundledSound(
            names: ["join-son", "son", "user-join", "success"],
            extensions: ["m4a", "wav", "mp3", "flac"]
        )
    }

    static func playError() {
        guard soundsEnabled else { return }
        playBundledSound(named: "error", extensions: ["mp3", "wav", "m4a", "flac"])
    }

    @discardableResult
    private static func playBundledSound(named name: String, extensions: [String]) -> Bool {
        for ext in extensions {
            let candidateURLs = [
                Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Sounds"),
                Bundle.main.url(forResource: name, withExtension: ext)
            ].compactMap { $0 }

            for url in candidateURLs {
                do {
                    try activateActionSoundSessionIfNeeded()
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.volume = 1.0
                    player.prepareToPlay()
                    player.delegate = AudioPlayerCleanupDelegate.shared
                    activePlayers.append(player)
                    player.play()
                    return true
                } catch {
                    continue
                }
            }
        }
        return false
    }

    private static func activateActionSoundSessionIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord,
           session.category != .playback,
           session.category != .ambient {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }
        try session.setActive(true, options: [])
    }

    @discardableResult
    private static func playFirstAvailableBundledSound(names: [String], extensions: [String]) -> Bool {
        for name in names {
            if playBundledSound(named: name, extensions: extensions) {
                return true
            }
        }
        return false
    }

    fileprivate static func cleanupPlayer(_ player: AVAudioPlayer) {
        activePlayers.removeAll { $0 === player }
    }
}

private final class AudioPlayerCleanupDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerCleanupDelegate()

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        IOSActionSoundPlayer.cleanupPlayer(player)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        IOSActionSoundPlayer.cleanupPlayer(player)
    }
}
