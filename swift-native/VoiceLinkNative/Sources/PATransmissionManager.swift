import Foundation
import SwiftUI
import AVFoundation

/// PA (Public Address) Transmission Manager
/// Enables intercom-style broadcast announcements to all users or specific rooms
/// - Uses intercom sound effects from sounds folder
/// - Applies audio processing for PA-style sound
/// - Supports multiple chime styles (1-16)
class PATransmissionManager: ObservableObject {
    static let shared = PATransmissionManager()

    // MARK: - State

    @Published var isTransmitting = false
    @Published var isPAEnabled = false             // User has PA permission
    @Published var currentTarget: PATarget = .allRooms
    @Published var transmitDuration: TimeInterval = 0
    @Published var selectedChimeStyle: Int = 1     // 1-16 chime styles

    // MARK: - Types

    enum PATarget: Equatable {
        case allRooms                    // Broadcast to all active channels
        case currentRoom                 // Broadcast to current room only
        case specificRoom(String)        // Broadcast to selected room(s)
        case specificUser(String, String) // userId, username - Direct PA to one person
        case selectedChannels([String])  // Broadcast to multiple selected channels
        case emergency                   // Emergency broadcast to all

        var displayName: String {
            switch self {
            case .allRooms: return "All Channels"
            case .currentRoom: return "Current Channel"
            case .specificRoom(let name): return name
            case .specificUser(_, let username): return "Direct to \(username)"
            case .selectedChannels(let rooms): return "\(rooms.count) Channels"
            case .emergency: return "Emergency (All)"
            }
        }

        var icon: String {
            switch self {
            case .allRooms: return "megaphone.fill"
            case .currentRoom: return "speaker.wave.3.fill"
            case .specificRoom: return "rectangle.fill"
            case .specificUser: return "person.wave.2.fill"
            case .selectedChannels: return "checklist"
            case .emergency: return "exclamationmark.triangle.fill"
            }
        }

        var description: String {
            switch self {
            case .allRooms: return "Broadcast to all active channels"
            case .currentRoom: return "Broadcast to this channel only"
            case .specificRoom: return "Broadcast to a specific channel"
            case .specificUser: return "Private PA to one person"
            case .selectedChannels: return "Broadcast to selected channels"
            case .emergency: return "Emergency broadcast with alert"
            }
        }
    }

    // MARK: - Settings

    struct PASettings: Codable, Equatable {
        var playStartChime: Bool = true
        var playEndChime: Bool = true
        var chimeVolume: Float = 0.4               // 40% volume for chimes
        var applyIntercomEffect: Bool = true       // Apply intercom audio processing
        var ducksOtherAudio: Bool = true           // Reduce other audio during PA
        var duckingLevel: Float = -15              // dB
        var maxDuration: TimeInterval = 60         // Max PA duration (1 min)
        var requireHold: Bool = true               // Hold to transmit (PA standard behavior)
    }

    @Published var settings = PASettings()
    @Published var isChimePlaying = false          // True while chime is playing

    // Track last used chimes to avoid immediate repeats
    private var lastStartChime: Int = 0
    private var lastStopChime: Int = 0

    // MARK: - Private

    private var audioPlayer: AVAudioPlayer?
    private var transmitStartTime: Date?
    private var durationTimer: Timer?
    private var maxDurationTimer: Timer?
    private var keyMonitor: Any?

    // Callbacks
    var onTransmitStart: ((PATarget) -> Void)?
    var onTransmitStop: (() -> Void)?
    var onPAReceived: ((String, PATarget) -> Void)? // username, target

    private var candidateBundles: [Bundle] {
        var bundles: [Bundle] = []
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        bundles.append(Bundle.main)
        bundles.append(Bundle(for: PATransmissionManager.self))
        return bundles
    }

