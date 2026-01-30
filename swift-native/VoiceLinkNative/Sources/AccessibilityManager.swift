import SwiftUI
import AVFoundation
import Combine
import AppKit

// MARK: - Priority Level (Custom since NSAccessibility.PriorityLevel doesn't exist in public API)
enum PriorityLevel: Int {
    case low = 0
    case medium = 1
    case high = 2
}

// MARK: - Announcement Priority
enum AnnouncementPriority: String {
    case polite = "polite"
    case assertive = "assertive"
    case status = "status"

    var interruptionPolicy: PriorityLevel {
        switch self {
        case .polite: return .medium
        case .assertive: return .high
        case .status: return .low
        }
    }
}

// MARK: - Announcement Category
enum AnnouncementCategory: String, CaseIterable {
    case navigation = "navigation"
    case roomEvents = "roomEvents"
    case userActions = "userActions"
    case errors = "errors"
    case success = "success"
    case status = "status"
    case audio = "audio"
    case connection = "connection"
}

// MARK: - Accessibility Settings
struct AccessibilitySettings: Codable {
    var announcements: Bool = true
    var soundCues: Bool = true
    var ttsAnnouncements: Bool = true
    var reduceMotion: Bool = false
    var highContrast: Bool = false
    var largeText: Bool = false

    var announceNavigation: Bool = true
    var announceActions: Bool = true
    var announceStatus: Bool = true
    var announceRoomEvents: Bool = true
    var announceErrors: Bool = true

    // TTS settings
    var ttsRate: Float = 0.5
    var ttsPitch: Float = 1.0
    var ttsVolume: Float = 0.8
    var ttsVoiceId: String?

    // Category toggles
    var categorySettings: [String: Bool] = [:]

    init() {
        // Initialize all categories as enabled
        for category in AnnouncementCategory.allCases {
            categorySettings[category.rawValue] = true
        }
    }
}

// MARK: - Accessibility Manager
class AccessibilityManager: ObservableObject {
    static let shared = AccessibilityManager()

    // Settings
    @Published var settings = AccessibilitySettings()

    // TTS
    private var synthesizer = AVSpeechSynthesizer()
    @Published var availableVoices: [AVSpeechSynthesisVoice] = []
    @Published var isSpeaking: Bool = false

    // VoiceOver status
    @Published var isVoiceOverRunning: Bool = false

    // Announcement queue
    private var announcementQueue: [(String, AnnouncementPriority)] = []
    private var isProcessingQueue: Bool = false

    // Sound manager reference
    private var soundManager: UISoundManager?

