import Foundation
import AVFoundation
import AppKit

/// Centralized sound manager for VoiceLink app
/// Uses actual sound files from Resources/sounds directory
class AppSoundManager: ObservableObject {
    static let shared = AppSoundManager()

    // Sound types with their file mappings
    enum SoundType: String, CaseIterable {
        // Connection sounds
        case connected = "connected"
        case disconnected = "connection lost"
        case reconnected = "reconnected"

        // UI feedback sounds
        case success = "success"
        case error = "error"
        case notification = "notification"
        case buttonClick = "button-click"

        // User activity sounds
        case userJoin = "user-join"
        case userLeave = "user-leave"

        // Whisper mode sounds
        case whisperStart = "Whisper-start"
        case whisperStop = "Whisper-Stop"

        // Peek into room sounds
        case peekIn = "Peek-In-To-Room-Raised-Fast"
        case peekOut = "Peek-Out-Of-Room-Blinds-Lowered-Fast"

        // Push-to-talk sounds
        case pttStart = "ptt-beep-high"
        case pttStop = "ptt-beep-low"

        // Message sounds
        case messageIncoming = "message-incoming-ding"
        case messageReceived = "message-receve"
        case doorbell = "Doorbell-Ding-Dong-Type-Single"

        // File transfer
        case fileTransferComplete = "file transfer complete"

        // Menu/UI transition sounds
        case menuOpen = "whoosh_fast1"
        case menuClose = "whoosh_fast2"
        case wooshFast = "whoosh_fast3"
        case wooshMedium = "whoosh_medium1"
        case wooshSlow = "whoosh_slow1"

        // UI animation sounds
        case uiAppear = "UI Animate Clean Beeps Appear (stereo)"
        case uiDisappear = "UI Animate Clean Beeps Disappear (stereo)"

        // Button toggle sounds
        case toggleOn = "switch_button_push_small_04"
        case toggleOff = "switch_button_push_small_05"

        var fileExtension: String {
            switch self {
            case .peekIn, .peekOut, .pttStart, .pttStop, .doorbell,
                 .uiAppear, .uiDisappear, .toggleOn, .toggleOff:
                return "flac"
            default:
                return "wav"
            }
        }

        var description: String {
            switch self {
            case .connected: return "Connected to server"
            case .disconnected: return "Disconnected from server"
            case .reconnected: return "Reconnected to server"
            case .success: return "Success"
            case .error: return "Error"
            case .notification: return "Notification"
            case .buttonClick: return "Button click"
            case .userJoin: return "User joined room"
            case .userLeave: return "User left room"
            case .whisperStart: return "Whisper mode started"
            case .whisperStop: return "Whisper mode ended"
            case .peekIn: return "Peeking into room"
            case .peekOut: return "Stopped peeking"
            case .pttStart: return "Push-to-talk started"
            case .pttStop: return "Push-to-talk ended"
            case .messageIncoming: return "Incoming message"
            case .messageReceived: return "Message received"
            case .doorbell: return "Doorbell"
            case .fileTransferComplete: return "File transfer complete"
            case .menuOpen: return "Menu opened"
            case .menuClose: return "Menu closed"
            case .wooshFast: return "Fast transition"
            case .wooshMedium: return "Medium transition"
            case .wooshSlow: return "Slow transition"
            case .uiAppear: return "UI element appeared"
            case .uiDisappear: return "UI element disappeared"
            case .toggleOn: return "Toggle on"
            case .toggleOff: return "Toggle off"
            }
        }
    }

    // Settings
    @Published var soundsEnabled: Bool = true
    @Published var volume: Float = 0.7

    // Audio players cache
    private var audioPlayers: [SoundType: AVAudioPlayer] = [:]
    private var isInitialized = false

    init() {
        loadSettings()
        preloadSounds()
    }

    // MARK: - Preload Sounds

    private func preloadSounds() {
        for soundType in SoundType.allCases {
            loadSound(soundType)
        }
        isInitialized = true
        print("AppSoundManager: Preloaded \(audioPlayers.count) sounds")
    }

    private func loadSound(_ soundType: SoundType) {
        // Try multiple locations for sound files
        let locations = [
            ("sounds", soundType.rawValue, soundType.fileExtension),
            (nil, soundType.rawValue, soundType.fileExtension),
            ("sounds", soundType.rawValue, "mp3"),
            ("sounds", soundType.rawValue, "flac")
        ]

        for (subdir, name, ext) in locations {
            var url: URL?
            if let sub = subdir {
                url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: sub)
            } else {
                url = Bundle.main.url(forResource: name, withExtension: ext)
            }

            if let soundURL = url {
                do {
                    let player = try AVAudioPlayer(contentsOf: soundURL)
                    player.prepareToPlay()
                    player.volume = volume
                    audioPlayers[soundType] = player
                    return
                } catch {
                    print("AppSoundManager: Failed to load \(soundType.rawValue): \(error)")
                }
            }
        }

