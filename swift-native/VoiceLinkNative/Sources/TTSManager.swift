import SwiftUI
import AVFoundation
import Combine

// MARK: - TTS Voice Info
struct TTSVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let gender: VoiceGender
    let quality: VoiceQuality
    let identifier: String

    enum VoiceGender: String {
        case male = "male"
        case female = "female"
        case neutral = "neutral"
    }

    enum VoiceQuality: String {
        case premium = "premium"
        case enhanced = "enhanced"
        case standard = "standard"
        case compact = "compact"
    }

    var displayName: String {
        "\(name) (\(language))"
    }

    init(from voice: AVSpeechSynthesisVoice) {
        self.id = voice.identifier
        self.name = voice.name
        self.language = voice.language
        self.identifier = voice.identifier
        self.gender = Self.detectGender(from: voice.name)
        self.quality = Self.detectQuality(from: voice.name, qualityValue: voice.quality)
    }

    private static func detectGender(from name: String) -> VoiceGender {
        let lowercased = name.lowercased()
        let femaleNames = ["female", "woman", "girl", "sara", "samantha", "alex", "alice", "emma", "victoria", "zoe", "siri female", "ava", "allison"]
        let maleNames = ["male", "man", "boy", "daniel", "thomas", "fred", "george", "nathan", "arthur", "siri male", "aaron", "tom"]

        for femaleName in femaleNames {
            if lowercased.contains(femaleName) { return .female }
        }
        for maleName in maleNames {
            if lowercased.contains(maleName) { return .male }
        }
        return .neutral
    }

    private static func detectQuality(from name: String, qualityValue: AVSpeechSynthesisVoiceQuality) -> VoiceQuality {
        switch qualityValue {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default:
            let lowercased = name.lowercased()
            if lowercased.contains("compact") { return .compact }
            return .standard
        }
    }
}

// MARK: - Announcement Type
enum AnnouncementType: String, CaseIterable, Identifiable {
    case user = "user"
    case admin = "admin"
    case system = "system"
    case emergency = "emergency"
    case celebration = "celebration"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .user: return "User Announcement"
        case .admin: return "Admin Announcement"
        case .system: return "System Notification"
        case .emergency: return "Emergency Alert"
        case .celebration: return "Celebration"
        }
    }

    var prefix: String {
        switch self {
        case .user: return "Attention all users"
        case .admin: return "Administrator announcement"
        case .system: return "System notification"
        case .emergency: return "Emergency alert"
        case .celebration: return "Congratulations"
        }
    }

    var icon: String {
        switch self {
        case .user: return "megaphone.fill"
        case .admin: return "person.badge.shield.checkmark.fill"
        case .system: return "gear.circle.fill"
        case .emergency: return "exclamationmark.triangle.fill"
        case .celebration: return "party.popper.fill"
        }
    }

    var color: Color {
        switch self {
        case .user: return .blue
        case .admin: return .purple
        case .system: return .gray
        case .emergency: return .red
        case .celebration: return .orange
        }
    }
}

// MARK: - Delivery Method
enum DeliveryMethod: String, CaseIterable, Identifiable {
    case global = "global"
    case room = "room"
    case direct = "direct"
    case proximity = "proximity"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global: return "Global Broadcast"
        case .room: return "Current Room Only"
        case .direct: return "Direct to Selected Users"
        case .proximity: return "Proximity-based"
        }
    }
}

// MARK: - Audio Effect
enum TTSAudioEffect: String, CaseIterable, Identifiable {
    case none = "none"
    case radioVoice = "radio_voice"
    case podcastVoice = "podcast_voice"
    case emergencyAlert = "emergency_alert"
    case intercomClassic = "intercom_classic"
    case robotVoice = "robot_voice"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "No Effects"
        case .radioVoice: return "Radio Voice"
        case .podcastVoice: return "Podcast Voice"
        case .emergencyAlert: return "Emergency Alert"
        case .intercomClassic: return "Intercom Classic"
        case .robotVoice: return "Robot Voice"
        }
    }
}

// MARK: - Announcement
struct Announcement: Identifiable {
    let id: String
    let type: AnnouncementType
    var text: String
    var voiceId: String?
    var effect: TTSAudioEffect
    var delivery: DeliveryMethod
    var targetUsers: [String]?
    let timestamp: Date