    // Cancellables
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadSettings()
        loadVoices()
        setupObservers()
        checkVoiceOverStatus()
    }

    // MARK: - Setup

    private func loadVoices() {
        availableVoices = AVSpeechSynthesisVoice.speechVoices()
    }

    private func setupObservers() {
        // Observe VoiceOver status changes
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(voiceOverStatusChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        // Observe system accessibility settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilitySettingsChanged),
            name: NSNotification.Name("NSAccessibilityReduceMotionStatusDidChangeNotification"),
            object: nil
        )
    }

    @objc private func voiceOverStatusChanged() {
        checkVoiceOverStatus()
    }

    @objc private func accessibilitySettingsChanged() {
        // Update reduce motion setting
        settings.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        settings.highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private func checkVoiceOverStatus() {
        isVoiceOverRunning = NSWorkspace.shared.isVoiceOverEnabled
    }

    // MARK: - Sound Manager

    func setSoundManager(_ manager: UISoundManager) {
        self.soundManager = manager
    }

    // MARK: - Core Announcement Methods

    func announce(_ message: String, priority: AnnouncementPriority = .polite, withSound: Bool = false, category: AnnouncementCategory? = nil) {
        guard settings.announcements else { return }

        // Check category settings
        if let cat = category, settings.categorySettings[cat.rawValue] == false {
            return
        }

        print("[Accessibility] (\(priority.rawValue)) \(message)")

        // Post to VoiceOver
        postToVoiceOver(message, priority: priority)

        // Play sound cue if enabled
        if withSound && settings.soundCues {
            playSoundCue(for: priority)
        }

        // TTS announcement if enabled
        if settings.ttsAnnouncements && !isVoiceOverRunning {
            speak(message, interrupt: priority == .assertive)
        }
    }

    private func postToVoiceOver(_ message: String, priority: AnnouncementPriority) {
        // Use NSAccessibility to post announcement
        let announcement = NSAccessibility.Announcement(
            announcementString: message,
            priority: priority.interruptionPolicy
        )

        NSAccessibility.post(
            element: NSApp,
            notification: .announcementRequested,
            userInfo: [.announcement: announcement]
        )
    }

    private func playSoundCue(for priority: AnnouncementPriority) {
        switch priority {
        case .assertive:
            NSSound.beep()
        case .polite, .status:
            soundManager?.playNotificationSound()
        }
    }

    // MARK: - TTS

    private func speak(_ message: String, interrupt: Bool = false) {
        if interrupt {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = settings.ttsRate
        utterance.pitchMultiplier = settings.ttsPitch
        utterance.volume = settings.ttsVolume

        if let voiceId = settings.ttsVoiceId,
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            utterance.voice = voice
        }

        synthesizer.speak(utterance)
    }

    func testTTS(_ message: String = "This is a test of the text-to-speech system") {
        speak(message, interrupt: true)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Navigation Announcements

    func announceNavigation(to screen: String, description: String? = nil) {
        guard settings.announceNavigation else { return }

        var message = "Navigated to \(screen)"
        if let desc = description {
            message += ". \(desc)"
        }

        announce(message, priority: .polite, withSound: true, category: .navigation)
    }

    func announceMainScreen() {
        announceNavigation(
            to: "Main Menu",
            description: "Choose to create a new room, join an existing room, or access settings"
        )
    }

    func announceRoomCreation() {
        announceNavigation(
            to: "Room Creation",
            description: "Fill in the form to create a new room and press Create to proceed"
        )
    }

    func announceRoomJoin() {
        announceNavigation(
            to: "Join Room",
            description: "Enter the room ID and your name to join an existing room"
        )
    }

    func announceSettings() {
        announceNavigation(
            to: "Settings",
            description: "Configure audio, accessibility, and other application preferences"
        )
    }

    func announceRoomScreen(roomName: String) {
        announceNavigation(
            to: "Voice Room",
            description: "You are now in room: \(roomName). Use spacebar to push-to-talk"
        )
    }

    // MARK: - Action Announcements

    func announceAction(_ action: String, result: String? = nil) {
        guard settings.announceActions else { return }

        var message = action
        if let res = result {
            message += ". \(res)"
        }

        announce(message, priority: .polite, category: .userActions)
    }

    // MARK: - Status Announcements

    func announceStatus(_ status: String, isUrgent: Bool = false) {
        guard settings.announceStatus else { return }

        let priority: AnnouncementPriority = isUrgent ? .assertive : .status
        announce(status, priority: priority, withSound: isUrgent, category: .status)
    }

    // MARK: - Error/Success Announcements

    func announceError(_ error: String) {
        guard settings.announceErrors else { return }
        announce("Error: \(error)", priority: .assertive, withSound: true, category: .errors)
    }

    func announceSuccess(_ message: String) {
        announce("Success: \(message)", priority: .polite, withSound: true, category: .success)
    }

    // MARK: - Room Event Announcements

    func announceRoomCreated(name: String, id: String) {
        guard settings.announceRoomEvents else { return }
        announceSuccess("Room '\(name)' created successfully with ID: \(id). You have been automatically joined")
    }

    func announceRoomJoined(name: String) {
        guard settings.announceRoomEvents else { return }
        announceSuccess("Successfully joined room: \(name)")
    }

    func announceRoomLeft() {
        guard settings.announceRoomEvents else { return }
        announceAction("Left room", result: "Returned to main menu")
    }

    func announceUserJoined(_ userName: String) {
        guard settings.announceRoomEvents else { return }
        announce("\(userName) joined the room", priority: .status, category: .roomEvents)
    }

    func announceUserLeft(_ userName: String) {
        guard settings.announceRoomEvents else { return }
        announce("\(userName) left the room", priority: .status, category: .roomEvents)
    }

    // MARK: - Connection Status

    func announceConnectionStatus(_ status: String) {
        let messages: [String: String] = [
            "connected": "Connected to server",
            "disconnected": "Disconnected from server",
            "connecting": "Connecting to server",
            "error": "Connection error occurred"
        ]

        let message = messages[status] ?? status
        let isError = status == "error"

        announce(message, priority: isError ? .assertive : .status, withSound: isError, category: .connection)
    }

    // MARK: - Audio Status

    func announceAudioStatus(_ status: String) {
        let messages: [String: String] = [
            "muted": "Microphone muted",
            "unmuted": "Microphone unmuted",
            "deafened": "Audio deafened - you cannot hear others",
            "undeafened": "Audio undeafened - you can now hear others"
        ]

        announce(messages[status] ?? status, priority: .status, category: .audio)
    }

    // MARK: - Keyboard Help

    func announceKeyboardHelp() {
        let help = """
        Keyboard navigation help.
        Tab: Move to next element.
        Shift+Tab: Move to previous element.
        Return or Space: Activate buttons.
        Escape: Close dialogs or return to previous screen.
        Arrow keys: Navigate within lists.
        """

        announce(help, priority: .polite, withSound: true)
    }

    // MARK: - Focus Announcements

    func announceFocusedElement(_ element: NSAccessibilityProtocol) {
        guard let description = element.accessibilityValue() as? String else { return }

        var announcement = ""

        if let role = element.accessibilityRole() {
            announcement = role.rawValue
        }

        if let label = element.accessibilityLabel() {
            announcement += ": \(label)"
        } else if !description.isEmpty {
            announcement += ": \(description)"
        }

        if let element = element as? NSControl, !element.isEnabled {
            announcement += ", disabled"
        }

        announce(announcement, priority: .polite)
    }

    // MARK: - Settings Management

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "accessibility.settings"),
           let loaded = try? JSONDecoder().decode(AccessibilitySettings.self, from: data) {
            settings = loaded
        }

        // Also check system accessibility settings
        settings.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        settings.highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "accessibility.settings")
        }
    }

    func setEnabled(_ enabled: Bool) {
        settings.announcements = enabled
        settings.soundCues = enabled
        settings.ttsAnnouncements = enabled
        saveSettings()

        announce("Accessibility features \(enabled ? "enabled" : "disabled")", priority: .assertive, withSound: true)
    }

    func setCategoryEnabled(_ category: AnnouncementCategory, enabled: Bool) {
        settings.categorySettings[category.rawValue] = enabled
        saveSettings()
    }

    // MARK: - Page Load Announcement

    func announceAppLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.announce(
                "VoiceLink application loaded. Use Tab to navigate through the interface.",
                priority: .polite,
                withSound: true
            )
        }
    }
}

