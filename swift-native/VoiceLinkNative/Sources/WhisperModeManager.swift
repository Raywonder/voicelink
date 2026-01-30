import Foundation
import AVFoundation
import SwiftUI
import Carbon.HIToolbox

/// VoiceLink Whisper Mode Manager
/// Enables private whisper conversations between two users
/// - Hold modifier key (Cmd/Ctrl/Opt) or Enter to activate whisper mode
/// - Double-tap modifier to toggle whisper on/off
/// - Ducks other users' audio by -20dB with 1kHz lowpass filter
/// - 30ms fade in/out to prevent audio pops
class WhisperModeManager: ObservableObject {
    static let shared = WhisperModeManager()

    // State
    @Published var isWhispering = false
    @Published var whisperTargetUserId: String?
    @Published var whisperTargetUsername: String?

    // Settings
    struct WhisperSettings: Codable, Equatable {
        var duckingLevelDb: Float = -20      // -20dB ducking for other users
        var lowpassFrequency: Float = 1000   // 1kHz lowpass filter
        var fadeTimeSeconds: Float = 0.03    // 30ms fade
        var filterQ: Float = 0.7             // Filter Q factor

        // Key binding settings
        var activationMode: WhisperActivationMode = .holdToWhisper
        var primaryKeyType: WhisperKeyType = .enter
        var modifierKey: ModifierKeyOption = .command
        var doubleTapInterval: TimeInterval = 0.3  // Max time between taps for double-tap
        var useEnterKey: Bool = true               // Also respond to Enter key
    }

    enum WhisperActivationMode: String, Codable, CaseIterable {
        case holdToWhisper = "hold"        // Hold key to whisper
        case doubleTapToggle = "doubleTap" // Double-tap to toggle on/off
        case singleTapToggle = "singleTap" // Single-tap to toggle on/off
    }

    enum WhisperKeyType: String, Codable, CaseIterable {
        case enter = "Enter"
        case modifier = "Modifier Key"
    }

