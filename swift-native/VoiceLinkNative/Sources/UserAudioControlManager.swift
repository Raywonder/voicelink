import Foundation
import SwiftUI
import Combine

/// Manages per-user audio controls including volume, mute, and spatial positioning
class UserAudioControlManager: ObservableObject {
    static let shared = UserAudioControlManager()

    // Per-user audio settings
    @Published var userVolumes: [String: Float] = [:]      // userId -> volume (0.0 to 2.0, 1.0 = normal)
    @Published var userMuted: [String: Bool] = [:]         // userId -> isMuted
    @Published var focusedUserId: String?                   // Currently focused user for keyboard control
    @Published var soloedUserId: String?                    // Single-user solo (others muted)

    // Global settings
    @Published var masterVolume: Float = 1.0
    @Published var defaultUserVolume: Float = 1.0

    // Volume step for keyboard controls
    let volumeStep: Float = 0.1  // 10% per step

    init() {
        setupKeyboardShortcuts()
        loadSettings()
    }

    // MARK: - Volume Control

    /// Get volume for a user (returns default if not set)
    func getVolume(for userId: String) -> Float {
        return userVolumes[userId] ?? defaultUserVolume
    }

    /// Set volume for a user
    func setVolume(for userId: String, volume: Float) {
        let clampedVolume = max(0.0, min(2.0, volume))
        userVolumes[userId] = clampedVolume

        // Play feedback sound
        if clampedVolume == 0 {
            AppSoundManager.shared.playSound(.toggleOff)
        } else {
            AppSoundManager.shared.playButtonClickSound()
        }

        // Notify audio engine
        NotificationCenter.default.post(
            name: .userVolumeChanged,
            object: nil,
            userInfo: ["userId": userId, "volume": clampedVolume * masterVolume]
        )

        saveSettings()
    }

    /// Set master volume (applies to all users)
    func setMasterVolume(_ volume: Float) {
        masterVolume = max(0.0, min(1.5, volume))
        NotificationCenter.default.post(name: .userMasterVolumeChanged, object: nil)
        saveSettings()
    }

    /// Increase volume for a user
    func increaseVolume(for userId: String) {
        let current = getVolume(for: userId)
        setVolume(for: userId, volume: current + volumeStep)
    }

    /// Decrease volume for a user
    func decreaseVolume(for userId: String) {
        let current = getVolume(for: userId)
        setVolume(for: userId, volume: current - volumeStep)
    }

    /// Reset volume to default
    func resetVolume(for userId: String) {
        setVolume(for: userId, volume: defaultUserVolume)
    }

    // MARK: - Mute Control

    /// Check if user is muted
    func isMuted(_ userId: String) -> Bool {
        return userMuted[userId] ?? false
    }

    /// Toggle mute for a user
    func toggleMute(for userId: String) {
        let currentlyMuted = isMuted(userId)
        setMuted(for: userId, muted: !currentlyMuted)
    }

    /// Set mute state for a user
    func setMuted(for userId: String, muted: Bool) {
        userMuted[userId] = muted

        // Play feedback sound
        if muted {
            AppSoundManager.shared.playSound(.toggleOff)
        } else {
            AppSoundManager.shared.playSound(.toggleOn)
        }

        // Notify audio engine
        NotificationCenter.default.post(
            name: .userMuteChanged,
            object: nil,
            userInfo: ["userId": userId, "muted": muted]
        )

        saveSettings()
    }

    // MARK: - Solo Control

    func toggleSolo(for userId: String) {
        if soloedUserId == userId {
            soloedUserId = nil
        } else {
            soloedUserId = userId
        }
        NotificationCenter.default.post(
            name: .userSoloChanged,
            object: nil,
            userInfo: ["userId": soloedUserId as Any]
        )
    }

    /// Mute all users
    func muteAll() {
        for user in ServerManager.shared.currentRoomUsers {
            setMuted(for: user.odId, muted: true)
        }
    }

    /// Unmute all users
    func unmuteAll() {
        for userId in userMuted.keys {
            setMuted(for: userId, muted: false)
        }
    }

    // MARK: - Focus Control

    /// Set focused user for keyboard control
    func setFocusedUser(_ userId: String?) {
        focusedUserId = userId
        if let id = userId {
            print("UserAudioControl: Focused on user \(id)")
        }
    }

    /// Focus next user in list
    func focusNextUser() {
        let users = ServerManager.shared.currentRoomUsers
        guard !users.isEmpty else { return }

        if let currentId = focusedUserId,
           let currentIndex = users.firstIndex(where: { $0.odId == currentId }) {
            let nextIndex = (currentIndex + 1) % users.count
            focusedUserId = users[nextIndex].odId
        } else {
            focusedUserId = users.first?.odId
        }

        AppSoundManager.shared.playButtonClickSound()
    }