    init(
        id: String = UUID().uuidString,
        type: AnnouncementType,
        text: String,
        voiceId: String? = nil,
        effect: TTSAudioEffect = .none,
        delivery: DeliveryMethod = .global,
        targetUsers: [String]? = nil
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.voiceId = voiceId
        self.effect = effect
        self.delivery = delivery
        self.targetUsers = targetUsers
        self.timestamp = Date()
    }

    var fullText: String {
        "\(type.prefix). \(text)"
    }
}

// MARK: - Predefined Announcement
struct PredefinedAnnouncement: Identifiable {
    let id: String
    let name: String
    let type: AnnouncementType
    let text: String
    let effect: TTSAudioEffect

    init(_ id: String, name: String, type: AnnouncementType, text: String, effect: TTSAudioEffect = .radioVoice) {
        self.id = id
        self.name = name
        self.type = type
        self.text = text
        self.effect = effect
    }
}

// MARK: - TTS Configuration
struct TTSConfiguration: Codable {
    var rate: Float = 0.5
    var pitch: Float = 1.0
    var volume: Float = 1.0
    var language: String = "en-US"
    var enableEffects: Bool = true
    var selectedVoiceId: String?
    var announcementPrefix: String = "Attention all users"
    var adminPrefix: String = "Administrator announcement"
    var emergencyPrefix: String = "Emergency alert"
    var systemPrefix: String = "System notification"
}

// MARK: - TTS Manager
class TTSManager: NSObject, ObservableObject {
    static let shared = TTSManager()

    // Synthesizer
    private var synthesizer = AVSpeechSynthesizer()

    // Configuration
    @Published var config = TTSConfiguration()

    // Voices
    @Published var availableVoices: [TTSVoice] = []
    @Published var selectedVoice: TTSVoice?

    // Queue
    @Published var announcementQueue: [Announcement] = []
    @Published var isAnnouncing: Bool = false
    @Published var currentAnnouncement: Announcement?

    // Predefined announcements
    let predefinedAnnouncements: [PredefinedAnnouncement]

    // Audio engine for effects
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    override init() {
        // Initialize predefined announcements
        self.predefinedAnnouncements = [
            // System
            PredefinedAnnouncement("server_maintenance", name: "Server Maintenance", type: .system,
                text: "Server maintenance will begin in 5 minutes. Please save your work and prepare to disconnect."),
            PredefinedAnnouncement("server_restart", name: "Server Restart", type: .system,
                text: "The server will restart in 60 seconds. All users will be disconnected."),
            PredefinedAnnouncement("backup_starting", name: "Backup Starting", type: .system,
                text: "Automated backup process starting. You may experience brief audio interruptions."),

            // Admin
            PredefinedAnnouncement("meeting_starting", name: "Meeting Starting", type: .admin,
                text: "The scheduled meeting will begin in 2 minutes. Please join the main conference room.", effect: .podcastVoice),
            PredefinedAnnouncement("quiet_hours", name: "Quiet Hours", type: .admin,
                text: "Quiet hours are now in effect. Please keep voice communication to a minimum.", effect: .podcastVoice),
            PredefinedAnnouncement("new_user_welcome", name: "Welcome New User", type: .admin,
                text: "Welcome to VoiceLink. Please review the user guidelines and configure your audio settings.", effect: .podcastVoice),

            // Emergency
            PredefinedAnnouncement("fire_drill", name: "Fire Drill", type: .emergency,
                text: "This is a fire drill. Please log off immediately and proceed to your designated assembly point.", effect: .emergencyAlert),
            PredefinedAnnouncement("security_breach", name: "Security Alert", type: .emergency,
                text: "Security alert. Unauthorized access detected. All users must verify their identity.", effect: .emergencyAlert),
            PredefinedAnnouncement("system_failure", name: "System Failure", type: .emergency,
                text: "Critical system failure detected. Please disconnect immediately to prevent data loss.", effect: .emergencyAlert),

            // User tips
            PredefinedAnnouncement("audio_test_reminder", name: "Audio Test Reminder", type: .user,
                text: "Remember to test your audio settings regularly for the best voice chat experience."),
            PredefinedAnnouncement("spatial_audio_tip", name: "Spatial Audio Tip", type: .user,
                text: "Tip: Enable 3D spatial audio for a more immersive voice chat experience."),
            PredefinedAnnouncement("keyboard_shortcuts", name: "Keyboard Shortcuts", type: .user,
                text: "Press Control for global announcements, Command for direct messages, and Shift for whisper mode."),

            // Celebrations
            PredefinedAnnouncement("birthday", name: "Birthday Celebration", type: .celebration,
                text: "Happy birthday! The community wishes you a wonderful day filled with great conversations."),
            PredefinedAnnouncement("milestone", name: "Milestone Reached", type: .celebration,
                text: "Congratulations! The server has reached a new milestone of active users.")
        ]

        super.init()

        synthesizer.delegate = self
        loadVoices()
        loadConfiguration()
    }

