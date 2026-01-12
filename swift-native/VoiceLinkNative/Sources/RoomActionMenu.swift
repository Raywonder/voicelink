import SwiftUI
import Foundation

/// Room Action Menu - Shows available actions for a room
/// Displayed when joining a room or clicking room name
struct RoomActionMenu: View {
    let room: Room
    let isInRoom: Bool
    @Binding var isPresented: Bool

    @ObservedObject var serverManager = ServerManager.shared
    @ObservedObject var whisperManager = WhisperModeManager.shared
    @ObservedObject var audioControl = UserAudioControlManager.shared
    @ObservedObject var roomLockManager = RoomLockManager.shared
    @State private var isPeeking = false
    @State private var selectedUser: RoomUser?

    // Room features (from server settings)
    var roomFeatures: RoomFeatures {
        // In production, these would come from room settings
        RoomFeatures(
            whisperEnabled: true,
            peekEnabled: room.userCount > 0,
            spatialAudioEnabled: true,
            recordingAllowed: false,
            voiceEffectsEnabled: true,
            pttRequired: false,
            canLockRoom: roomLockManager.canCurrentUserLock,
            isRoomLocked: roomLockManager.isRoomLocked
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(room.name)
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.blue.opacity(0.3))

            // Room info
            HStack {
                Image(systemName: room.isPrivate ? "lock.fill" : "globe")
                    .foregroundColor(room.isPrivate ? .yellow : .green)

                Text("\(room.userCount)/\(room.maxUsers) users")
                    .font(.caption)
                    .foregroundColor(.gray)

                if !room.description.isEmpty {
                    Text("- \(room.description)")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Actions
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // Peek into room (if not already in room)
                    if !isInRoom && roomFeatures.peekEnabled {
                        ActionMenuItem(
                            icon: "eye.fill",
                            label: isPeeking ? "Stop Peeking" : "Peek Into Room",
                            shortcut: "Cmd+P",
                            description: "Preview room audio (5-20 sec)",
                            isActive: isPeeking
                        ) {
                            togglePeek()
                        }
                    }

                    // Whisper mode (if in room)
                    if isInRoom && roomFeatures.whisperEnabled {
                        ActionMenuSection(title: "Whisper To") {
                            ForEach(serverManager.currentRoomUsers) { user in
                                ActionMenuItem(
                                    icon: whisperManager.whisperTargetUserId == user.odId ? "ear.fill" : "ear",
                                    label: user.username,
                                    shortcut: nil,
                                    description: "Hold Enter to whisper",
                                    isActive: whisperManager.whisperTargetUserId == user.odId
                                ) {
                                    if whisperManager.whisperTargetUserId == user.odId {
                                        whisperManager.clearWhisperTarget()
                                    } else {
                                        whisperManager.setWhisperTarget(userId: user.odId, username: user.username)
                                    }
                                }
                            }
                        }
                    }

                    // User volume controls (if in room)
                    if isInRoom {
                        ActionMenuSection(title: "User Volumes") {
                            ForEach(serverManager.currentRoomUsers) { user in
                                UserVolumeMenuItem(user: user)
                            }
                        }
                    }

                    Divider().padding(.vertical, 8)

                    // Spatial audio toggle
                    if roomFeatures.spatialAudioEnabled {
                        ActionMenuItem(
                            icon: "cube.transparent",
                            label: "3D Spatial Audio",
                            shortcut: "Cmd+3",
                            description: "Position users in 3D space",
                            isToggle: true,
                            isToggled: true
                        ) {
                            // Toggle spatial audio
                        }
                    }

                    // Voice effects
                    if roomFeatures.voiceEffectsEnabled {
                        ActionMenuItem(
                            icon: "waveform.circle",
                            label: "Voice Effects",
                            shortcut: nil,
                            description: "Apply audio effects"
                        ) {
                            // Show voice effects panel
                        }
                    }

                    // PTT mode
                    if roomFeatures.pttRequired {
                        ActionMenuItem(
                            icon: "hand.raised.fill",
                            label: "Push-to-Talk Mode",
                            shortcut: "Space",
                            description: "Hold Space to transmit",
                            isActive: true
                        ) {
                            // PTT is required, can't toggle
                        }
                        .disabled(true)
                    }

                    Divider().padding(.vertical, 8)

                    // Room lock/unlock (if owner/admin and in room)
                    if isInRoom && roomFeatures.canLockRoom {
                        ActionMenuItem(
                            icon: roomLockManager.isRoomLocked ? "lock.fill" : "lock.open.fill",
                            label: roomLockManager.isRoomLocked ? "Unlock Room" : "Lock Room",
                            shortcut: "Cmd+Opt+L",
                            description: roomLockManager.isRoomLocked ?
                                "Locked by \(roomLockManager.lockedByUsername ?? "owner")" :
                                "Prevent new users from joining",
                            isActive: roomLockManager.isRoomLocked
                        ) {
                            roomLockManager.toggleLock()
                        }
                    }

                    // Show lock indicator if locked (for non-owners)
                    if isInRoom && roomLockManager.isRoomLocked && !roomFeatures.canLockRoom {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.orange)
                            Text("Room locked by \(roomLockManager.lockedByUsername ?? "owner")")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }

                    // Room settings (if owner/admin)
                    ActionMenuItem(
                        icon: "gearshape",
                        label: "Room Settings",
                        shortcut: "Cmd+,",
                        description: "Configure room options"
                    ) {
                        // Show room settings
                    }

                    // Leave room (if in room)
                    if isInRoom {
                        ActionMenuItem(
                            icon: "arrow.left.circle",
                            label: "Leave Room",
                            shortcut: "Cmd+W",
                            description: nil,
                            isDestructive: true
                        ) {
                            serverManager.leaveRoom()
                            isPresented = false
                        }
                    }

                    // Join room (if not in room)
                    if !isInRoom {
                        ActionMenuItem(
                            icon: "arrow.right.circle.fill",
                            label: "Join Room",
                            shortcut: "Return",
                            description: nil,
                            isPrimary: true
                        ) {
                            // Join room
                            isPresented = false
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 320)
        .background(Color(white: 0.15))
        .cornerRadius(12)
        .shadow(radius: 20)
    }

    private func togglePeek() {
        if isPeeking {
            PeekManager.shared.stopPeeking()
        } else {
            PeekManager.shared.peekIntoRoom(room)
        }
        isPeeking.toggle()
    }
}

// MARK: - Room Features

struct RoomFeatures {
    var whisperEnabled: Bool
    var peekEnabled: Bool
    var spatialAudioEnabled: Bool
    var recordingAllowed: Bool
    var voiceEffectsEnabled: Bool
    var pttRequired: Bool
    var canLockRoom: Bool = false      // User has permission to lock room
    var isRoomLocked: Bool = false     // Current lock state
}

// MARK: - Room Lock Manager

class RoomLockManager: ObservableObject {
    static let shared = RoomLockManager()

    @Published var isRoomLocked = false
    @Published var lockedByUserId: String?
    @Published var lockedByUsername: String?
    @Published var canCurrentUserLock = false

    private var keyMonitor: Any?

    init() {
        setupKeyboardShortcut()
        setupNotifications()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Lock Control

    /// Lock the current room (if user has permission)
    func lockRoom() {
        guard canCurrentUserLock, !isRoomLocked else { return }

        isRoomLocked = true
        lockedByUserId = getCurrentUserId()
        lockedByUsername = getCurrentUsername()

        // Play lock sound
        AppSoundManager.shared.playSound(.toggleOn)

        // Notify server
        NotificationCenter.default.post(
            name: .roomLockStateChanged,
            object: nil,
            userInfo: [
                "locked": true,
                "userId": lockedByUserId ?? "",
                "username": lockedByUsername ?? ""
            ]
        )

        print("RoomLockManager: Room locked by \(lockedByUsername ?? "user")")
    }

    /// Unlock the current room
    func unlockRoom() {
        guard isRoomLocked else { return }

        // Only the user who locked can unlock, or room owner/admin
        let currentUser = getCurrentUserId()
        guard canCurrentUserLock || lockedByUserId == currentUser else {
            print("RoomLockManager: Cannot unlock - not authorized")
            return
        }

        isRoomLocked = false
        lockedByUserId = nil
        lockedByUsername = nil

        // Play unlock sound
        AppSoundManager.shared.playSound(.toggleOff)

        // Notify server
        NotificationCenter.default.post(
            name: .roomLockStateChanged,
            object: nil,
            userInfo: ["locked": false]
        )

        print("RoomLockManager: Room unlocked")
    }

    /// Toggle room lock state
    func toggleLock() {
        if isRoomLocked {
            unlockRoom()
        } else {
            lockRoom()
        }
    }

    // MARK: - Keyboard Shortcut (Cmd+Opt+L)

    private func setupKeyboardShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Check for Cmd+Opt+L (keyCode 37 is L)
            let hasCmd = event.modifierFlags.contains(.command)
            let hasOpt = event.modifierFlags.contains(.option)

            if event.keyCode == 37 && hasCmd && hasOpt {
                // Don't trigger if in text field
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }

                if self.canCurrentUserLock {
                    self.toggleLock()
                    return nil // Consume event
                }
            }
            return event
        }
    }