    /// Focus previous user in list
    func focusPreviousUser() {
        let users = ServerManager.shared.currentRoomUsers
        guard !users.isEmpty else { return }

        if let currentId = focusedUserId,
           let currentIndex = users.firstIndex(where: { $0.odId == currentId }) {
            let prevIndex = currentIndex > 0 ? currentIndex - 1 : users.count - 1
            focusedUserId = users[prevIndex].odId
        } else {
            focusedUserId = users.last?.odId
        }

        AppSoundManager.shared.playButtonClickSound()
    }

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Don't handle if in text field
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }

            let hasCmd = event.modifierFlags.contains(.command)
            let hasOpt = event.modifierFlags.contains(.option)
            let hasShift = event.modifierFlags.contains(.shift)

            switch event.keyCode {
            case 126: // Up arrow
                if hasCmd && hasOpt {
                    // Cmd+Opt+Up = Master volume up
                    self.increaseMasterVolume()
                    return nil
                } else if hasCmd {
                    // Cmd+Up = User volume up (focused user)
                    if let focusedId = self.focusedUserId {
                        self.increaseVolume(for: focusedId)
                        return nil
                    }
                }

            case 125: // Down arrow
                if hasCmd && hasOpt {
                    // Cmd+Opt+Down = Master volume down
                    self.decreaseMasterVolume()
                    return nil
                } else if hasCmd {
                    // Cmd+Down = User volume down (focused user)
                    if let focusedId = self.focusedUserId {
                        self.decreaseVolume(for: focusedId)
                        return nil
                    }
                }

            case 48: // Tab - focus next/previous user
                if hasShift {
                    self.focusPreviousUser()
                } else {
                    self.focusNextUser()
                }
                return nil

            case 46: // M key
                if hasCmd {
                    // Cmd+M = Toggle mute focused user
                    if let focusedId = self.focusedUserId {
                        self.toggleMute(for: focusedId)
                        return nil
                    }
                }

            case 15: // R key
                if hasCmd {
                    // Cmd+R = Reset volume for focused user
                    if let focusedId = self.focusedUserId {
                        self.resetVolume(for: focusedId)
                        return nil
                    }
                }

            case 27: // 0 key
                if hasCmd && hasOpt {
                    // Cmd+Opt+0 = Reset master volume
                    self.masterVolume = 1.0
                    self.saveSettings()
                    AppSoundManager.shared.playButtonClickSound()
                    return nil
                }

            default:
                break
            }

            return event
        }
    }

    // MARK: - Master Volume Control

    func increaseMasterVolume() {
        masterVolume = min(1.5, masterVolume + volumeStep)
        saveSettings()
        AppSoundManager.shared.playButtonClickSound()

        NotificationCenter.default.post(
            name: .masterVolumeChanged,
            object: nil,
            userInfo: ["volume": masterVolume]
        )
    }

    func decreaseMasterVolume() {
        masterVolume = max(0.0, masterVolume - volumeStep)
        saveSettings()

        if masterVolume == 0 {
            AppSoundManager.shared.playSound(.toggleOff)
        } else {
            AppSoundManager.shared.playButtonClickSound()
        }

        NotificationCenter.default.post(
            name: .masterVolumeChanged,
            object: nil,
            userInfo: ["volume": masterVolume]
        )
    }

    // MARK: - Persistence

    private func loadSettings() {
        if let volumeData = UserDefaults.standard.dictionary(forKey: "userVolumes") as? [String: Float] {
            userVolumes = volumeData
        }
        if let muteData = UserDefaults.standard.dictionary(forKey: "userMuted") as? [String: Bool] {
            userMuted = muteData
        }
        masterVolume = UserDefaults.standard.float(forKey: "masterVolume")
        if masterVolume == 0 { masterVolume = 1.0 }
    }

    private func saveSettings() {
        UserDefaults.standard.set(userVolumes, forKey: "userVolumes")
        UserDefaults.standard.set(userMuted, forKey: "userMuted")
        UserDefaults.standard.set(masterVolume, forKey: "masterVolume")
    }

    // MARK: - Cleanup

    func cleanup() {
        userVolumes.removeAll()
        userMuted.removeAll()
        focusedUserId = nil
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let userVolumeChanged = Notification.Name("userVolumeChanged")
    static let userMuteChanged = Notification.Name("userMuteChanged")
    static let userSoloChanged = Notification.Name("userSoloChanged")
    static let userMasterVolumeChanged = Notification.Name("userMasterVolumeChanged")
}