    enum ModifierKeyOption: String, Codable, CaseIterable {
        case command = "Command (⌘)"
        case control = "Control (⌃)"
        case option = "Option (⌥)"
        case shift = "Shift (⇧)"

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .command: return .command
            case .control: return .control
            case .option: return .option
            case .shift: return .shift
            }
        }

        var symbol: String {
            switch self {
            case .command: return "⌘"
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            }
        }
    }

    @Published var settings = WhisperSettings()

    // Audio engine reference
    private weak var audioEngine: AVAudioEngine?

    // Original gains storage for restoration
    private var originalGains: [String: Float] = [:]

    // Key state
    private var isKeyPressed = false
    private var isModifierPressed = false
    private var lastModifierTapTime: Date?
    private var modifierMonitor: Any?
    private var keyMonitor: Any?

    // Event handlers for UI updates
    var onWhisperStart: ((String, String?) -> Void)?
    var onWhisperStop: (() -> Void)?
    var onTargetChange: ((String?, String?) -> Void)?

    init() {
        loadSettings()
        setupKeyboardMonitoring()
    }

    // MARK: - Configuration

    func configure(audioEngine: AVAudioEngine) {
        self.audioEngine = audioEngine
    }

    // MARK: - Target Management

    /// Set the whisper target user
    func setWhisperTarget(userId: String, username: String? = nil) {
        whisperTargetUserId = userId
        whisperTargetUsername = username
        onTargetChange?(userId, username)
        print("WhisperModeManager: Target set to \(username ?? userId)")
    }

    /// Clear the whisper target
    func clearWhisperTarget() {
        whisperTargetUserId = nil
        whisperTargetUsername = nil
        onTargetChange?(nil, nil)
    }

    // MARK: - Whisper Control

    /// Start whispering to the target user
    /// Ducks all other users' audio with lowpass filter
    func startWhisper() {
        guard !isWhispering else { return }
        guard whisperTargetUserId != nil else {
            print("WhisperModeManager: No target set")
            return
        }

        isWhispering = true

        // Play start sound
        AppSoundManager.shared.playWhisperStartSound()

        // Duck other users' audio
        duckOtherUsers()

        // Notify UI
        DispatchQueue.main.async {
            self.onWhisperStart?(self.whisperTargetUserId!, self.whisperTargetUsername)
        }

        print("WhisperModeManager: Started whispering to \(whisperTargetUsername ?? whisperTargetUserId!)")
    }

    /// Stop whispering - restore all audio to normal
    func stopWhisper() {
        guard isWhispering else { return }

        isWhispering = false

        // Play stop sound
        AppSoundManager.shared.playWhisperStopSound()

        // Restore other users' audio
        restoreOtherUsers()

        // Notify UI
        DispatchQueue.main.async {
            self.onWhisperStop?()
        }

        print("WhisperModeManager: Stopped whispering")
    }

    // MARK: - Audio Ducking

    private func duckOtherUsers() {
        // Get all connected users from ServerManager
        let roomUsers = ServerManager.shared.currentRoomUsers

        for user in roomUsers {
            // Skip the whisper target - they should hear us clearly
            if user.odId == whisperTargetUserId { continue }

            // Store original gain (default to 1.0)
            originalGains[user.odId] = 1.0

            // Apply ducking - in a real implementation this would
            // modify the audio node gains via WebRTC or audio engine
            applyDucking(to: user.odId)
        }
    }

    private func applyDucking(to userId: String) {
        // Calculate linear gain from dB
        let linearLevel = pow(10, settings.duckingLevelDb / 20) // -20dB = 0.1

        // In a real implementation, this would:
        // 1. Get the audio node for this user
        // 2. Apply fade to the new gain level over fadeTimeSeconds
        // 3. Insert a lowpass filter at lowpassFrequency

        // Send ducking state to server for WebRTC adjustments
        NotificationCenter.default.post(
            name: .whisperDuckUser,
            object: nil,
            userInfo: [
                "userId": userId,
                "duckLevel": linearLevel,
                "lowpassFreq": settings.lowpassFrequency
            ]
        )
    }

    private func restoreOtherUsers() {
        for (userId, originalGain) in originalGains {
            // Restore original gain with fade
            NotificationCenter.default.post(
                name: .whisperRestoreUser,
                object: nil,
                userInfo: [
                    "userId": userId,
                    "gain": originalGain
                ]
            )
        }
        originalGains.removeAll()
    }

    // MARK: - Keyboard Monitoring

    private func setupKeyboardMonitoring() {
        stopKeyboardMonitoring()

        // Monitor for Enter key press (push-to-whisper)
        if settings.useEnterKey || settings.primaryKeyType == .enter {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self = self else { return event }

                // Enter key code is 36
                guard event.keyCode == 36 else { return event }

                // Don't trigger if in text field
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }

                guard self.whisperTargetUserId != nil else { return event }

                if event.type == .keyDown && !self.isKeyPressed {
                    self.isKeyPressed = true
                    self.handleWhisperActivation(isPress: true, isEnterKey: true)
                    return nil // Consume the event
                } else if event.type == .keyUp && self.isKeyPressed {
                    self.isKeyPressed = false
                    self.handleWhisperActivation(isPress: false, isEnterKey: true)
                    return nil
                }
                return event
            }
        }

        // Monitor for modifier key press
        if settings.primaryKeyType == .modifier {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self = self else { return event }
                guard self.whisperTargetUserId != nil else { return event }

                let modifierFlag = self.settings.modifierKey.flag
                let isPressed = event.modifierFlags.contains(modifierFlag)

                // Detect press/release
                if isPressed && !self.isModifierPressed {
                    self.isModifierPressed = true
                    self.handleModifierPress()
                } else if !isPressed && self.isModifierPressed {
                    self.isModifierPressed = false
                    self.handleModifierRelease()
                }

                return event
            }
        }

        print("WhisperModeManager: Keyboard monitoring configured (mode: \(settings.activationMode.rawValue), key: \(settings.primaryKeyType.rawValue))")
    }

    private func stopKeyboardMonitoring() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = modifierMonitor {
            NSEvent.removeMonitor(monitor)
            modifierMonitor = nil
        }
    }

    private func handleWhisperActivation(isPress: Bool, isEnterKey: Bool) {
        switch settings.activationMode {
        case .holdToWhisper:
            if isPress {
                startWhisper()
            } else {
                stopWhisper()
            }
        case .singleTapToggle:
            if isPress {
                toggleWhisper()
            }
        case .doubleTapToggle:
            // For Enter key in double-tap mode, treat as single toggle
            if isPress {
                toggleWhisper()
            }
        }
    }

    private func handleModifierPress() {
        let now = Date()

        switch settings.activationMode {
        case .holdToWhisper:
            startWhisper()

        case .singleTapToggle:
            // Will toggle on release
            break

        case .doubleTapToggle:
            // Check for double-tap
            if let lastTap = lastModifierTapTime,
               now.timeIntervalSince(lastTap) < settings.doubleTapInterval {
                // Double-tap detected
                toggleWhisper()
                lastModifierTapTime = nil
            } else {
                lastModifierTapTime = now
            }
        }
    }

    private func handleModifierRelease() {
        switch settings.activationMode {
        case .holdToWhisper:
            stopWhisper()

        case .singleTapToggle:
            toggleWhisper()

        case .doubleTapToggle:
            // Already handled in press
            break
        }
    }

    /// Toggle whisper on/off
    func toggleWhisper() {
        if isWhispering {
            stopWhisper()
        } else {
            startWhisper()
        }
    }

    /// Update settings and reconfigure monitoring
    func updateSettings(_ newSettings: WhisperSettings) {
        settings = newSettings
        saveSettings()
        setupKeyboardMonitoring()
    }

    // MARK: - Status

    func getStatus() -> [String: Any] {
        return [
            "isWhispering": isWhispering,
            "targetUserId": whisperTargetUserId ?? "",
            "targetUsername": whisperTargetUsername ?? "",
            "settings": [
                "duckingLevelDb": settings.duckingLevelDb,
                "lowpassFrequency": settings.lowpassFrequency,
                "fadeTimeSeconds": settings.fadeTimeSeconds
            ]
        ]
    }

    // MARK: - Persistence

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "whisperSettings"),
           let decoded = try? JSONDecoder().decode(WhisperSettings.self, from: data) {
            settings = decoded
        }
    }

    private func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: "whisperSettings")
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        if isWhispering {
            stopWhisper()
        }
        clearWhisperTarget()
        originalGains.removeAll()
        stopKeyboardMonitoring()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let whisperDuckUser = Notification.Name("whisperDuckUser")
    static let whisperRestoreUser = Notification.Name("whisperRestoreUser")
}