    init() {
        loadSettings()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - PA Control

    /// Start PA transmission (button pressed down)
    /// Flow: Button down → Start chime plays → Chime finishes → Mic activates
    func startTransmission(target: PATarget = .allRooms) {
        guard !isTransmitting && !isChimePlaying else { return }
        guard isPAEnabled else {
            print("PATransmissionManager: PA not enabled for this user")
            return
        }

        currentTarget = target

        // Notify server that PA is starting (for UI indicators on other clients)
        notifyServer(transmitting: true, target: target)

        // Callback
        onTransmitStart?(target)

        // Play start chime FIRST - mic only activates after chime finishes
        if settings.playStartChime {
            isChimePlaying = true
            playStartChime { [weak self] in
                guard let self = self else { return }
                self.isChimePlaying = false

                // Only activate mic if button is still held (check isTransmitting flag)
                // We set isTransmitting = true here, after chime completes
                self.isTransmitting = true
                self.transmitStartTime = Date()
                self.activateMicrophone()

                // Start duration timer
                self.durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self = self, let startTime = self.transmitStartTime else { return }
                    self.transmitDuration = Date().timeIntervalSince(startTime)
                }

                // Start max duration timer
                self.maxDurationTimer = Timer.scheduledTimer(withTimeInterval: self.settings.maxDuration, repeats: false) { [weak self] _ in
                    self?.stopTransmission(timedOut: true)
                }

                print("PATransmissionManager: Mic activated - user can now speak")
            }
        } else {
            // No chime - activate immediately
            isTransmitting = true
            transmitStartTime = Date()
            activateMicrophone()

            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let startTime = self.transmitStartTime else { return }
                self.transmitDuration = Date().timeIntervalSince(startTime)
            }

            maxDurationTimer = Timer.scheduledTimer(withTimeInterval: settings.maxDuration, repeats: false) { [weak self] _ in
                self?.stopTransmission(timedOut: true)
            }
        }