// MARK: - UI Sound Manager
class UISoundManager {
    static let shared = UISoundManager()

    private var notificationSound: NSSound?
    private var errorSound: NSSound?
    private var successSound: NSSound?

    init() {
        loadSounds()
    }

    private func loadSounds() {
        notificationSound = NSSound(named: "Pop")
        errorSound = NSSound(named: "Basso")
        successSound = NSSound(named: "Glass")
    }

    func playNotificationSound() {
        notificationSound?.play()
    }

    func playErrorSound() {
        errorSound?.play()
    }

    func playSuccessSound() {
        successSound?.play()
    }
}

// MARK: - Accessibility Settings View
struct AccessibilitySettingsView: View {
    @ObservedObject var manager = AccessibilityManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        Form {
            Section("General") {
                Toggle("Enable Announcements", isOn: $manager.settings.announcements)
                Toggle("Sound Cues", isOn: $manager.settings.soundCues)
                Toggle("Text-to-Speech Announcements", isOn: $manager.settings.ttsAnnouncements)
            }

            Section("Announcement Categories") {
                ForEach(AnnouncementCategory.allCases, id: \.rawValue) { category in
                    Toggle(category.rawValue.capitalized, isOn: Binding(
                        get: { manager.settings.categorySettings[category.rawValue] ?? true },
                        set: { manager.setCategoryEnabled(category, enabled: $0) }
                    ))
                }
            }

            Section("Text-to-Speech Settings") {
                HStack {
                    Text("Rate")
                    Slider(value: $manager.settings.ttsRate, in: 0.1...1.0)
                    Text("\(manager.settings.ttsRate, specifier: "%.1f")")
                        .frame(width: 35)
                }

                HStack {
                    Text("Pitch")
                    Slider(value: $manager.settings.ttsPitch, in: 0.5...2.0)
                    Text("\(manager.settings.ttsPitch, specifier: "%.1f")")
                        .frame(width: 35)
                }

                HStack {
                    Text("Volume")
                    Slider(value: $manager.settings.ttsVolume, in: 0.1...1.0)
                    Text("\(manager.settings.ttsVolume, specifier: "%.1f")")
                        .frame(width: 35)
                }

                Picker("Voice", selection: $manager.settings.ttsVoiceId) {
                    Text("Default").tag(nil as String?)
                    ForEach(manager.availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier as String?)
                    }
                }

                Button("Test Voice") {
                    manager.testTTS()
                }
            }

