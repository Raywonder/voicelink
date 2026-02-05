import Foundation
import SwiftUI
import AVFoundation

/// Push-to-Talk Manager
/// Handles PTT mode where users hold a key to transmit audio
/// - Default key: Space bar
/// - Configurable keybind
/// - Visual and audio feedback
class PTTManager: ObservableObject {
    static let shared = PTTManager()

    // MARK: - State

    @Published var isTransmitting = false
    @Published var isPTTEnabled = false          // PTT mode vs voice activation
    @Published var isPTTRequired = false         // Room requires PTT
    @Published var transmitDuration: TimeInterval = 0

    // MARK: - Settings

    struct PTTSettings: Codable {
        var keyCode: UInt16 = 49            // Space bar default
        var keyName: String = "Space"
        var playStartSound: Bool = true
        var playStopSound: Bool = true
        var showVisualIndicator: Bool = true
        var transmitDelay: TimeInterval = 0.05  // 50ms delay to prevent pops
        var releaseDelay: TimeInterval = 0.1    // 100ms tail
        var maxTransmitTime: TimeInterval = 300 // 5 min max continuous transmit
    }

    @Published var settings = PTTSettings()

    // MARK: - Internal State

    var isKeyPressed = false
    private var transmitStartTime: Date?
    private var transmitTimer: Timer?
    private var maxTransmitTimer: Timer?
    private var keyMonitor: Any?

    // Callbacks
    var onTransmitStart: (() -> Void)?
    var onTransmitStop: (() -> Void)?
    var onTransmitTimeout: (() -> Void)?

    init() {
        loadSettings()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Enable/Disable PTT Mode

    func enablePTT() {
        isPTTEnabled = true
        startMonitoring()
        saveSettings()
        print("PTTManager: PTT mode enabled (key: \(settings.keyName))")
    }

    func disablePTT() {
        if isTransmitting {
            stopTransmit()
        }
        isPTTEnabled = false
        stopMonitoring()
        saveSettings()
        print("PTTManager: PTT mode disabled, using voice activation")
    }

    func togglePTT() {
        if isPTTEnabled {
            disablePTT()
        } else {
            enablePTT()
        }
    }

    // MARK: - Key Monitoring

    func startMonitoring() {
        guard keyMonitor == nil else { return }

        // Monitor key down
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self = self else { return event }
            guard self.isPTTEnabled || self.isPTTRequired else { return event }

            // Check if it's our PTT key
            guard event.keyCode == self.settings.keyCode else { return event }

            // Don't trigger if in text field
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }

            if event.type == .keyDown && !self.isKeyPressed {
                self.isKeyPressed = true
                self.startTransmit()
                return nil // Consume event
            } else if event.type == .keyUp && self.isKeyPressed {
                self.isKeyPressed = false
                self.stopTransmit()
                return nil // Consume event
            }

            return event
        }