        print("PATransmissionManager: Started PA to \(target.displayName)")
    }

    /// Stop PA transmission (button released)
    /// Flow: Button up → Mic deactivates immediately → Stop chime plays
    func stopTransmission(timedOut: Bool = false) {
        // If chime is still playing (user released too early), cancel
        if isChimePlaying {
            audioPlayer?.stop()
            isChimePlaying = false
            print("PATransmissionManager: PA cancelled - button released during start chime")
            notifyServer(transmitting: false, target: currentTarget)
            onTransmitStop?()
            return
        }

        guard isTransmitting else { return }

        // IMMEDIATELY deactivate microphone - user stops talking
        deactivateMicrophone()
        isTransmitting = false

        // Stop timers
        durationTimer?.invalidate()
        durationTimer = nil
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil

        let duration = transmitDuration
        transmitDuration = 0
        transmitStartTime = nil

        // Notify server
        notifyServer(transmitting: false, target: currentTarget)

        // Callback
        onTransmitStop?()

        print("PATransmissionManager: Mic deactivated (duration: \(String(format: "%.1f", duration))s\(timedOut ? " - timed out" : ""))")

        // THEN play end chime (after mic is off)
        if settings.playEndChime {
            isChimePlaying = true
            playStopChime { [weak self] in
                self?.isChimePlaying = false
                print("PATransmissionManager: Stop chime finished")
            }
        }
    }

    /// Toggle PA transmission (for non-hold mode)
    func toggleTransmission(target: PATarget = .allRooms) {
        if isTransmitting || isChimePlaying {
            stopTransmission()
        } else {
            startTransmission(target: target)
        }
    }

    // MARK: - Chime Playback

    /// Get a random chime number (1-16), avoiding the last used one
    private func getRandomChime(avoiding lastUsed: Int) -> Int {
        var newChime: Int
        repeat {
            newChime = Int.random(in: 1...16)
        } while newChime == lastUsed && lastUsed != 0
        return newChime
    }

    /// Play random PA chime for start
    private func playStartChime(completion: @escaping () -> Void) {
        let chime = getRandomChime(avoiding: lastStartChime)
        lastStartChime = chime
        playPAChime(style: chime, completion: completion)
    }

    /// Play random PA chime for stop
    private func playStopChime(completion: @escaping () -> Void) {
        let chime = getRandomChime(avoiding: lastStopChime)
        lastStopChime = chime
        playPAChime(style: chime, completion: completion)
    }

    /// Play PA chime with specified style (1-16) at configured volume
    private func playPAChime(style: Int, completion: @escaping () -> Void) {
        let chimeNumber = String(format: "%03d", style)
        let filename = "pa-transmit-start-or-stop_\(chimeNumber)"

        // Try to load from multiple bundle locations
        let url = candidateBundles.lazy.compactMap { bundle in
            bundle.url(forResource: filename, withExtension: "wav", subdirectory: "sounds")
            ?? bundle.url(forResource: filename, withExtension: "wav", subdirectory: "Resources/sounds")
            ?? bundle.url(forResource: filename, withExtension: "wav")
        }.first

        guard let url else {
            print("PATransmissionManager: Chime file not found: \(filename)")
            completion()
            return
        }

        do {
            audioPlayer?.stop()
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.volume = settings.chimeVolume  // 40% volume
            audioPlayer?.play()

            // Wait for playback to finish
            let duration = audioPlayer?.duration ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                completion()
            }
        } catch {
            print("PATransmissionManager: Failed to play chime: \(error)")
            completion()
        }
    }

    // MARK: - Microphone Control

    private func activateMicrophone() {
        // Apply intercom effect if enabled
        if settings.applyIntercomEffect {
            applyIntercomEffect()
        }

        // Duck other audio if enabled
        if settings.ducksOtherAudio {
            duckOtherAudio()
        }

        // Notify audio engine to enable PA mode
        NotificationCenter.default.post(
            name: .paTransmitStateChanged,
            object: nil,
            userInfo: [
                "transmitting": true,
                "target": currentTarget.displayName,
                "intercomEffect": settings.applyIntercomEffect
            ]
        )
    }

    private func deactivateMicrophone() {
        // Remove intercom effect
        removeIntercomEffect()

        // Restore other audio
        restoreOtherAudio()

        // Notify audio engine
        NotificationCenter.default.post(
            name: .paTransmitStateChanged,
            object: nil,
            userInfo: ["transmitting": false]
        )
    }

    // MARK: - Audio Effects

    private func applyIntercomEffect() {
        // In production, this would apply:
        // - Bandpass filter (300Hz - 3400Hz) for classic PA sound
        // - Light compression
        // - Slight distortion for "speaker" character

        NotificationCenter.default.post(
            name: .applyPAEffect,
            object: nil,
            userInfo: [
                "bandpassLow": 300,
                "bandpassHigh": 3400,
                "compression": true,
                "saturation": 0.15
            ]
        )
    }

    private func removeIntercomEffect() {
        NotificationCenter.default.post(name: .removePAEffect, object: nil)
    }

    private func duckOtherAudio() {
        let linearLevel = pow(10, settings.duckingLevel / 20)
        NotificationCenter.default.post(
            name: .paDuckAudio,
            object: nil,
            userInfo: ["level": linearLevel]
        )
    }

    private func restoreOtherAudio() {
        NotificationCenter.default.post(name: .paRestoreAudio, object: nil)
    }

    // MARK: - Server Communication

    private func notifyServer(transmitting: Bool, target: PATarget) {
        var targetInfo: [String: Any] = ["type": "pa"]

        switch target {
        case .allRooms:
            targetInfo["scope"] = "all"
        case .currentRoom:
            targetInfo["scope"] = "current"
        case .specificRoom(let roomId):
            targetInfo["scope"] = "room"
            targetInfo["roomId"] = roomId
        case .specificUser(let userId, let username):
            targetInfo["scope"] = "user"
            targetInfo["userId"] = userId
            targetInfo["username"] = username
        case .selectedChannels(let roomIds):
            targetInfo["scope"] = "selected"
            targetInfo["roomIds"] = roomIds
        case .emergency:
            targetInfo["scope"] = "emergency"
        }

        NotificationCenter.default.post(
            name: .sendPAToServer,
            object: nil,
            userInfo: [
                "transmitting": transmitting,
                "target": targetInfo,
                "chimeStyle": selectedChimeStyle
            ]
        )
    }

    /// Start direct PA to a specific user
    func startDirectPA(to userId: String, username: String) {
        startTransmission(target: .specificUser(userId, username))
    }

    /// Start PA to selected channels
    func startSelectedChannelsPA(roomIds: [String]) {
        startTransmission(target: .selectedChannels(roomIds))
    }

    // MARK: - Receiving PA

    /// Handle incoming PA broadcast from another user
    func handleIncomingPA(_ data: [String: Any]) {
        guard let username = data["username"] as? String,
              let transmitting = data["transmitting"] as? Bool else { return }

        if transmitting {
            // Play incoming PA start chime
            if let chimeStyle = data["chimeStyle"] as? Int {
                selectedChimeStyle = chimeStyle
            }
            playPAChime(style: selectedChimeStyle) {}

            // Notify UI
            let scope = data["scope"] as? String ?? "all"
            let target: PATarget = scope == "emergency" ? .emergency : .allRooms
            onPAReceived?(username, target)
        } else {
            // Play end chime
            playPAChime(style: selectedChimeStyle) {}
        }
    }

    // MARK: - Keyboard Shortcut (Cmd+Shift+P for PA)

    func startMonitoring() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self = self else { return event }
            guard self.isPAEnabled else { return event }

            // Cmd+Shift+P (keyCode 35 is P)
            let hasCmd = event.modifierFlags.contains(.command)
            let hasShift = event.modifierFlags.contains(.shift)

            guard event.keyCode == 35 && hasCmd && hasShift else { return event }

            // Don't trigger if in text field
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }

            if self.settings.requireHold {
                // Hold to transmit
                if event.type == .keyDown && !self.isTransmitting {
                    self.startTransmission()
                    return nil
                } else if event.type == .keyUp && self.isTransmitting {
                    self.stopTransmission()
                    return nil
                }
            } else {
                // Toggle mode
                if event.type == .keyDown {
                    self.toggleTransmission()
                    return nil
                }
            }

            return event
        }
    }

    func stopMonitoring() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Persistence

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "paSettings"),
           let decoded = try? JSONDecoder().decode(PASettings.self, from: data) {
            settings = decoded
        }
        isPAEnabled = UserDefaults.standard.bool(forKey: "paEnabled")
    }

    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: "paSettings")
        }
    }

    // MARK: - Status

    func getStatus() -> [String: Any] {
        return [
            "isEnabled": isPAEnabled,
            "isTransmitting": isTransmitting,
            "target": currentTarget.displayName,
            "duration": transmitDuration,
            "chimeStyle": selectedChimeStyle
        ]
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let paTransmitStateChanged = Notification.Name("paTransmitStateChanged")
    static let applyPAEffect = Notification.Name("applyPAEffect")
    static let removePAEffect = Notification.Name("removePAEffect")
    static let paDuckAudio = Notification.Name("paDuckAudio")
    static let paRestoreAudio = Notification.Name("paRestoreAudio")
    static let sendPAToServer = Notification.Name("sendPAToServer")
    static let incomingPA = Notification.Name("incomingPA")
}