    // MARK: - Server Notifications

    private func setupNotifications() {
        // Listen for lock state changes from server
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleServerLockUpdate),
            name: .serverRoomLockUpdate,
            object: nil
        )

        // Listen for permission changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionUpdate),
            name: .roomPermissionsUpdated,
            object: nil
        )
    }

    @objc private func handleServerLockUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        DispatchQueue.main.async {
            self.isRoomLocked = userInfo["locked"] as? Bool ?? false
            self.lockedByUserId = userInfo["userId"] as? String
            self.lockedByUsername = userInfo["username"] as? String
        }
    }

    @objc private func handlePermissionUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        DispatchQueue.main.async {
            self.canCurrentUserLock = userInfo["canLock"] as? Bool ?? false
        }
    }

    // MARK: - Helpers

    private func getCurrentUserId() -> String? {
        return UserDefaults.standard.string(forKey: "clientId")
    }

    private func getCurrentUsername() -> String? {
        return UserDefaults.standard.string(forKey: "username")
    }

    // MARK: - Status

    func getLockStatus() -> [String: Any] {
        return [
            "isLocked": isRoomLocked,
            "canLock": canCurrentUserLock,
            "lockedBy": lockedByUsername ?? ""
        ]
    }
}

// MARK: - Room Lock Notifications