        // Also monitor for window losing focus
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowLostFocus),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        print("PTTManager: Started key monitoring")
    }

    func stopMonitoring() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }

        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        print("PTTManager: Stopped key monitoring")
    }

    @objc private func windowLostFocus() {
        // Stop transmitting if window loses focus
        if isTransmitting {
            isKeyPressed = false
            stopTransmit()
        }
    }

    // MARK: - Transmit Control

    func startTransmit() {
        guard !isTransmitting else { return }

        // Small delay to prevent audio pops
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.transmitDelay) { [weak self] in
            guard let self = self, self.isKeyPressed else { return }

            self.isTransmitting = true
            self.transmitStartTime = Date()

            // Play start sound
            if self.settings.playStartSound {
                AppSoundManager.shared.playPTTStartSound()
            }

            // Start duration timer
            self.transmitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let startTime = self.transmitStartTime else { return }
                self.transmitDuration = Date().timeIntervalSince(startTime)
            }

            // Start max transmit timer
            self.maxTransmitTimer = Timer.scheduledTimer(withTimeInterval: self.settings.maxTransmitTime, repeats: false) { [weak self] _ in
                self?.handleTransmitTimeout()
            }

            // Notify server to start transmitting
            self.notifyServerTransmitState(transmitting: true)

            // Callback
            self.onTransmitStart?()

            print("PTTManager: Started transmitting")
        }
    }

    func stopTransmit() {
        guard isTransmitting else { return }

        // Small delay for release tail
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.releaseDelay) { [weak self] in
            guard let self = self else { return }

            self.isTransmitting = false

            // Play stop sound
            if self.settings.playStopSound {
                AppSoundManager.shared.playPTTStopSound()
            }

            // Stop timers
            self.transmitTimer?.invalidate()
            self.transmitTimer = nil
            self.maxTransmitTimer?.invalidate()
            self.maxTransmitTimer = nil

            let duration = self.transmitDuration
            self.transmitDuration = 0
            self.transmitStartTime = nil

            // Notify server to stop transmitting
            self.notifyServerTransmitState(transmitting: false)

            // Callback
            self.onTransmitStop?()

            print("PTTManager: Stopped transmitting (duration: \(String(format: "%.1f", duration))s)")
        }
    }

    private func handleTransmitTimeout() {
        print("PTTManager: Max transmit time reached")

        // Force stop transmitting
        isKeyPressed = false
        stopTransmit()

        // Notify user
        onTransmitTimeout?()

        // Post notification for UI
        NotificationCenter.default.post(name: .pttTransmitTimeout, object: nil)
    }

    // MARK: - Server Communication

    private func notifyServerTransmitState(transmitting: Bool) {
        // Send audio state to server
        ServerManager.shared.sendAudioState(
            isMuted: !transmitting && isPTTEnabled, // Muted when not transmitting in PTT mode
            isDeafened: false
        )

        // Post notification for audio engine
        NotificationCenter.default.post(
            name: .pttTransmitStateChanged,
            object: nil,
            userInfo: ["transmitting": transmitting]
        )
    }

    // MARK: - Key Configuration

    func setKeyBind(keyCode: UInt16, keyName: String) {
        settings.keyCode = keyCode
        settings.keyName = keyName
        saveSettings()
        print("PTTManager: Key bind set to \(keyName) (code: \(keyCode))")
    }

    /// Start listening for next key press to set as PTT key
    func startKeyBindCapture(completion: @escaping (UInt16, String) -> Void) {
        let captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyName = self.keyCodeToString(event.keyCode)
            completion(event.keyCode, keyName)
            return nil // Consume event
        }

        // Auto-remove after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if let monitor = captureMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String {
        let keyNames: [UInt16: String] = [
            49: "Space",
            36: "Return",
            48: "Tab",
            51: "Delete",
            53: "Escape",
            123: "Left Arrow",
            124: "Right Arrow",
            125: "Down Arrow",
            126: "Up Arrow",
            96: "F5",
            97: "F6",
            98: "F7",
            99: "F3",
            100: "F8",
            101: "F9",
            109: "F10",
            103: "F11",
            111: "F12",
            // Add more as needed
        ]
        return keyNames[keyCode] ?? "Key \(keyCode)"
    }

    // MARK: - Persistence

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "pttSettings"),
           let decoded = try? JSONDecoder().decode(PTTSettings.self, from: data) {
            settings = decoded
        }
        isPTTEnabled = UserDefaults.standard.bool(forKey: "pttEnabled")

        if isPTTEnabled {
            startMonitoring()
        }
    }

    private func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: "pttSettings")
        }
        UserDefaults.standard.set(isPTTEnabled, forKey: "pttEnabled")
    }

    // MARK: - Status

    func getStatus() -> [String: Any] {
        return [
            "isEnabled": isPTTEnabled,
            "isTransmitting": isTransmitting,
            "keyName": settings.keyName,
            "duration": transmitDuration,
            "isPTTRequired": isPTTRequired
        ]
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let pttTransmitStateChanged = Notification.Name("pttTransmitStateChanged")
    static let pttTransmitTimeout = Notification.Name("pttTransmitTimeout")
}

// MARK: - SwiftUI Views

/// PTT Indicator - Shows when transmitting
struct PTTIndicator: View {
    @ObservedObject var pttManager = PTTManager.shared

    var body: some View {
        if pttManager.isPTTEnabled || pttManager.isPTTRequired {
            HStack(spacing: 8) {
                // Transmit indicator
                Circle()
                    .fill(pttManager.isTransmitting ? Color.red : Color.gray)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )

                if pttManager.isTransmitting {
                    // Transmitting state
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .foregroundColor(.red)

                        Text("TX")
                            .font(.caption.bold())
                            .foregroundColor(.red)

                        Text(formatDuration(pttManager.transmitDuration))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white.opacity(0.8))
                    }
                } else {
                    // Ready state
                    HStack(spacing: 4) {
                        Image(systemName: "mic.slash")
                            .foregroundColor(.gray)

                        Text("PTT")
                            .font(.caption)
                            .foregroundColor(.gray)

                        Text("[\(pttManager.settings.keyName)]")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(pttManager.isTransmitting ? Color.red.opacity(0.2) : Color.black.opacity(0.3))
            .cornerRadius(20)
            .animation(.easeInOut(duration: 0.15), value: pttManager.isTransmitting)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "0:%02d", seconds)
        }
    }
}