// MARK: - SwiftUI Views

struct WhisperModeIndicator: View {
    @ObservedObject var whisperManager = WhisperModeManager.shared

    var body: some View {
        if whisperManager.isWhispering {
            HStack(spacing: 8) {
                Image(systemName: "ear.fill")
                    .foregroundColor(.purple)

                Text("Whispering to \(whisperManager.whisperTargetUsername ?? "user")")
                    .font(.caption)
                    .foregroundColor(.purple)

                // Pulsing indicator
                Circle()
                    .fill(Color.purple)
                    .frame(width: 8, height: 8)
                    .opacity(0.8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.purple.opacity(0.2))
            .cornerRadius(20)
        }
    }
}

/// Whisper Mode Settings View
struct WhisperSettingsView: View {
    @ObservedObject var whisperManager = WhisperModeManager.shared
    @State private var localSettings: WhisperModeManager.WhisperSettings

    init() {
        _localSettings = State(initialValue: WhisperModeManager.shared.settings)
    }

    var body: some View {
        Form {
            Section("Whisper Activation") {
                Picker("Activation Mode", selection: $localSettings.activationMode) {
                    ForEach(WhisperModeManager.WhisperActivationMode.allCases, id: \.self) { mode in
                        Text(modeDescription(mode)).tag(mode)
                    }
                }
                .help("How whisper mode is activated")

                Picker("Primary Key", selection: $localSettings.primaryKeyType) {
                    ForEach(WhisperModeManager.WhisperKeyType.allCases, id: \.self) { keyType in
                        Text(keyType.rawValue).tag(keyType)
                    }
                }

                if localSettings.primaryKeyType == .modifier {
                    Picker("Modifier Key", selection: $localSettings.modifierKey) {
                        ForEach(WhisperModeManager.ModifierKeyOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }

                if localSettings.primaryKeyType == .modifier {
                    Toggle("Also use Enter key", isOn: $localSettings.useEnterKey)
                        .help("Allow Enter key as alternative whisper activation")
                }

                if localSettings.activationMode == .doubleTapToggle {
                    HStack {
                        Text("Double-tap interval:")
                        Slider(value: $localSettings.doubleTapInterval, in: 0.2...0.5, step: 0.05)
                        Text("\(Int(localSettings.doubleTapInterval * 1000))ms")
                            .frame(width: 50)
                    }
                }
            }

            Section("Audio Settings") {
                HStack {
                    Text("Ducking level:")
                    Slider(value: $localSettings.duckingLevelDb, in: -40...0, step: 1)
                    Text("\(Int(localSettings.duckingLevelDb)) dB")
                        .frame(width: 55)
                }
                .help("How much to reduce other users' volume when whispering")

                HStack {
                    Text("Lowpass filter:")
                    Slider(value: $localSettings.lowpassFrequency, in: 500...4000, step: 100)
                    Text("\(Int(localSettings.lowpassFrequency)) Hz")
                        .frame(width: 65)
                }
                .help("Muffles non-target users' audio")
            }

            Section("How to Use") {
                VStack(alignment: .leading, spacing: 8) {
                    keyInstructions
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: localSettings) { newValue in
            whisperManager.updateSettings(newValue)
        }
    }

    private func modeDescription(_ mode: WhisperModeManager.WhisperActivationMode) -> String {
        switch mode {
        case .holdToWhisper: return "Hold to Whisper"
        case .doubleTapToggle: return "Double-Tap to Toggle"
        case .singleTapToggle: return "Single-Tap to Toggle"
        }
    }

    @ViewBuilder
    private var keyInstructions: some View {
        switch localSettings.activationMode {
        case .holdToWhisper:
            if localSettings.primaryKeyType == .modifier {
                Text("Hold \(localSettings.modifierKey.symbol) to whisper, release to stop")
                if localSettings.useEnterKey {
                    Text("Or hold Enter key")
                }
            } else {
                Text("Hold Enter to whisper, release to stop")
            }
        case .doubleTapToggle:
            if localSettings.primaryKeyType == .modifier {
                Text("Double-tap \(localSettings.modifierKey.symbol) to toggle whisper on/off")
            } else {
                Text("Press Enter to toggle whisper on/off")
            }
        case .singleTapToggle:
            if localSettings.primaryKeyType == .modifier {
                Text("Press \(localSettings.modifierKey.symbol) once to toggle whisper on/off")
            } else {
                Text("Press Enter to toggle whisper on/off")
            }
        }
        Text("First select a user to whisper to from the user list")
    }
}