        print("AppSoundManager: Sound file not found for \(soundType.rawValue)")
    }

    // MARK: - Play Sounds

    func playSound(_ soundType: SoundType) {
        guard soundsEnabled else { return }

        if let player = audioPlayers[soundType] {
            player.volume = volume
            player.currentTime = 0
            player.play()
            print("AppSoundManager: Playing \(soundType.description)")
        } else {
            // Try to load on demand
            loadSound(soundType)
            if let player = audioPlayers[soundType] {
                player.volume = volume
                player.currentTime = 0
                player.play()
            } else {
                // Fallback to system sound
                playSystemSound(for: soundType)
            }
        }
    }

    private func playSystemSound(for soundType: SoundType) {
        // Fallback to NSSound system sounds
        let systemSoundName: String? = {
            switch soundType {
            case .success: return "Glass"
            case .error: return "Basso"
            case .notification: return "Ping"
            case .connected: return "Pop"
            case .disconnected: return "Blow"
            case .buttonClick: return "Tink"
            default: return nil
            }
        }()

        if let name = systemSoundName, let sound = NSSound(named: NSSound.Name(name)) {
            sound.volume = volume
            sound.play()
            print("AppSoundManager: Playing system sound \(name) as fallback")
        }
    }

    // Convenience methods - Connection
    func playConnectedSound() { playSound(.connected) }
    func playDisconnectedSound() { playSound(.disconnected) }
    func playReconnectedSound() { playSound(.reconnected) }

    // Convenience methods - UI Feedback
    func playSuccessSound() { playSound(.success) }
    func playErrorSound() { playSound(.error) }
    func playNotificationSound() { playSound(.notification) }
    func playButtonClickSound() { playSound(.buttonClick) }

    // Convenience methods - User Activity
    func playUserJoinSound() { playSound(.userJoin) }
    func playUserLeaveSound() { playSound(.userLeave) }

    // Convenience methods - Whisper Mode
    func playWhisperStartSound() { playSound(.whisperStart) }
    func playWhisperStopSound() { playSound(.whisperStop) }

    // Convenience methods - Peek Into Room
    func playPeekInSound() { playSound(.peekIn) }
    func playPeekOutSound() { playSound(.peekOut) }

    // Convenience methods - Push-to-Talk
    func playPTTStartSound() { playSound(.pttStart) }
    func playPTTStopSound() { playSound(.pttStop) }

    // Convenience methods - Messages
    func playMessageIncomingSound() { playSound(.messageIncoming) }
    func playMessageReceivedSound() { playSound(.messageReceived) }
    func playDoorbellSound() { playSound(.doorbell) }
    func playFileTransferCompleteSound() { playSound(.fileTransferComplete) }

    // Convenience methods - Menu/UI Transitions
    func playMenuOpenSound() { playSound(.menuOpen) }
    func playMenuCloseSound() { playSound(.menuClose) }
    func playWooshSound() { playSound(.wooshFast) }
    func playUIAppearSound() { playSound(.uiAppear) }
    func playUIDisappearSound() { playSound(.uiDisappear) }
    func playToggleOnSound() { playSound(.toggleOn) }
    func playToggleOffSound() { playSound(.toggleOff) }

    // MARK: - Settings

    private func loadSettings() {
        if let enabled = UserDefaults.standard.object(forKey: "appSoundsEnabled") as? Bool {
            soundsEnabled = enabled
        }
        if let vol = UserDefaults.standard.object(forKey: "appSoundsVolume") as? Float {
            volume = vol
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(soundsEnabled, forKey: "appSoundsEnabled")
        UserDefaults.standard.set(volume, forKey: "appSoundsVolume")

        // Update volume on all players
        for player in audioPlayers.values {
            player.volume = volume
        }
    }

    func setEnabled(_ enabled: Bool) {
        soundsEnabled = enabled
        saveSettings()
    }

    func setVolume(_ newVolume: Float) {
        volume = max(0, min(1, newVolume))
        saveSettings()
    }

    // MARK: - Test

    func testAllSounds() {
        var delay: Double = 0
        for soundType in SoundType.allCases {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.playSound(soundType)
            }
            delay += 0.8
        }
    }
}
