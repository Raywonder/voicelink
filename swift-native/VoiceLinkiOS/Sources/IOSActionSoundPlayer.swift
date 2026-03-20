import AudioToolbox
import Foundation

enum IOSActionSoundPlayer {
    private static var soundsEnabled: Bool {
        UserDefaults.standard.object(forKey: "systemActionNotificationSound") as? Bool ?? true
    }

    static func playToggle() {
        guard soundsEnabled else { return }
        AudioServicesPlaySystemSound(1104)
    }

    static func playConfirm() {
        guard soundsEnabled else { return }
        AudioServicesPlaySystemSound(1057)
    }

    static func playClose() {
        guard soundsEnabled else { return }
        AudioServicesPlaySystemSound(1118)
    }

    static func playTest() {
        guard soundsEnabled else { return }
        AudioServicesPlaySystemSound(1005)
    }
}