    // MARK: - Voice Management

    private func loadVoices() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        availableVoices = voices.map { TTSVoice(from: $0) }

        // Set default voice
        if let defaultVoice = availableVoices.first(where: { $0.language.starts(with: config.language.prefix(2)) }) {
            selectedVoice = defaultVoice
        } else if let firstVoice = availableVoices.first {
            selectedVoice = firstVoice
        }
    }

    func selectVoice(_ voice: TTSVoice) {
        selectedVoice = voice
        config.selectedVoiceId = voice.identifier
        saveConfiguration()
    }

    func getVoices(for language: String) -> [TTSVoice] {
        availableVoices.filter { $0.language.starts(with: language.prefix(2)) }
    }

    // MARK: - Announcement Queue

    func queueAnnouncement(_ announcement: Announcement) {
        announcementQueue.append(announcement)

        if !isAnnouncing {
            processQueue()
        }
    }

    func queuePredefined(_ predefined: PredefinedAnnouncement, delivery: DeliveryMethod = .global) {
        let announcement = Announcement(
            id: "\(predefined.id)_\(Date().timeIntervalSince1970)",
            type: predefined.type,
            text: predefined.text,
            effect: predefined.effect,
            delivery: delivery
        )
        queueAnnouncement(announcement)
    }

    func removeFromQueue(at index: Int) {
        guard index < announcementQueue.count else { return }
        announcementQueue.remove(at: index)
    }

    func clearQueue() {
        announcementQueue.removeAll()
    }

    // MARK: - Speech Synthesis

    private func processQueue() {
        guard !announcementQueue.isEmpty, !isAnnouncing else { return }

        isAnnouncing = true
        let announcement = announcementQueue.removeFirst()
        currentAnnouncement = announcement

        speak(announcement)
    }

    private func speak(_ announcement: Announcement) {
        let utterance = AVSpeechUtterance(string: announcement.fullText)

        // Configure voice
        if let voiceId = announcement.voiceId ?? selectedVoice?.identifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice(language: config.language) {
            utterance.voice = voice
        }

        // Configure speech parameters
        utterance.rate = config.rate
        utterance.pitchMultiplier = config.pitch
        utterance.volume = config.volume

        // Apply effect modifications
        applyEffect(announcement.effect, to: utterance)

        synthesizer.speak(utterance)
    }

    private func applyEffect(_ effect: TTSAudioEffect, to utterance: AVSpeechUtterance) {
        switch effect {
        case .none:
            break
        case .radioVoice:
            utterance.pitchMultiplier *= 0.9
            utterance.rate *= 1.1
        case .podcastVoice:
            utterance.pitchMultiplier *= 0.95
            utterance.rate *= 0.95
        case .emergencyAlert:
            utterance.pitchMultiplier *= 1.1
            utterance.rate *= 1.2
            utterance.volume = min(utterance.volume * 1.2, 1.0)
        case .intercomClassic:
            utterance.pitchMultiplier *= 0.85
            utterance.rate *= 0.9
        case .robotVoice:
            utterance.pitchMultiplier *= 0.8
            utterance.rate *= 0.85
        }
    }

    func preview(_ text: String, voice: TTSVoice? = nil, effect: TTSAudioEffect = .none) {
        stopSpeaking()

        let utterance = AVSpeechUtterance(string: text)

        if let voice = voice, let avVoice = AVSpeechSynthesisVoice(identifier: voice.identifier) {
            utterance.voice = avVoice
        } else if let selected = selectedVoice, let avVoice = AVSpeechSynthesisVoice(identifier: selected.identifier) {
            utterance.voice = avVoice
        }

        utterance.rate = config.rate
        utterance.pitchMultiplier = config.pitch
        utterance.volume = config.volume

        applyEffect(effect, to: utterance)

        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Configuration

    private func loadConfiguration() {
        if let data = UserDefaults.standard.data(forKey: "tts.config"),
           let loaded = try? JSONDecoder().decode(TTSConfiguration.self, from: data) {
            config = loaded

            // Restore selected voice
            if let voiceId = config.selectedVoiceId {
                selectedVoice = availableVoices.first { $0.identifier == voiceId }
            }
        }
    }

    func saveConfiguration() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "tts.config")
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension TTSManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.currentAnnouncement = nil
            self.isAnnouncing = false

            // Process next in queue after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.processQueue()
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.currentAnnouncement = nil
            self.isAnnouncing = false
        }
    }
}