extension Notification.Name {
    static let roomLockStateChanged = Notification.Name("roomLockStateChanged")
    static let serverRoomLockUpdate = Notification.Name("serverRoomLockUpdate")
    static let roomPermissionsUpdated = Notification.Name("roomPermissionsUpdated")
}

// MARK: - Action Menu Components

struct ActionMenuSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.leading, 4)
                .padding(.top, 8)

            content()
        }
    }
}

struct ActionMenuItem: View {
    let icon: String
    let label: String
    let shortcut: String?
    let description: String?
    var isActive: Bool = false
    var isToggle: Bool = false
    var isToggled: Bool = false
    var isDestructive: Bool = false
    var isPrimary: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .foregroundColor(labelColor)

                    if let desc = description {
                        Text(desc)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }

                Spacer()

                if isToggle {
                    Toggle("", isOn: .constant(isToggled))
                        .labelsHidden()
                        .scaleEffect(0.8)
                }

                if let key = shortcut {
                    Text(key)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isActive ? Color.blue.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    var iconColor: Color {
        if isDestructive { return .red }
        if isPrimary { return .blue }
        if isActive { return .blue }
        return .white.opacity(0.8)
    }

    var labelColor: Color {
        if isDestructive { return .red }
        if isPrimary { return .blue }
        return .white
    }
}

struct UserVolumeMenuItem: View {
    let user: RoomUser
    @ObservedObject var audioControl = UserAudioControlManager.shared

    var volume: Float {
        audioControl.getVolume(for: user.odId)
    }