/// Large PTT button for touch/click activation
struct PTTButton: View {
    @ObservedObject var pttManager = PTTManager.shared
    @State private var isPressed = false

    var body: some View {
        Button(action: {}) {
            VStack(spacing: 8) {
                Image(systemName: pttManager.isTransmitting ? "mic.fill" : "mic")
                    .font(.system(size: 32))

                Text(pttManager.isTransmitting ? "Transmitting..." : "Hold to Talk")
                    .font(.caption)

                if pttManager.isTransmitting {
                    Text(formatDuration(pttManager.transmitDuration))
                        .font(.caption.monospacedDigit())
                }
            }
            .frame(width: 100, height: 100)
            .background(pttManager.isTransmitting ? Color.red : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(50)
            .scaleEffect(isPressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        pttManager.isKeyPressed = true
                        pttManager.startTransmit()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    pttManager.isKeyPressed = false
                    pttManager.stopTransmit()
                }
        )
        .accessibilityLabel("Push to talk button")
        .accessibilityHint("Press and hold to transmit audio")
        .accessibilityAddTraits(pttManager.isTransmitting ? .isSelected : [])
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return "\(seconds)s"
    }
}

/// PTT Settings View
struct PTTSettingsView: View {
    @ObservedObject var pttManager = PTTManager.shared
    @State private var isCapturingKey = false

    var body: some View {
        Form {
            Section("Push-to-Talk Mode") {
                Toggle("Enable PTT Mode", isOn: Binding(
                    get: { pttManager.isPTTEnabled },
                    set: { newValue in
                        if newValue {
                            pttManager.enablePTT()
                        } else {
                            pttManager.disablePTT()
                        }
                    }
                ))
                .help("When enabled, hold a key to transmit. When disabled, uses voice activation.")

                if pttManager.isPTTRequired {
                    Text("This room requires Push-to-Talk")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Section("Key Binding") {
                HStack {
                    Text("PTT Key:")
                    Spacer()

                    if isCapturingKey {
                        Text("Press any key...")
                            .foregroundColor(.blue)
                    } else {
                        Text(pttManager.settings.keyName)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(6)
                    }

                    Button(isCapturingKey ? "Cancel" : "Change") {
                        if isCapturingKey {
                            isCapturingKey = false
                        } else {
                            isCapturingKey = true
                            pttManager.startKeyBindCapture { keyCode, keyName in
                                pttManager.setKeyBind(keyCode: keyCode, keyName: keyName)
                                isCapturingKey = false
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("Sound Feedback") {
                Toggle("Play start sound", isOn: $pttManager.settings.playStartSound)
                Toggle("Play stop sound", isOn: $pttManager.settings.playStopSound)
            }

            Section("Timing") {
                HStack {
                    Text("Transmit delay:")
                    Slider(value: Binding(
                        get: { pttManager.settings.transmitDelay * 1000 },
                        set: { pttManager.settings.transmitDelay = $0 / 1000 }
                    ), in: 0...200, step: 10)
                    Text("\(Int(pttManager.settings.transmitDelay * 1000))ms")
                        .frame(width: 50)
                }

                HStack {
                    Text("Release delay:")
                    Slider(value: Binding(
                        get: { pttManager.settings.releaseDelay * 1000 },
                        set: { pttManager.settings.releaseDelay = $0 / 1000 }
                    ), in: 0...500, step: 25)
                    Text("\(Int(pttManager.settings.releaseDelay * 1000))ms")
                        .frame(width: 50)
                }

                HStack {
                    Text("Max transmit time:")
                    Picker("", selection: Binding(
                        get: { Int(pttManager.settings.maxTransmitTime) },
                        set: { pttManager.settings.maxTransmitTime = TimeInterval($0) }
                    )) {
                        Text("1 min").tag(60)
                        Text("2 min").tag(120)
                        Text("5 min").tag(300)
                        Text("10 min").tag(600)
                        Text("No limit").tag(3600)
                    }
                    .frame(width: 120)
                }
            }

            Section("Test") {
                HStack {
                    PTTButton()
                        .scaleEffect(0.8)

                    VStack(alignment: .leading) {
                        Text("Test PTT")
                            .font(.headline)
                        Text("Click and hold the button or press \(pttManager.settings.keyName)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