// MARK: - TTS Settings View
struct TTSSettingsView: View {
    @ObservedObject var manager = TTSManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Text-to-Speech Settings")
                .font(.headline)

            Form {
                // Voice selection
                Section("Voice") {
                    Picker("Voice", selection: $manager.selectedVoice) {
                        ForEach(manager.availableVoices) { voice in
                            Text(voice.displayName).tag(voice as TTSVoice?)
                        }
                    }

                    Picker("Language", selection: $manager.config.language) {
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                        Text("Spanish").tag("es-ES")
                        Text("French").tag("fr-FR")
                        Text("German").tag("de-DE")
                        Text("Italian").tag("it-IT")
                        Text("Japanese").tag("ja-JP")
                        Text("Chinese").tag("zh-CN")
                    }
                }

                // Speech parameters
                Section("Speech") {
                    HStack {
                        Text("Rate")
                        Slider(value: $manager.config.rate, in: 0.1...1.0)
                        Text("\(manager.config.rate, specifier: "%.1f")")
                            .frame(width: 40)
                    }

                    HStack {
                        Text("Pitch")
                        Slider(value: $manager.config.pitch, in: 0.5...2.0)
                        Text("\(manager.config.pitch, specifier: "%.1f")")
                            .frame(width: 40)
                    }

                    HStack {
                        Text("Volume")
                        Slider(value: $manager.config.volume, in: 0.1...1.0)
                        Text("\(manager.config.volume, specifier: "%.1f")")
                            .frame(width: 40)
                    }
                }

                // Effects
                Section("Effects") {
                    Toggle("Enable Audio Effects", isOn: $manager.config.enableEffects)
                }

                // Prefixes
                Section("Announcement Prefixes") {
                    TextField("User Prefix", text: $manager.config.announcementPrefix)
                    TextField("Admin Prefix", text: $manager.config.adminPrefix)
                    TextField("Emergency Prefix", text: $manager.config.emergencyPrefix)
                    TextField("System Prefix", text: $manager.config.systemPrefix)
                }
            }

            HStack {
                Button("Test Voice") {
                    manager.preview("This is a test of the current voice settings.")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    manager.saveConfiguration()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500, height: 600)
    }
}