    var isMuted: Bool {
        audioControl.isMuted(user.odId)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Mute button
            Button(action: { audioControl.toggleMute(for: user.odId) }) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundColor(isMuted ? .red : .white.opacity(0.8))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            // Username
            Text(user.username)
                .foregroundColor(.white)
                .frame(width: 80, alignment: .leading)

            // Volume slider
            Slider(
                value: Binding(
                    get: { Double(volume) },
                    set: { audioControl.setVolume(for: user.odId, volume: Float($0)) }
                ),
                in: 0...2
            )
            .disabled(isMuted)

            // Volume buttons
            Button(action: { audioControl.decreaseVolume(for: user.odId) }) {
                Image(systemName: "minus")
            }
            .buttonStyle(.plain)

            Button(action: { audioControl.increaseVolume(for: user.odId) }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundColor(.white.opacity(0.7))
    }
}

// MARK: - Peek Manager

class PeekManager: ObservableObject {
    static let shared = PeekManager()

    @Published var isPeeking = false
    @Published var peekingRoom: Room?
    @Published var peekTimeRemaining: Int = 0

    private var peekTimer: Timer?
    private let maxPeekTime = 20 // seconds

    func peekIntoRoom(_ room: Room) {
        guard !isPeeking else { return }

        isPeeking = true
        peekingRoom = room
        peekTimeRemaining = maxPeekTime

        // Play peek in sound
        AppSoundManager.shared.playPeekInSound()

        // Start countdown timer
        peekTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.peekTimeRemaining -= 1
            if self.peekTimeRemaining <= 0 {
                self.stopPeeking()
            }
        }

        // Request audio preview from server
        NotificationCenter.default.post(
            name: .startPeekingRoom,
            object: nil,
            userInfo: ["roomId": room.id]
        )

        print("PeekManager: Started peeking into \(room.name)")
    }

    func stopPeeking() {
        guard isPeeking else { return }

        // Play peek out sound
        AppSoundManager.shared.playPeekOutSound()

        // Stop timer
        peekTimer?.invalidate()
        peekTimer = nil

        // Stop audio preview
        if let room = peekingRoom {
            NotificationCenter.default.post(
                name: .stopPeekingRoom,
                object: nil,
                userInfo: ["roomId": room.id]
            )
        }

        isPeeking = false
        peekingRoom = nil
        peekTimeRemaining = 0

        print("PeekManager: Stopped peeking")
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let startPeekingRoom = Notification.Name("startPeekingRoom")
    static let stopPeekingRoom = Notification.Name("stopPeekingRoom")
}

// MARK: - Peek Indicator View

struct PeekIndicator: View {
    @ObservedObject var peekManager = PeekManager.shared

    var body: some View {
        if peekManager.isPeeking, let room = peekManager.peekingRoom {
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .foregroundColor(.orange)

                Text("Peeking: \(room.name)")
                    .font(.caption)

                Text("\(peekManager.peekTimeRemaining)s")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.orange)

                Button(action: { peekManager.stopPeeking() }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.2))
            .cornerRadius(20)
            .foregroundColor(.white)
        }
    }
}

// MARK: - Room Lock Indicator View

struct RoomLockIndicator: View {
    @ObservedObject var lockManager = RoomLockManager.shared

    var body: some View {
        if lockManager.isRoomLocked {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.orange)

                Text("Room Locked")
                    .font(.caption)
                    .foregroundColor(.orange)

                if lockManager.canCurrentUserLock {
                    Button(action: { lockManager.unlockRoom() }) {
                        Text("Unlock")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(16)
        }
    }
}

// MARK: - Room Lock Button (for toolbar)

struct RoomLockButton: View {
    @ObservedObject var lockManager = RoomLockManager.shared

    var body: some View {
        if lockManager.canCurrentUserLock {
            Button(action: { lockManager.toggleLock() }) {
                Image(systemName: lockManager.isRoomLocked ? "lock.fill" : "lock.open")
                    .foregroundColor(lockManager.isRoomLocked ? .orange : .white)
            }
            .buttonStyle(.plain)
            .help(lockManager.isRoomLocked ? "Unlock Room (Cmd+Opt+L)" : "Lock Room (Cmd+Opt+L)")
            .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