// MARK: - SwiftUI Views

/// PA Transmission Indicator
struct PAIndicator: View {
    @ObservedObject var paManager = PATransmissionManager.shared

    var body: some View {
        if paManager.isTransmitting || paManager.isChimePlaying {
            HStack(spacing: 8) {
                // Status icon
                if paManager.isChimePlaying {
                    // Chime is playing - user cannot speak yet
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.orange)
                } else {
                    // Mic is active - user can speak
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundColor(.red)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if paManager.isChimePlaying && !paManager.isTransmitting {
                        // Start chime playing
                        Text("PA STARTING...")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                        Text("Wait for chime")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    } else if paManager.isTransmitting {
                        // Mic is active
                        Text("PA LIVE - SPEAK NOW")
                            .font(.caption.bold())
                            .foregroundColor(.red)
                        Text(paManager.currentTarget.displayName)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    } else {
                        // Stop chime playing
                        Text("PA ENDING...")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                    }
                }

                if paManager.isTransmitting {
                    Text(formatDuration(paManager.transmitDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))

                    Button(action: { paManager.stopTransmission() }) {
                        Image(systemName: "stop.fill")
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(paManager.isTransmitting ? Color.red.opacity(0.9) : Color.orange.opacity(0.9))
            .cornerRadius(8)
            .animation(.easeInOut, value: paManager.isTransmitting)
            .animation(.easeInOut, value: paManager.isChimePlaying)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return String(format: "0:%02d", seconds)
    }
}

/// PA Button for toolbar
struct PAButton: View {
    @ObservedObject var paManager = PATransmissionManager.shared
    @State private var showTargetPicker = false

    var body: some View {
        if paManager.isPAEnabled {
            Button(action: {
                if paManager.isTransmitting {
                    paManager.stopTransmission()
                } else {
                    showTargetPicker = true
                }
            }) {
                Image(systemName: paManager.isTransmitting ? "megaphone.fill" : "megaphone")
                    .foregroundColor(paManager.isTransmitting ? .red : .white)
            }
            .buttonStyle(.plain)
            .help("PA Broadcast (Cmd+Shift+P)")
            .popover(isPresented: $showTargetPicker) {
                PATargetPicker(onSelect: { target in
                    paManager.startTransmission(target: target)
                    showTargetPicker = false
                })
            }
        }
    }
}

/// PA Target Picker
struct PATargetPicker: View {
    let onSelect: (PATransmissionManager.PATarget) -> Void
    @ObservedObject var serverManager = ServerManager.shared
    @State private var showUserPicker = false
    @State private var showChannelPicker = false
    @State private var selectedChannelIds: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Broadcast To")
                .font(.headline)
                .padding(.bottom, 4)

            // Quick options
            Group {
                PATargetButton(target: .currentRoom, onSelect: onSelect)
                PATargetButton(target: .allRooms, onSelect: onSelect)

                // Direct to user
                Button(action: { showUserPicker = true }) {
                    HStack {
                        Image(systemName: "person.wave.2.fill")
                            .foregroundColor(.purple)
                            .frame(width: 20)
                        Text("Direct to User...")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)

                // Selected channels
                Button(action: { showChannelPicker = true }) {
                    HStack {
                        Image(systemName: "checklist")
                            .foregroundColor(.blue)
                            .frame(width: 20)
                        Text("Select Channels...")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)

                Divider()

                PATargetButton(target: .emergency, onSelect: onSelect)
            }
        }
        .padding()
        .frame(width: 220)
        .sheet(isPresented: $showUserPicker) {
            PAUserPicker(onSelect: { userId, username in
                onSelect(.specificUser(userId, username))
                showUserPicker = false
            })
        }
        .sheet(isPresented: $showChannelPicker) {
            PAChannelPicker(selectedIds: $selectedChannelIds) {
                if !selectedChannelIds.isEmpty {
                    onSelect(.selectedChannels(Array(selectedChannelIds)))
                }
                showChannelPicker = false
            }
        }
    }
}

struct PATargetButton: View {
    let target: PATransmissionManager.PATarget
    let onSelect: (PATransmissionManager.PATarget) -> Void

    var body: some View {
        Button(action: { onSelect(target) }) {
            HStack {
                Image(systemName: target.icon)
                    .foregroundColor(target == .emergency ? .red : .blue)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(target.displayName)
                    Text(target.description)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

/// Pick a user for direct PA
struct PAUserPicker: View {
    let onSelect: (String, String) -> Void
    @ObservedObject var serverManager = ServerManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Direct PA to User")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }

            Divider()

            if serverManager.currentRoomUsers.isEmpty {
                Text("No users in room")
                    .foregroundColor(.gray)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(serverManager.currentRoomUsers) { user in
                            Button(action: { onSelect(user.odId, user.username) }) {
                                HStack {
                                    Image(systemName: "person.fill")
                                        .foregroundColor(.blue)
                                    Text(user.username)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 280, height: 300)
    }
}

/// Pick multiple channels for PA broadcast
struct PAChannelPicker: View {
    @Binding var selectedIds: Set<String>
    let onConfirm: () -> Void
    @ObservedObject var serverManager = ServerManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Select Channels")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }

            Text("Select channels to broadcast to:")
                .font(.caption)
                .foregroundColor(.gray)

            Divider()

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(serverManager.rooms) { room in
                        Button(action: { toggleRoom(room.id) }) {
                            HStack {
                                Image(systemName: selectedIds.contains(room.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedIds.contains(room.id) ? .blue : .gray)

                                Image(systemName: room.isPrivate ? "lock.fill" : "globe")
                                    .foregroundColor(room.isPrivate ? .yellow : .green)
                                    .font(.caption)

                                Text(room.name)
                                Spacer()

                                Text("\(room.userCount)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(selectedIds.contains(room.id) ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            HStack {
                Text("\(selectedIds.count) channel(s) selected")
                    .font(.caption)
                    .foregroundColor(.gray)

                Spacer()

                Button("Select All") {
                    selectedIds = Set(serverManager.rooms.map { $0.id })
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Broadcast") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIds.isEmpty)
            }
        }
        .padding()
        .frame(width: 320, height: 400)
    }

    private func toggleRoom(_ roomId: String) {
        if selectedIds.contains(roomId) {
            selectedIds.remove(roomId)
        } else {
            selectedIds.insert(roomId)
        }
    }
}

/// PA Settings View
struct PASettingsView: View {
    @ObservedObject var paManager = PATransmissionManager.shared

    var body: some View {
        Form {
            Section("PA Chime Sounds") {
                Toggle("Play start chime", isOn: $paManager.settings.playStartChime)
                Toggle("Play stop chime", isOn: $paManager.settings.playEndChime)

                HStack {
                    Text("Chime volume:")
                    Slider(value: $paManager.settings.chimeVolume, in: 0.2...1.0, step: 0.1)
                    Text("\(Int(paManager.settings.chimeVolume * 100))%")
                        .frame(width: 45)
                }

                Text("Chimes are randomly selected from 16 sounds")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Section("How PA Works") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "1.circle.fill")
                            .foregroundColor(.blue)
                        Text("Press button → Random start chime plays")
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "2.circle.fill")
                            .foregroundColor(.blue)
                        Text("Chime finishes → Mic activates (speak now)")
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "3.circle.fill")
                            .foregroundColor(.blue)
                        Text("Release button → Mic off immediately")
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "4.circle.fill")
                            .foregroundColor(.blue)
                        Text("Random stop chime plays → Done")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section("Audio Effects") {
                Toggle("Apply intercom effect", isOn: $paManager.settings.applyIntercomEffect)
                    .help("Adds classic PA speaker sound")

                Toggle("Duck other audio", isOn: $paManager.settings.ducksOtherAudio)
                    .help("Reduce other audio during PA")

                if paManager.settings.ducksOtherAudio {
                    HStack {
                        Text("Ducking level:")
                        Slider(value: $paManager.settings.duckingLevel, in: -30...0, step: 1)
                        Text("\(Int(paManager.settings.duckingLevel)) dB")
                            .frame(width: 50)
                    }
                }
            }

            Section("Limits") {
                HStack {
                    Text("Max duration:")
                    Picker("", selection: Binding(
                        get: { Int(paManager.settings.maxDuration) },
                        set: { paManager.settings.maxDuration = TimeInterval($0) }
                    )) {
                        Text("30 sec").tag(30)
                        Text("1 min").tag(60)
                        Text("2 min").tag(120)
                        Text("5 min").tag(300)
                    }
                    .frame(width: 100)
                }
            }

            Section("Activation") {
                Text("Keyboard shortcut: Cmd+Shift+P")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("Hold to transmit, release to stop")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .formStyle(.grouped)
        .onChange(of: paManager.settings) { _ in
            paManager.saveSettings()
        }
    }
}

/// Incoming PA Alert
struct IncomingPAAlert: View {
    let username: String
    let target: PATransmissionManager.PATarget
    @Binding var isShowing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: target.icon)
                .font(.title2)
                .foregroundColor(target == .emergency ? .red : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(target == .emergency ? "EMERGENCY BROADCAST" : "PA Announcement")
                    .font(.caption.bold())
                    .foregroundColor(target == .emergency ? .red : .orange)

                Text("From \(username)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }

            Spacer()

            // Audio wave animation
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(target == .emergency ? Color.red : Color.orange)
                        .frame(width: 3, height: CGFloat.random(in: 8...20))
                }
            }
        }
        .padding()
        .background(
            (target == .emergency ? Color.red : Color.orange).opacity(0.2)
        )
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(target == .emergency ? Color.red : Color.orange, lineWidth: 1)
        )
    }
}