// MARK: - TTS Announcement View
struct TTSAnnouncementView: View {
    @ObservedObject var manager = TTSManager.shared
    @State private var selectedTab = 0
    @State private var customText = ""
    @State private var announcementType: AnnouncementType = .user
    @State private var deliveryMethod: DeliveryMethod = .global
    @State private var selectedEffect: TTSAudioEffect = .none

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "megaphone.fill")
                    .font(.title2)
                Text("Announcements")
                    .font(.headline)
                Spacer()

                if manager.isAnnouncing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Speaking...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(.controlBackgroundColor))

            // Tabs
            Picker("", selection: $selectedTab) {
                Text("Custom").tag(0)
                Text("Quick").tag(1)
                Text("Queue").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            // Content
            TabView(selection: $selectedTab) {
                // Custom Announcement
                customAnnouncementView
                    .tag(0)

                // Quick Announcements
                quickAnnouncementsView
                    .tag(1)

                // Queue
                queueView
                    .tag(2)
            }
            .tabViewStyle(.automatic)
        }
    }

    private var customAnnouncementView: some View {
        Form {
            Section("Message") {
                TextEditor(text: $customText)
                    .frame(height: 100)

                Text("\(customText.count)/500 characters")
                    .font(.caption)
                    .foregroundColor(customText.count > 500 ? .red : .secondary)
            }

            Section("Settings") {
                Picker("Type", selection: $announcementType) {
                    ForEach(AnnouncementType.allCases) { type in
                        Label(type.displayName, systemImage: type.icon).tag(type)
                    }
                }

                Picker("Delivery", selection: $deliveryMethod) {
                    ForEach(DeliveryMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }

                Picker("Effect", selection: $selectedEffect) {
                    ForEach(TTSAudioEffect.allCases) { effect in
                        Text(effect.displayName).tag(effect)
                    }
                }
            }

            Section {
                HStack {
                    Button("Preview") {
                        let fullText = "\(announcementType.prefix). \(customText)"
                        manager.preview(fullText, effect: selectedEffect)
                    }
                    .disabled(customText.isEmpty)

                    Spacer()

                    Button("Send") {
                        sendCustomAnnouncement()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(customText.isEmpty || customText.count > 500)
                }
            }
        }
        .padding()
    }

    private var quickAnnouncementsView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 12) {
                ForEach(manager.predefinedAnnouncements) { predefined in
                    PredefinedAnnouncementCard(announcement: predefined)
                }
            }
            .padding()
        }
    }

    private var queueView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Queue (\(manager.announcementQueue.count))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Clear All") {
                    manager.clearQueue()
                }
                .disabled(manager.announcementQueue.isEmpty)
            }
            .padding(.horizontal)

            if manager.announcementQueue.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No announcements queued")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(manager.announcementQueue.enumerated()), id: \.element.id) { index, announcement in
                        HStack {
                            VStack(alignment: .leading) {
                                HStack {
                                    Image(systemName: announcement.type.icon)
                                        .foregroundColor(announcement.type.color)
                                    Text(announcement.type.displayName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(announcement.text)
                                    .font(.subheadline)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Button(action: { manager.removeFromQueue(at: index) }) {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Now playing
            if let current = manager.currentAnnouncement {
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.green)
                    Text("Now playing: \(current.text)")
                        .font(.caption)
                        .lineLimit(1)

                    Spacer()

                    Button("Stop") {
                        manager.stopSpeaking()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding()
                .background(Color.green.opacity(0.1))
            }
        }
    }

    private func sendCustomAnnouncement() {
        let announcement = Announcement(
            type: announcementType,
            text: customText,
            effect: selectedEffect,
            delivery: deliveryMethod
        )
        manager.queueAnnouncement(announcement)
        customText = ""
    }
}

// MARK: - Predefined Announcement Card
struct PredefinedAnnouncementCard: View {
    let announcement: PredefinedAnnouncement
    @ObservedObject var manager = TTSManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            manager.queuePredefined(announcement)
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: announcement.type.icon)
                        .foregroundColor(announcement.type.color)
                    Text(announcement.type.displayName)
                        .font(.caption)
                        .textCase(.uppercase)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                Text(announcement.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(announcement.text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            .padding()
            .background(isHovered ? Color(.selectedContentBackgroundColor) : Color(.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Compact TTS Button
struct TTSQuickButton: View {
    @ObservedObject var manager = TTSManager.shared
    @State private var showAnnouncements = false

    var body: some View {
        Button(action: { showAnnouncements = true }) {
            HStack(spacing: 4) {
                Image(systemName: "megaphone.fill")
                if !manager.announcementQueue.isEmpty {
                    Text("\(manager.announcementQueue.count)")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .foregroundColor(.white)
                }
            }
        }
        .help("Announcements")
        .popover(isPresented: $showAnnouncements) {
            TTSAnnouncementView()
                .frame(width: 500, height: 600)
        }
    }
}