            Section("Visual Accessibility") {
                Toggle("Reduce Motion", isOn: $manager.settings.reduceMotion)
                    .help("Uses system setting when available")
                Toggle("High Contrast", isOn: $manager.settings.highContrast)
                    .help("Uses system setting when available")
                Toggle("Large Text", isOn: $manager.settings.largeText)
            }

            Section("VoiceOver") {
                HStack {
                    Text("VoiceOver Status:")
                    Spacer()
                    Text(manager.isVoiceOverRunning ? "Running" : "Not Running")
                        .foregroundColor(manager.isVoiceOverRunning ? .green : .secondary)
                }

                Button("Announce Keyboard Help") {
                    manager.announceKeyboardHelp()
                }
            }
        }
        .padding()
        .frame(width: 500, height: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    manager.saveSettings()
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Accessibility Modifier
struct AccessibilityAnnouncementModifier: ViewModifier {
    let message: String
    let priority: AnnouncementPriority

    func body(content: Content) -> some View {
        content.onAppear {
            AccessibilityManager.shared.announce(message, priority: priority)
        }
    }
}

extension View {
    func accessibilityAnnounce(_ message: String, priority: AnnouncementPriority = .polite) -> some View {
        modifier(AccessibilityAnnouncementModifier(message: message, priority: priority))
    }
}

// MARK: - Accessibility Screen View Modifier
struct AccessibilityScreenModifier: ViewModifier {
    let screenName: String
    let description: String?

    func body(content: Content) -> some View {
        content.onAppear {
            AccessibilityManager.shared.announceNavigation(to: screenName, description: description)
        }
    }
}

extension View {
    func accessibilityScreen(_ name: String, description: String? = nil) -> some View {
        modifier(AccessibilityScreenModifier(screenName: name, description: description))
    }
}

// MARK: - NSAccessibility Announcement Extension
extension NSAccessibility {
    struct Announcement {
        let announcementString: String
        let priority: PriorityLevel
    }
}