// MARK: - SwiftUI Views

/// Volume slider for a single user
struct UserVolumeSlider: View {
    let userId: String
    let username: String
    @ObservedObject var audioControl = UserAudioControlManager.shared

    var volume: Float {
        audioControl.getVolume(for: userId)
    }

    var isMuted: Bool {
        audioControl.isMuted(userId)
    }

    var isFocused: Bool {
        audioControl.focusedUserId == userId
    }

    var body: some View {
        HStack(spacing: 12) {
            // Mute button
            Button(action: { audioControl.toggleMute(for: userId) }) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundColor(isMuted ? .red : .white)
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute \(username)" : "Mute \(username)")

            // Username
            Text(username)
                .font(.caption)
                .foregroundColor(isFocused ? .blue : .white)
                .frame(width: 100, alignment: .leading)

            // Volume slider
            Slider(
                value: Binding(
                    get: { Double(volume) },
                    set: { audioControl.setVolume(for: userId, volume: Float($0)) }
                ),
                in: 0...2,
                step: 0.1
            )
            .disabled(isMuted)
            .opacity(isMuted ? 0.5 : 1.0)

            // Volume percentage
            Text("\(Int(volume * 100))%")
                .font(.caption)
                .foregroundColor(.gray)
                .frame(width: 45, alignment: .trailing)

            // Volume buttons
            HStack(spacing: 4) {
                Button(action: { audioControl.decreaseVolume(for: userId) }) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .disabled(volume <= 0)

                Button(action: { audioControl.increaseVolume(for: userId) }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(volume >= 2.0)
            }
            .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isFocused ? Color.blue.opacity(0.2) : Color.clear)
        .cornerRadius(6)
        .onTapGesture {
            audioControl.setFocusedUser(userId)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(username), volume \(Int(volume * 100)) percent, \(isMuted ? "muted" : "unmuted")")
        .accessibilityHint("Tap to focus. Use Option+Up/Down to adjust volume, Option+M to mute")
    }
}

/// Panel showing all user volume controls
struct UserVolumeControlPanel: View {
    @ObservedObject var serverManager = ServerManager.shared
    @ObservedObject var audioControl = UserAudioControlManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("User Volumes")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                // Mute/Unmute all
                Button(action: { audioControl.muteAll() }) {
                    Image(systemName: "speaker.slash")
                }
                .buttonStyle(.plain)
                .help("Mute all users")

                Button(action: { audioControl.unmuteAll() }) {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .help("Unmute all users")
            }
            .foregroundColor(.white.opacity(0.8))

            // Keyboard hint
            Text("Tab to focus, Opt+\u{2191}/\u{2193} volume, Opt+M mute")
                .font(.caption2)
                .foregroundColor(.gray)

            Divider()

            // User list
            if serverManager.currentRoomUsers.isEmpty {
                Text("No other users in room")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(serverManager.currentRoomUsers) { user in
                            UserVolumeSlider(
                                userId: user.odId,
                                username: user.username
                            )
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            // Master volume
            Divider()

            HStack {
                Text("Master")
                    .font(.caption)
                    .foregroundColor(.gray)

                Slider(
                    value: Binding(
                        get: { Double(audioControl.masterVolume) },
                        set: { audioControl.setMasterVolume(Float($0)) }
                    ),
                    in: 0...1.5
                )

                Text("\(Int(audioControl.masterVolume * 100))%")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(width: 45)
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
        .cornerRadius(10)
    }
}

/// Compact inline volume control for user list
struct InlineUserVolumeControl: View {
    let userId: String
    @ObservedObject var audioControl = UserAudioControlManager.shared

    var volume: Float {
        audioControl.getVolume(for: userId)
    }

    var isMuted: Bool {
        audioControl.isMuted(userId)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Quick mute toggle
            Button(action: { audioControl.toggleMute(for: userId) }) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                    .font(.caption)
                    .foregroundColor(isMuted ? .red : volumeColor)
            }
            .buttonStyle(.plain)

            // Mini volume bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))

                    Rectangle()
                        .fill(volumeColor)
                        .frame(width: geometry.size.width * CGFloat(min(volume, 1.0)))
                }
            }
            .frame(width: 30, height: 4)
            .cornerRadius(2)
            .opacity(isMuted ? 0.3 : 1.0)
        }
    }

    var volumeColor: Color {
        if volume > 1.5 { return .red }
        if volume > 1.0 { return .orange }
        if volume < 0.3 { return .yellow }
        return .green
    }
}
