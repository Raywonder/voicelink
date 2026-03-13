import SwiftUI
import AppKit
import CoreAudio

struct UserProfileSheet: View {
    let userId: String
    let username: String
    let isCurrentUser: Bool
    let roomUser: RoomUser?
    let roomName: String?
    let connectedServerName: String?
    let isRoomAudioActive: Bool
    let isUserMuted: Bool
    let isSoloed: Bool
    let monitorIsActive: Bool
    let onDirectMessage: () -> Void
    let onSendFile: () -> Void
    let onToggleMute: () -> Void
    let onToggleSolo: () -> Void
    let onToggleMonitor: () -> Void
    let onGrantModerator: (() -> Void)?
    let onGrantAdmin: (() -> Void)?
    let onRevokeElevatedAccess: (() -> Void)?
    let onKickFromRoom: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var authManager = AuthenticationManager.shared
    @ObservedObject private var adminManager = AdminServerManager.shared

    private var authenticatedUser: AuthenticatedUser? {
        isCurrentUser ? authManager.currentUser : nil
    }

    private var effectiveDisplayName: String {
        roomUser?.displayName
            ?? authenticatedUser?.displayName
            ?? username
    }

    private var effectiveUserId: String {
        authenticatedUser?.id ?? userId
    }

    private var effectiveRole: String? {
        roomUser?.role ?? authenticatedUser?.role
    }

    private var effectiveStatus: String? {
        if let status = roomUser?.status, !status.isEmpty {
            return status
        }
        return isCurrentUser ? "Signed in" : nil
    }

    private var effectiveAuthProvider: String? {
        roomUser?.authProvider ?? authenticatedUser?.authProvider
    }

    private var effectiveEmail: String? {
        roomUser?.email ?? authenticatedUser?.email
    }

    private var effectiveServerTitle: String? {
        roomUser?.serverTitle ?? connectedServerName
    }

    private var effectiveJoinedAt: Date? {
        roomUser?.joinedAt
    }

    private var effectiveLastActiveAt: Date? {
        roomUser?.lastActiveAt
    }

    private var avatarInitials: String {
        let source = effectiveDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "?" }
        return String(source.prefix(1)).uppercased()
    }

    private var canManageThisUser: Bool {
        !isCurrentUser && (adminManager.isAdmin || adminManager.adminRole.canManageUsers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                Circle()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Text(avatarInitials)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(effectiveDisplayName)
                        .font(.title2)
                        .fontWeight(.semibold)

                    if effectiveDisplayName.caseInsensitiveCompare(username) != .orderedSame {
                        Text(username)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }

                    Text(isCurrentUser ? "Current user" : "Room participant")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
            }

            GroupBox("Details") {
                VStack(alignment: .leading, spacing: 10) {
                    detailRow("User ID", value: effectiveUserId)
                    detailRow("Role", value: effectiveRole)
                    detailRow("Status", value: effectiveStatus)
                    detailRow("Auth Provider", value: effectiveAuthProvider)
                    detailRow("Email", value: effectiveEmail)
                    detailRow("Room", value: roomName)
                    detailRow("Server", value: effectiveServerTitle)
                    detailRow("Joined", value: formattedDate(effectiveJoinedAt))
                    detailRow("Last Activity", value: formattedDate(effectiveLastActiveAt))
                }
            }

            GroupBox("Audio State") {
                VStack(alignment: .leading, spacing: 10) {
                    detailRow("Speaking", value: statusLabel(roomUser?.isSpeaking ?? false))
                    detailRow("Muted", value: statusLabel(roomUser?.isMuted ?? false))
                    detailRow("Deafened", value: statusLabel(roomUser?.isDeafened ?? false))
                    detailRow("Room Audio", value: isRoomAudioActive ? "Active" : "Inactive")
                    if isCurrentUser {
                        detailRow("Self Monitor", value: monitorIsActive ? "Enabled" : "Disabled")
                    } else {
                        detailRow("Local Mute", value: isUserMuted ? "Enabled" : "Disabled")
                        detailRow("Solo", value: isSoloed ? "Enabled" : "Disabled")
                    }
                }
            }

            GroupBox("Actions") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button(isCurrentUser ? "Open Saved Items" : "Send Direct Message") {
                            onDirectMessage()
                        }
                        Button(isCurrentUser ? "Save File for Later..." : "Send File...") {
                            onSendFile()
                        }
                        Button("Copy User ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(userId, forType: .string)
                        }
                    }

                    HStack(spacing: 10) {
                        if isCurrentUser {
                            Button(monitorIsActive ? "Stop Self Monitor" : "Start Self Monitor") {
                                onToggleMonitor()
                            }
                        } else {
                            Button(isUserMuted ? "Unmute User Locally" : "Mute User Locally") {
                                onToggleMute()
                            }
                            Button(isSoloed ? "Unsolo User" : "Solo User") {
                                onToggleSolo()
                            }
                        }
                    }

                    if canManageThisUser {
                        Divider()
                        HStack(spacing: 10) {
                            if let onGrantModerator {
                                Button("Grant Moderator") {
                                    onGrantModerator()
                                }
                            }
                            if let onGrantAdmin {
                                Button("Grant Admin") {
                                    onGrantAdmin()
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            if let onRevokeElevatedAccess {
                                Button("Revoke Elevated Access", role: .destructive) {
                                    onRevokeElevatedAccess()
                                }
                            }
                            if let onKickFromRoom {
                                Button("Kick From Room", role: .destructive) {
                                    onKickFromRoom()
                                }
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile for \(effectiveDisplayName)")
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .fontWeight(.semibold)
                .frame(width: 110, alignment: .leading)
            Text((value?.isEmpty == false ? value! : "Not available"))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func formattedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func statusLabel(_ flag: Bool) -> String {
        flag ? "Yes" : "No"
    }
}

struct VoiceControlButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                Text(label)
                    .font(.caption)
            }
            .frame(width: 80, height: 80)
            .background(isActive ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            .foregroundColor(isActive ? .green : .red)
            .cornerRadius(40)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sync Mode Enum
enum SyncMode: String, CaseIterable, Identifiable {
    case all = "all"
    case federation = "federation"
    case personalFederated = "personal_federated"
    case personalRooms = "personal_rooms"
    case allRoomTypes = "all_room_types"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All Servers"
        case .federation: return "Main Federation"
        case .personalFederated: return "Personal Federated"
        case .personalRooms: return "Personal Rooms (Hidden)"
        case .allRoomTypes: return "All Room Types"
        }
    }

    var description: String {
        switch self {
        case .all: return "Show all available servers and rooms"
        case .federation: return "Main VoiceLink federation network"
        case .personalFederated: return "Your personal federated servers"
        case .personalRooms: return "Private rooms not visible publicly"
        case .allRoomTypes: return "All room types including private"
        }
    }

    var icon: String {
        switch self {
        case .all: return "globe"
        case .federation: return "network"
        case .personalFederated: return "person.3.fill"
        case .personalRooms: return "lock.shield"
        case .allRoomTypes: return "square.grid.2x2"
        }
    }
}

// MARK: - File Receive Mode
enum FileReceiveMode: String, CaseIterable {
    case autoReceive = "auto"
    case askAlways = "ask"
    case askOnce = "askOnce" // Ask once per sender
    case blockAll = "block"

    var displayName: String {
        switch self {
        case .autoReceive: return "Auto-receive files"
        case .askAlways: return "Ask every time"
        case .askOnce: return "Ask once per sender"
        case .blockAll: return "Block all transfers"
        }
    }

    var icon: String {
        switch self {
        case .autoReceive: return "arrow.down.circle.fill"
        case .askAlways: return "questionmark.circle"
        case .askOnce: return "person.badge.clock"
        case .blockAll: return "xmark.shield"
        }
    }
}

struct ManagedFederationServer: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let url: String
    let description: String

    var host: String {
        URL(string: url)?.host?.lowercased() ?? url.lowercased()
    }
}

enum RoomHostingPreference: String, CaseIterable, Identifiable {
    case currentServer = "currentServer"
    case primaryServer = "primaryServer"
    case communityVPS = "communityVPS"
    case favoriteServer = "favoriteServer"
    case mostUsedServer = "mostUsedServer"
    case randomFederated = "randomFederated"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .currentServer: return "Current Server"
        case .primaryServer: return "Main Server"
        case .communityVPS: return "Community VPS"
        case .favoriteServer: return "Favorite Server"
        case .mostUsedServer: return "Most Used Server"
        case .randomFederated: return "Random Online Server"
        }
    }

    var description: String {
        switch self {
        case .currentServer: return "Create on the server you are currently connected to."
        case .primaryServer: return "Prefer the main VoiceLink server."
        case .communityVPS: return "Prefer the synced community VPS."
        case .favoriteServer: return "Use your preferred linked server when available."
        case .mostUsedServer: return "Use the server you join most often."
        case .randomFederated: return "Let the backend choose a healthy federated server."
        }
    }

    var preferredServerBase: String? {
        switch self {
        case .currentServer, .favoriteServer, .mostUsedServer, .randomFederated:
            return nil
        case .primaryServer:
            return APIEndpointResolver.canonicalMainBase
        case .communityVPS:
            return APIEndpointResolver.communityNode2Base
        }
    }
}

enum HandoffPromptMode: String, CaseIterable, Identifiable {
    case askAlways = "askAlways"
    case askOnce = "askOnce"
    case autoUseSavedChoice = "autoUseSavedChoice"
    case serverRecommended = "serverRecommended"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .askAlways: return "Ask Every Time"
        case .askOnce: return "Ask Once"
        case .autoUseSavedChoice: return "Auto-use Saved Choice"
        case .serverRecommended: return "Use Server Recommendation"
        }
    }

    var description: String {
        switch self {
        case .askAlways: return "Always ask before moving you to another server during maintenance or failover."
        case .askOnce: return "Ask once, then remember the action you choose until you change it."
        case .autoUseSavedChoice: return "Automatically use the action you previously chose."
        case .serverRecommended: return "Use the server owner's default handoff recommendation unless you override it."
        }
    }
}

struct CustomFederationServer: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var federationEnabled: Bool

    init(id: UUID = UUID(), name: String, url: String, federationEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.federationEnabled = federationEnabled
    }

    var host: String {
        let normalized = url.hasPrefix("http://") || url.hasPrefix("https://") ? url : "https://\(url)"
        return URL(string: normalized)?.host?.lowercased() ?? url.lowercased()
    }
}

// MARK: - Settings Manager
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    static let managedFederationServers: [ManagedFederationServer] = [
        ManagedFederationServer(
            id: "main",
            name: "Main VoiceLink",
            url: APIEndpointResolver.canonicalMainBase,
            description: "Primary VoiceLink server managed through the main API."
        ),
        ManagedFederationServer(
            id: "community-vps",
            name: "Community VPS",
            url: APIEndpointResolver.communityNode2Base,
            description: "Community VPS mirror that shares federated room data with main."
        )
    ]
    private var isApplyingAudioDeviceSelection = false
    private var audioDeviceRefreshTimer: Timer?
    private var lastAudioDeviceSignature: String = ""

    enum CloseButtonBehavior: String, CaseIterable {
        case goToMainThenHide = "goToMainThenHide"
        case hideToTray = "hideToTray"
        case minimizeWindow = "minimizeWindow"
    }

    // Audio Settings
    @Published var inputDevice: String = "Default"
    @Published var outputDevice: String = "Default"
    @Published var inputVolume: Double = 0.8
    @Published var outputVolume: Double = 0.8
    @Published var noiseSuppression: Bool = true
    @Published var echoCancellation: Bool = true
    @Published var autoGainControl: Bool = true

    // Sync Settings
    @Published var syncMode: SyncMode = .all {
        didSet {
            UserDefaults().set(syncMode.rawValue, forKey: "syncMode")
            NotificationCenter.default.post(name: .syncModeChanged, object: syncMode)
        }
    }
    @Published var showPrivateMemberRooms: Bool = true
    @Published var showFederatedRooms: Bool = true
    @Published var showLocalOnlyRooms: Bool = true
    @Published var customFederationServers: [CustomFederationServer] = []
    @Published var handoffPromptMode: HandoffPromptMode = .serverRecommended

    // Connection Settings
    @Published var autoConnect: Bool = true
    @Published var preferLocalServer: Bool = true
    @Published var reconnectOnDisconnect: Bool = true
    @Published var connectionTimeout: Double = 30

    // PTT Settings
    @Published var pttEnabled: Bool = false
    @Published var pttKey: String = "Space"

    // Notifications
    @Published var soundNotifications: Bool = true
    @Published var desktopNotifications: Bool = true
    @Published var notifyOnJoin: Bool = true
    @Published var notifyOnLeave: Bool = true
    @Published var systemActionNotifications: Bool = true
    @Published var systemActionNotificationSound: Bool = true

    // Privacy
    @Published var showOnlineStatus: Bool = true
    @Published var allowDirectMessages: Bool = true

    // File Sharing Settings
    @Published var fileReceiveMode: FileReceiveMode = .askAlways
    @Published var autoReceiveTimeLimit: Int = 30 // minutes, 0 = always
    @Published var maxAutoReceiveSize: Int = 100 // MB
    @Published var saveReceivedFilesTo: String = "~/Downloads/VoiceLink"

    // Mastodon Integration Settings
    @Published var useMastodonForDM: Bool = false
    @Published var autoCreateThreads: Bool = true // Auto-create threads for messages > 500 chars
    @Published var storeMastodonDMsLocally: Bool = true // Keep copy in VoiceLink
    @Published var useMastodonForFileStorage: Bool = false // Use instance for media (future)

    // 3D Audio
    @Published var spatialAudioEnabled: Bool = true
    @Published var headTrackingEnabled: Bool = false

    // UI Settings
    @Published var showAudioControlsOnStartup: Bool = true
    @Published var closeButtonBehavior: CloseButtonBehavior = .goToMainThenHide
    enum StartupBehavior: String, CaseIterable {
        case openMainWindow = "openMainWindow"
        case restoreCurrentRoom = "restoreCurrentRoom"
        case rejoinLastRoom = "rejoinLastRoom"
    }
    @Published var startupBehavior: StartupBehavior = .openMainWindow
    @Published var startupAmbienceEnabled: Bool = true
    @Published var suppressSelfMonitoringPrompt: Bool = false
    @Published var confirmBeforeQuit: Bool = false
    @Published var confirmBeforeDeletingRooms: Bool = true
    @Published var showRoomDescriptions: Bool = true
    @Published var showUserStatusesInRoomList: Bool = true
    @Published var allowVoiceInRoomPreview: Bool = true
    @Published var previewSoundCuesEnabled: Bool = true
    @Published var roomPreviewPolicyByRoom: [String: Bool] = [:]
    enum RoomPrimaryAction: String, CaseIterable {
        case openDetails = "openDetails"
        case joinOrShow = "joinOrShow"
        case preview = "preview"
        case share = "share"
    }
    @Published var defaultRoomPrimaryAction: RoomPrimaryAction = .joinOrShow
    @Published var adminGodModeEnabled: Bool = false
    @Published var adminInvisibleMode: Bool = false

    // Advanced / diagnostics
    @Published var debugLoggingEnabled: Bool = false
    @Published var showConnectionStats: Bool = true
    @Published var autoSendDiagnostics: Bool = true
    @Published var shareCrashReports: Bool = true
    @Published var preferredAudioCodec: String = "Opus"

    // Profile Settings
    @Published var userNickname: String = ""
    @Published var userGender: String = "Prefer not to say"
    @Published var userProfileLinks: [String] = []

    // Available devices
    @Published var availableInputDevices: [String] = ["Default"]
    @Published var availableOutputDevices: [String] = ["Default"]
    private var hasCompletedInitialAudioSetup = false

    init() {
        loadSettings()
        DispatchQueue.main.async { [weak self] in
            self?.finishInitialAudioSetup()
        }
    }

    deinit {
        audioDeviceRefreshTimer?.invalidate()
    }

    func loadSettings() {
        if let mode = UserDefaults().string(forKey: "syncMode"),
           let syncMode = SyncMode(rawValue: mode) {
            self.syncMode = syncMode
        }
        showPrivateMemberRooms = UserDefaults().object(forKey: "showPrivateMemberRooms") as? Bool ?? true
        showFederatedRooms = UserDefaults().object(forKey: "showFederatedRooms") as? Bool ?? true
        showLocalOnlyRooms = UserDefaults().object(forKey: "showLocalOnlyRooms") as? Bool ?? true
        if let stored = UserDefaults().string(forKey: "handoffPromptMode"),
           let parsed = HandoffPromptMode(rawValue: stored) {
            handoffPromptMode = parsed
        } else {
            handoffPromptMode = .serverRecommended
        }
        if let data = UserDefaults().data(forKey: "customFederationServers"),
           let decoded = try? JSONDecoder().decode([CustomFederationServer].self, from: data) {
            customFederationServers = decoded
        } else {
            customFederationServers = []
        }

        if let savedInputDevice = UserDefaults().string(forKey: "inputDevice"), !savedInputDevice.isEmpty {
            inputDevice = savedInputDevice
        }

        if let savedOutputDevice = UserDefaults().string(forKey: "outputDevice"), !savedOutputDevice.isEmpty {
            outputDevice = savedOutputDevice
        }

        inputVolume = UserDefaults().double(forKey: "inputVolume")
        if inputVolume == 0 { inputVolume = 0.8 }

        outputVolume = UserDefaults().double(forKey: "outputVolume")
        if outputVolume == 0 { outputVolume = 0.8 }
        confirmBeforeDeletingRooms = UserDefaults().object(forKey: "confirmBeforeDeletingRooms") as? Bool ?? true

        noiseSuppression = UserDefaults().bool(forKey: "noiseSuppression")
        echoCancellation = UserDefaults().bool(forKey: "echoCancellation")
        autoGainControl = UserDefaults().bool(forKey: "autoGainControl")
        autoConnect = UserDefaults().bool(forKey: "autoConnect")
        preferLocalServer = UserDefaults().bool(forKey: "preferLocalServer")
        pttEnabled = UserDefaults().bool(forKey: "pttEnabled")
        spatialAudioEnabled = UserDefaults().bool(forKey: "spatialAudioEnabled")

        // UI settings
        showAudioControlsOnStartup = UserDefaults().object(forKey: "showAudioControlsOnStartup") as? Bool ?? true
        if let value = UserDefaults().string(forKey: "closeButtonBehavior"),
           let parsed = CloseButtonBehavior(rawValue: value) {
            closeButtonBehavior = parsed
        } else {
            closeButtonBehavior = .goToMainThenHide
        }
        if let value = UserDefaults().string(forKey: "startupBehavior"),
           let parsed = StartupBehavior(rawValue: value) {
            startupBehavior = parsed
        } else if UserDefaults().object(forKey: "openMainWindowOnLaunch") as? Bool == false {
            startupBehavior = .restoreCurrentRoom
        } else {
            startupBehavior = .openMainWindow
        }
        startupAmbienceEnabled = UserDefaults().object(forKey: "startupAmbienceEnabled") as? Bool ?? true
        suppressSelfMonitoringPrompt = UserDefaults().object(forKey: "suppressSelfMonitoringPrompt") as? Bool ?? false
        confirmBeforeQuit = UserDefaults().object(forKey: "confirmBeforeQuit") as? Bool ?? false
        showRoomDescriptions = UserDefaults().object(forKey: "showRoomDescriptions") as? Bool ?? true
        showUserStatusesInRoomList = UserDefaults().object(forKey: "showUserStatusesInRoomList") as? Bool ?? true
        if let stored = UserDefaults().object(forKey: "allowVoiceInRoomPreview") as? Bool {
            allowVoiceInRoomPreview = stored
        } else {
            allowVoiceInRoomPreview = UserDefaults().object(forKey: "allowPreviewWhenMediaActive") as? Bool ?? true
        }
        previewSoundCuesEnabled = UserDefaults().object(forKey: "previewSoundCuesEnabled") as? Bool ?? true
        roomPreviewPolicyByRoom = UserDefaults().dictionary(forKey: "roomPreviewPolicyByRoom") as? [String: Bool] ?? [:]
        if let value = UserDefaults().string(forKey: "defaultRoomPrimaryAction"),
           let parsed = RoomPrimaryAction(rawValue: value) {
            defaultRoomPrimaryAction = parsed
        } else {
            defaultRoomPrimaryAction = .joinOrShow
        }
        if !UserDefaults().bool(forKey: "migratedDefaultRoomActionToJoin"),
           defaultRoomPrimaryAction == .openDetails {
            defaultRoomPrimaryAction = .joinOrShow
            UserDefaults().set(defaultRoomPrimaryAction.rawValue, forKey: "defaultRoomPrimaryAction")
            UserDefaults().set(true, forKey: "migratedDefaultRoomActionToJoin")
        }
        adminGodModeEnabled = UserDefaults().object(forKey: "adminGodModeEnabled") as? Bool ?? false
        adminInvisibleMode = UserDefaults().object(forKey: "adminInvisibleMode") as? Bool ?? false
        debugLoggingEnabled = UserDefaults().object(forKey: "debugLoggingEnabled") as? Bool ?? false
        showConnectionStats = UserDefaults().object(forKey: "showConnectionStats") as? Bool ?? true
        autoSendDiagnostics = UserDefaults().object(forKey: "autoSendDiagnostics") as? Bool ?? true
        shareCrashReports = UserDefaults().object(forKey: "shareCrashReports") as? Bool ?? true
        preferredAudioCodec = UserDefaults().string(forKey: "preferredAudioCodec") ?? "Opus"

        // Profile settings
        userNickname = UserDefaults().string(forKey: "userNickname") ?? ""
        userGender = UserDefaults().string(forKey: "userGender") ?? "Prefer not to say"
        userProfileLinks = UserDefaults().stringArray(forKey: "userProfileLinks") ?? []

        // File sharing settings
        if let mode = UserDefaults().string(forKey: "fileReceiveMode"),
           let receiveMode = FileReceiveMode(rawValue: mode) {
            self.fileReceiveMode = receiveMode
        }
        autoReceiveTimeLimit = UserDefaults().integer(forKey: "autoReceiveTimeLimit")
        if autoReceiveTimeLimit == 0 { autoReceiveTimeLimit = 30 }
        maxAutoReceiveSize = UserDefaults().integer(forKey: "maxAutoReceiveSize")
        if maxAutoReceiveSize == 0 { maxAutoReceiveSize = 100 }
        if let savePath = UserDefaults().string(forKey: "saveReceivedFilesTo") {
            saveReceivedFilesTo = savePath
        }

        // Mastodon settings
        useMastodonForDM = UserDefaults().bool(forKey: "useMastodonForDM")
        autoCreateThreads = UserDefaults().bool(forKey: "autoCreateThreads")
        storeMastodonDMsLocally = UserDefaults().bool(forKey: "storeMastodonDMsLocally")
        useMastodonForFileStorage = UserDefaults().bool(forKey: "useMastodonForFileStorage")
        soundNotifications = UserDefaults().object(forKey: "soundNotifications") as? Bool ?? true
        desktopNotifications = UserDefaults().object(forKey: "desktopNotifications") as? Bool ?? true
        notifyOnJoin = UserDefaults().object(forKey: "notifyOnJoin") as? Bool ?? true
        notifyOnLeave = UserDefaults().object(forKey: "notifyOnLeave") as? Bool ?? true
        systemActionNotifications = UserDefaults().object(forKey: "systemActionNotifications") as? Bool ?? true
        systemActionNotificationSound = UserDefaults().object(forKey: "systemActionNotificationSound") as? Bool ?? true

        // Defaults that should be true
        if !UserDefaults().bool(forKey: "settingsInitialized") {
            noiseSuppression = true
            echoCancellation = true
            autoGainControl = true
            autoConnect = true
            preferLocalServer = true
            soundNotifications = true
            desktopNotifications = true
            notifyOnJoin = true
            notifyOnLeave = true
            systemActionNotifications = true
            systemActionNotificationSound = true
            showOnlineStatus = true
            allowDirectMessages = true
            showPrivateMemberRooms = true
            showFederatedRooms = true
            showLocalOnlyRooms = true
            spatialAudioEnabled = true
            reconnectOnDisconnect = true
            showAudioControlsOnStartup = true
            closeButtonBehavior = .goToMainThenHide
            startupBehavior = .openMainWindow
            startupAmbienceEnabled = true
            suppressSelfMonitoringPrompt = false
            confirmBeforeQuit = false
            showRoomDescriptions = true
            showUserStatusesInRoomList = true
            allowVoiceInRoomPreview = true
            previewSoundCuesEnabled = true
            defaultRoomPrimaryAction = .joinOrShow
            adminGodModeEnabled = false
            adminInvisibleMode = false
            debugLoggingEnabled = false
            showConnectionStats = true
            autoSendDiagnostics = true
            shareCrashReports = true
            preferredAudioCodec = "Opus"
            UserDefaults().set(true, forKey: "settingsInitialized")
        }
    }

    func saveSettings() {
        UserDefaults().set(syncMode.rawValue, forKey: "syncMode")
        UserDefaults().set(showPrivateMemberRooms, forKey: "showPrivateMemberRooms")
        UserDefaults().set(showFederatedRooms, forKey: "showFederatedRooms")
        UserDefaults().set(showLocalOnlyRooms, forKey: "showLocalOnlyRooms")
        UserDefaults().set(handoffPromptMode.rawValue, forKey: "handoffPromptMode")
        if let customData = try? JSONEncoder().encode(customFederationServers) {
            UserDefaults().set(customData, forKey: "customFederationServers")
        }
        UserDefaults().set(inputDevice, forKey: "inputDevice")
        UserDefaults().set(outputDevice, forKey: "outputDevice")
        UserDefaults().set(inputVolume, forKey: "inputVolume")
        UserDefaults().set(outputVolume, forKey: "outputVolume")
        UserDefaults().set(confirmBeforeDeletingRooms, forKey: "confirmBeforeDeletingRooms")
        UserDefaults().set(noiseSuppression, forKey: "noiseSuppression")
        UserDefaults().set(echoCancellation, forKey: "echoCancellation")
        UserDefaults().set(autoGainControl, forKey: "autoGainControl")
        UserDefaults().set(autoConnect, forKey: "autoConnect")
        UserDefaults().set(preferLocalServer, forKey: "preferLocalServer")
        UserDefaults().set(pttEnabled, forKey: "pttEnabled")
        UserDefaults().set(spatialAudioEnabled, forKey: "spatialAudioEnabled")

        // UI settings
        UserDefaults().set(showAudioControlsOnStartup, forKey: "showAudioControlsOnStartup")
        UserDefaults().set(closeButtonBehavior.rawValue, forKey: "closeButtonBehavior")
        UserDefaults().set(startupBehavior.rawValue, forKey: "startupBehavior")
        UserDefaults().set(startupAmbienceEnabled, forKey: "startupAmbienceEnabled")
        UserDefaults().set(suppressSelfMonitoringPrompt, forKey: "suppressSelfMonitoringPrompt")
        UserDefaults().set(confirmBeforeQuit, forKey: "confirmBeforeQuit")
        UserDefaults().set(showRoomDescriptions, forKey: "showRoomDescriptions")
        UserDefaults().set(showUserStatusesInRoomList, forKey: "showUserStatusesInRoomList")
        UserDefaults().set(allowVoiceInRoomPreview, forKey: "allowVoiceInRoomPreview")
        UserDefaults().set(previewSoundCuesEnabled, forKey: "previewSoundCuesEnabled")
        UserDefaults().set(roomPreviewPolicyByRoom, forKey: "roomPreviewPolicyByRoom")
        UserDefaults().set(defaultRoomPrimaryAction.rawValue, forKey: "defaultRoomPrimaryAction")
        UserDefaults().set(adminGodModeEnabled, forKey: "adminGodModeEnabled")
        UserDefaults().set(adminInvisibleMode, forKey: "adminInvisibleMode")
        UserDefaults().set(debugLoggingEnabled, forKey: "debugLoggingEnabled")
        UserDefaults().set(showConnectionStats, forKey: "showConnectionStats")
        UserDefaults().set(autoSendDiagnostics, forKey: "autoSendDiagnostics")
        UserDefaults().set(shareCrashReports, forKey: "shareCrashReports")
        UserDefaults().set(preferredAudioCodec, forKey: "preferredAudioCodec")

        // Profile settings
        UserDefaults().set(userNickname, forKey: "userNickname")
        UserDefaults().set(userGender, forKey: "userGender")
        UserDefaults().set(userProfileLinks, forKey: "userProfileLinks")

        // File sharing settings
        UserDefaults().set(fileReceiveMode.rawValue, forKey: "fileReceiveMode")
        UserDefaults().set(autoReceiveTimeLimit, forKey: "autoReceiveTimeLimit")
        UserDefaults().set(maxAutoReceiveSize, forKey: "maxAutoReceiveSize")
        UserDefaults().set(saveReceivedFilesTo, forKey: "saveReceivedFilesTo")

        // Mastodon settings
        UserDefaults().set(useMastodonForDM, forKey: "useMastodonForDM")
        UserDefaults().set(autoCreateThreads, forKey: "autoCreateThreads")
        UserDefaults().set(storeMastodonDMsLocally, forKey: "storeMastodonDMsLocally")
        UserDefaults().set(useMastodonForFileStorage, forKey: "useMastodonForFileStorage")
        UserDefaults().set(soundNotifications, forKey: "soundNotifications")
        UserDefaults().set(desktopNotifications, forKey: "desktopNotifications")
        UserDefaults().set(notifyOnJoin, forKey: "notifyOnJoin")
        UserDefaults().set(notifyOnLeave, forKey: "notifyOnLeave")
        UserDefaults().set(systemActionNotifications, forKey: "systemActionNotifications")
        UserDefaults().set(systemActionNotificationSound, forKey: "systemActionNotificationSound")

        // Apply selected devices so audio routing follows settings in active sessions.
        applySelectedAudioDevices()
        NotificationCenter.default.post(
            name: .settingsDidAutoSave,
            object: nil,
            userInfo: ["savedAt": Date()]
        )
    }

    func resetToDefaults() {
        syncMode = .all
        showPrivateMemberRooms = true
        showFederatedRooms = true
        showLocalOnlyRooms = true
        handoffPromptMode = .serverRecommended
        customFederationServers = []
        inputVolume = 0.8
        outputVolume = 0.8
        noiseSuppression = true
        echoCancellation = true
        autoGainControl = true
        autoConnect = true
        preferLocalServer = true
        reconnectOnDisconnect = true
        pttEnabled = false
        pttKey = "Space"
        soundNotifications = true
        desktopNotifications = true
        notifyOnJoin = true
        notifyOnLeave = true
        systemActionNotifications = true
        systemActionNotificationSound = true
        showOnlineStatus = true
        allowDirectMessages = true
        fileReceiveMode = .askAlways
        autoReceiveTimeLimit = 30
        maxAutoReceiveSize = 100
        saveReceivedFilesTo = "~/Downloads/VoiceLink"
        useMastodonForDM = false
        autoCreateThreads = true
        storeMastodonDMsLocally = true
        useMastodonForFileStorage = false
        spatialAudioEnabled = true
        headTrackingEnabled = false
        showAudioControlsOnStartup = true
        closeButtonBehavior = .goToMainThenHide
        startupBehavior = .openMainWindow
        startupAmbienceEnabled = true
        suppressSelfMonitoringPrompt = false
        confirmBeforeQuit = false
        confirmBeforeDeletingRooms = true
        showRoomDescriptions = true
        showUserStatusesInRoomList = true
        allowVoiceInRoomPreview = true
        previewSoundCuesEnabled = true
        defaultRoomPrimaryAction = .joinOrShow
        adminGodModeEnabled = false
        adminInvisibleMode = false
        debugLoggingEnabled = false
        showConnectionStats = true
        autoSendDiagnostics = true
        shareCrashReports = true
        preferredAudioCodec = "Opus"
        saveSettings()
    }

    func addCustomFederationServer(name: String, url: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        let normalizedURL = trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://") ? trimmedURL : "https://\(trimmedURL)"
        let displayName = trimmedName.isEmpty ? (URL(string: normalizedURL)?.host ?? normalizedURL) : trimmedName
        let candidate = CustomFederationServer(name: displayName, url: normalizedURL, federationEnabled: true)
        guard !customFederationServers.contains(where: { $0.host == candidate.host }) else { return }
        customFederationServers.append(candidate)
        customFederationServers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveSettings()
    }

    func removeCustomFederationServer(_ server: CustomFederationServer) {
        customFederationServers.removeAll { $0.id == server.id }
        saveSettings()
    }

    func updateCustomFederationServerEnabled(_ enabled: Bool, for server: CustomFederationServer) {
        guard let index = customFederationServers.firstIndex(where: { $0.id == server.id }) else { return }
        customFederationServers[index].federationEnabled = enabled
        saveSettings()
    }

    func isVisibleFederationHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return true }

        if Self.managedFederationServers.contains(where: { normalizedHost.contains($0.host) || $0.host.contains(normalizedHost) }) {
            return true
        }

        if let custom = customFederationServers.first(where: { normalizedHost.contains($0.host) || $0.host.contains(normalizedHost) }) {
            return custom.federationEnabled
        }

        return true
    }

    func displayNameForFederationHost(_ host: String) -> String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return host }

        if let managed = Self.managedFederationServers.first(where: {
            normalizedHost.contains($0.host) || $0.host.contains(normalizedHost)
        }) {
            return managed.name
        }

        if let custom = customFederationServers.first(where: {
            normalizedHost.contains($0.host) || $0.host.contains(normalizedHost)
        }) {
            return custom.name
        }

        return host
    }

    func roomPreviewOverride(for roomId: String) -> Bool? {
        roomPreviewPolicyByRoom[roomId]
    }

    func effectiveHandoffPromptMode(serverDefault: String?) -> HandoffPromptMode {
        if handoffPromptMode != .serverRecommended {
            return handoffPromptMode
        }
        guard let serverDefault,
              let parsed = HandoffPromptMode(rawValue: serverDefault) else {
            return .askAlways
        }
        return parsed
    }

    func setRoomPreviewOverride(roomId: String, enabled: Bool?) {
        if let enabled {
            roomPreviewPolicyByRoom[roomId] = enabled
        } else {
            roomPreviewPolicyByRoom.removeValue(forKey: roomId)
        }
        saveSettings()
    }

    func canPreviewRoom(roomId: String, userCount: Int, hasActiveMedia: Bool) -> Bool {
        if roomPreviewPolicyByRoom[roomId] == false {
            return false
        }
        return true
    }

    func mergeProfileLinks(_ incoming: [String], replaceExisting: Bool = false) {
        let seed = replaceExisting ? [] : userProfileLinks
        var merged: [String] = []
        var seen = Set<String>()

        for value in seed + incoming {
            guard let normalized = normalizeProfileLink(value) else { continue }
            let key = normalized.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(normalized)
            }
        }

        userProfileLinks = merged
    }

    func removeProfileLink(_ link: String) {
        let key = link.lowercased()
        userProfileLinks.removeAll { $0.lowercased() == key }
    }

    private func normalizeProfileLink(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if !lower.hasPrefix("http://") &&
            !lower.hasPrefix("https://") &&
            !lower.hasPrefix("mailto:") &&
            !lower.hasPrefix("tel:") {
            value = "https://\(value)"
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme,
              !scheme.isEmpty else { return nil }
        return components.string
    }

    func detectAudioDevices() {
        detectAudioDevices(applySelectionIfNeeded: true)
    }

    private func finishInitialAudioSetup() {
        detectAudioDevices(applySelectionIfNeeded: false)
        startAudioDeviceRefreshMonitoring()
        hasCompletedInitialAudioSetup = true
    }

    func detectAudioDevices(applySelectionIfNeeded: Bool) {
        // Detect input devices
        var inputDevices = ["Default"]
        var outputDevices = ["Default"]

        // Get audio devices using CoreAudio
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize)
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceIDs)

        for deviceID in deviceIDs {
            // Get device name
            var nameSize: UInt32 = 256
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var name: CFString = "" as CFString
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            let deviceName = name as String

            // Check if input device
            var inputStreamSize: UInt32 = 0
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputStreamSize)
            if inputStreamSize > 0 && !deviceName.isEmpty {
                inputDevices.append(deviceName)
            }

            // Check if output device
            var outputStreamSize: UInt32 = 0
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyDataSize(deviceID, &outputAddress, 0, nil, &outputStreamSize)
            if outputStreamSize > 0 && !deviceName.isEmpty {
                outputDevices.append(deviceName)
            }
        }

        let uniqueInput = Array(Set(inputDevices.filter { !$0.isEmpty }))
        let uniqueOutput = Array(Set(outputDevices.filter { !$0.isEmpty }))
        let newSignature = (uniqueInput.sorted() + ["|"] + uniqueOutput.sorted()).joined(separator: "\n")
        let didChange = newSignature != lastAudioDeviceSignature
        lastAudioDeviceSignature = newSignature

        availableInputDevices = ["Default"] + uniqueInput.filter { $0 != "Default" }.sorted()
        availableOutputDevices = ["Default"] + uniqueOutput.filter { $0 != "Default" }.sorted()

        if !availableInputDevices.contains(inputDevice) {
            inputDevice = "Default"
        }

        if !availableOutputDevices.contains(outputDevice) {
            outputDevice = "Default"
        }

        if didChange {
            print("[Settings] Audio device inventory changed. Inputs=\(availableInputDevices) Outputs=\(availableOutputDevices)")
            NotificationCenter.default.post(
                name: .audioDevicesChanged,
                object: nil,
                userInfo: [
                    "reason": "inventoryChanged",
                    "inputDevice": inputDevice,
                    "outputDevice": outputDevice,
                    "availableInputs": availableInputDevices,
                    "availableOutputs": availableOutputDevices
                ]
            )
        }

        if didChange && applySelectionIfNeeded && hasCompletedInitialAudioSetup {
            applySelectedAudioDevices()
        }
    }

    private func startAudioDeviceRefreshMonitoring() {
        audioDeviceRefreshTimer?.invalidate()
        audioDeviceRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.detectAudioDevices()
            }
        }
        if let audioDeviceRefreshTimer {
            RunLoop.main.add(audioDeviceRefreshTimer, forMode: .common)
        }
    }

    func applySelectedAudioDevices(notifyChange: Bool = true) {
        guard !isApplyingAudioDeviceSelection else { return }
        isApplyingAudioDeviceSelection = true
        defer { isApplyingAudioDeviceSelection = false }

        if inputDevice != "Default" {
            // Input capture now binds directly to the selected CoreAudio device.
            // Do not rewrite the macOS global default input device here.
            print("[Settings] Selected app input device retained without changing system default: \(inputDevice)")
        }

        if outputDevice != "Default" {
            let switched = setPreferredDevice(named: outputDevice, isInput: false)
            if !switched {
                print("[Settings] Failed to apply output device selection: \(outputDevice)")
            }
            let resolvedOutput = currentDefaultDeviceName(isInput: false)
            print("[Settings] Effective output device after apply: \(resolvedOutput)")
        }

        if notifyChange {
            NotificationCenter.default.post(
                name: .audioDevicesChanged,
                object: nil,
                userInfo: [
                    "reason": "selectionApplied",
                    "inputDevice": inputDevice,
                    "outputDevice": outputDevice
                ]
            )
        }
    }

    private func setPreferredDevice(named targetName: String, isInput: Bool) -> Bool {
        if setDeviceViaSwitchAudioSource(named: targetName, isInput: isInput) {
            return true
        }
        guard let deviceId = getDeviceID(named: targetName, scope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput) else {
            return false
        }
        return setSystemDefaultDevice(deviceId: deviceId, isInput: isInput)
    }

    private func setDeviceViaSwitchAudioSource(named targetName: String, isInput: Bool) -> Bool {
        let candidates = [
            "/usr/local/bin/SwitchAudioSource",
            "/opt/homebrew/bin/SwitchAudioSource"
        ]
        guard let toolPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = ["-t", isInput ? "input" : "output", "-s", targetName]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus == 0 {
                print("[Settings] Applied \(isInput ? "input" : "output") device via SwitchAudioSource: \(targetName)")
                return true
            }
            print("[Settings] SwitchAudioSource failed for \(isInput ? "input" : "output") \(targetName): \(text)")
        } catch {
            print("[Settings] SwitchAudioSource error for \(isInput ? "input" : "output") \(targetName): \(error)")
        }

        return false
    }

    @discardableResult
    private func setSystemDefaultDevice(deviceId: AudioDeviceID, isInput: Bool) -> Bool {
        var mutableDeviceId = deviceId
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            size,
            &mutableDeviceId
        )

        if status != noErr {
            print("[Settings] Failed to set \(isInput ? "input" : "output") default device. status=\(status)")
            return false
        } else {
            print("[Settings] Applied \(isInput ? "input" : "output") device selection: \(deviceId)")
            return true
        }
    }

    private func currentDefaultDeviceName(isInput: Bool) -> String {
        let selector = isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceId = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceId
        ) == noErr,
        deviceId != 0 else {
            return "Unavailable"
        }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var cfName: CFString?
        guard AudioObjectGetPropertyData(deviceId, &nameAddress, 0, nil, &nameSize, &cfName) == noErr,
              let name = cfName as String?,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Unavailable"
        }
        return name
    }

    private func getDeviceID(named targetName: String, scope: AudioObjectPropertyScope) -> AudioDeviceID? {
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        ) == noErr else {
            return nil
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        for deviceID in deviceIDs {
            var streamSize: UInt32 = 0
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr else {
                continue
            }
            if streamSize == 0 {
                continue
            }

            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: CFString?
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &cfName) == noErr else {
                continue
            }
            let deviceName = (cfName as String?) ?? ""
            if deviceName == targetName {
                return deviceID
            }
        }

        return nil
    }
}

extension Notification.Name {
    static let syncModeChanged = Notification.Name("syncModeChanged")
    static let settingsDidAutoSave = Notification.Name("settingsDidAutoSave")
    static let audioDevicesChanged = Notification.Name("audioDevicesChanged")
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = SettingsManager.shared
    @State private var selectedTab: SettingsTab = .general
    @State private var selectedProfileSubtab: ProfileSubtab = .identity
    @State private var showMastodonAuthSheet = false
    @State private var isSoundTestPlaying = false
    @State private var lastSavedAt: Date?
    private let genderOptions: [String] = [
        "Prefer not to say",
        "Male",
        "Female",
        "Non-binary",
        "Other"
    ]

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case profile = "Profile & Authentication"
        case audio = "Audio"
        case sync = "Sync & Filters"
        case fileSharing = "File Sharing"
        case notifications = "Notifications"
        case privacy = "Privacy"
        case advanced = "Advanced"
    }

    enum ProfileSubtab: String, CaseIterable, Identifiable {
        case identity = "Identity"
        case links = "Links"
        case account = "Account"
        case licensing = "Licensing"

        var id: String { rawValue }
    }

    private func closeSettings() {
        settings.saveSettings()
        appState.returnFromSettings()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    closeSettings()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.8))
                .accessibilityLabel("Back to previous screen")
                .accessibilityHint("Returns to your active room if one is open, otherwise returns to the main menu.")

                Spacer()

                VStack(spacing: 2) {
                    Text("Settings")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text(lastSavedAt.map { "Changes save automatically. Last saved \($0.formatted(date: .omitted, time: .shortened))" } ?? "Changes save automatically.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .accessibilityLabel(lastSavedAt.map { "Changes save automatically. Last saved \($0.formatted(date: .omitted, time: .shortened))" } ?? "Changes save automatically.")
                }

                Spacer()

                // Symmetry placeholder
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .opacity(0)
            }
            .padding()
            .background(Color.black.opacity(0.3))

            // Main content
            HSplitView {
                // Sidebar
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Button(action: { selectedTab = tab }) {
                            HStack {
                                Image(systemName: iconForTab(tab))
                                    .frame(width: 20)
                                Text(tab.rawValue)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selectedTab == tab ? Color.blue.opacity(0.3) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.7))
                        .accessibilityLabel(tab.rawValue)
                        .accessibilityValue(selectedTab == tab ? "Selected" : "")
                        .accessibilityHint("Opens the \(tab.rawValue) settings section.")
                    }
                    Spacer()
                }
                .frame(width: 180)
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .background(Color.black.opacity(0.2))

                // Detail panel
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch selectedTab {
                        case .general:
                            generalSettings
                        case .profile:
                            profileSettings
                        case .audio:
                            audioSettings
                        case .sync:
                            syncSettings
                        case .fileSharing:
                            fileSharingSettings
                        case .notifications:
                            notificationSettings
                        case .privacy:
                            privacySettings
                        case .advanced:
                            advancedSettings
                        }
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showMastodonAuthSheet) {
            MastodonAuthView(isPresented: $showMastodonAuthSheet) {
                syncProfileFromConnectedSources(forceNickname: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProfileSettings)) { _ in
            selectedTab = .profile
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAudioSettings)) { _ in
            selectedTab = .audio
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidAutoSave)) { notification in
            lastSavedAt = notification.userInfo?["savedAt"] as? Date ?? Date()
        }
        .background(SettingsKeyboardHandler(onClose: closeSettings))
    }

    func iconForTab(_ tab: SettingsTab) -> String {
        switch tab {
        case .general: return "gearshape"
        case .profile: return "person.circle"
        case .audio: return "speaker.wave.2"
        case .sync: return "arrow.triangle.2.circlepath"
        case .fileSharing: return "folder.badge.person.crop"
        case .notifications: return "bell"
        case .privacy: return "lock.shield"
        case .advanced: return "gear"
        }
    }

    // MARK: - General Settings
    @ViewBuilder
    var generalSettings: some View {
        SettingsSection(title: "Window Behavior") {
            VStack(alignment: .leading, spacing: 12) {
                Text("When close button is pressed")
                    .font(.caption)
                    .foregroundColor(.gray)
                Picker("Close behavior", selection: $settings.closeButtonBehavior) {
                    Text("Back to previous view, then hide").tag(SettingsManager.CloseButtonBehavior.goToMainThenHide)
                    Text("Hide to tray").tag(SettingsManager.CloseButtonBehavior.hideToTray)
                    Text("Minimize window").tag(SettingsManager.CloseButtonBehavior.minimizeWindow)
                }
                .pickerStyle(.menu)
                .onChange(of: settings.closeButtonBehavior) { _ in settings.saveSettings() }
            }
        }

        SettingsSection(title: "Startup") {
            Picker("On Launch", selection: $settings.startupBehavior) {
                Text("Open Main Window").tag(SettingsManager.StartupBehavior.openMainWindow)
                Text("Restore Current Room").tag(SettingsManager.StartupBehavior.restoreCurrentRoom)
                Text("Rejoin Last Room").tag(SettingsManager.StartupBehavior.rejoinLastRoom)
            }
            .pickerStyle(.menu)
            .onChange(of: settings.startupBehavior) { _ in settings.saveSettings() }
            .accessibilityHint("Choose whether VoiceLink opens the main window, restores the current minimized room, or rejoins the last room when the app launches.")
            Toggle("Show room descriptions in room list", isOn: $settings.showRoomDescriptions)
                .onChange(of: settings.showRoomDescriptions) { _ in settings.saveSettings() }
                .accessibilityHint("Shows or hides room description text in list and grid views.")
            Toggle("Show user statuses in room list", isOn: $settings.showUserStatusesInRoomList)
                .onChange(of: settings.showUserStatusesInRoomList) { _ in settings.saveSettings() }
                .accessibilityHint("Shows each user's attached status text after their name in room user lists.")
            Toggle("Allow my voice in room preview", isOn: $settings.allowVoiceInRoomPreview)
                .onChange(of: settings.allowVoiceInRoomPreview) { _ in settings.saveSettings() }
                .accessibilityHint("Allows your live room voice to be included in room preview when the preview voice path is enabled by the server. Preview availability itself is based on room activity or media.")
            Toggle("Play sound cues when preview starts and stops", isOn: $settings.previewSoundCuesEnabled)
                .onChange(of: settings.previewSoundCuesEnabled) { _ in settings.saveSettings() }
                .accessibilityHint("Plays the configured preview in/out sounds when toggling room preview.")
            Toggle("Play ambient background sound before joining a room", isOn: $settings.startupAmbienceEnabled)
                .onChange(of: settings.startupAmbienceEnabled) { _ in
                    settings.saveSettings()
                    AppSoundManager.shared.syncStartupAmbience(hasActiveRoom: appState.hasActiveRoom)
                }
                .accessibilityHint("Loops a low-volume ambient background sound in the main app until you join a room.")
            Picker("Default room button action", selection: $settings.defaultRoomPrimaryAction) {
                Text("Open Details").tag(SettingsManager.RoomPrimaryAction.openDetails)
                Text("Join or Show Room").tag(SettingsManager.RoomPrimaryAction.joinOrShow)
                Text("Preview Audio").tag(SettingsManager.RoomPrimaryAction.preview)
                Text("Share Room Link").tag(SettingsManager.RoomPrimaryAction.share)
            }
            .pickerStyle(.menu)
            .onChange(of: settings.defaultRoomPrimaryAction) { _ in settings.saveSettings() }
            .accessibilityHint("Sets what the focused room button does by default. Use actions menu to choose another option.")
        }

        SettingsSection(title: "Quit Behavior") {
            Toggle("Confirm before quit", isOn: $settings.confirmBeforeQuit)
                .onChange(of: settings.confirmBeforeQuit) { _ in settings.saveSettings() }
            Toggle("Confirm before deleting rooms", isOn: $settings.confirmBeforeDeletingRooms)
                .onChange(of: settings.confirmBeforeDeletingRooms) { _ in settings.saveSettings() }
                .accessibilityHint("Shows a confirmation dialog before deleting a room from server administration or room actions.")
        }
    }

    // MARK: - Profile Settings
    @ViewBuilder
    var profileSettings: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ProfileSubtab.allCases) { tab in
                    Button(tab.rawValue) {
                        selectedProfileSubtab = tab
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedProfileSubtab == tab ? .accentColor : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityValue(selectedProfileSubtab == tab ? "Selected" : "")
                }
                Spacer()
            }
            .frame(width: 120, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 20) {
                switch selectedProfileSubtab {
                case .identity:
                    profileIdentitySection
                case .links:
                    profileLinksSection
                case .account:
                    profileAccountSection
                case .licensing:
                    LicensingView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            syncProfileFromConnectedSourcesIfNeeded()
        }
    }

    @ViewBuilder
    private var profileIdentitySection: some View {
        SettingsSection(title: "User Information") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nickname")
                    .font(.caption)
                    .foregroundColor(.gray)
                TextField("Enter your nickname", text: $settings.userNickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: settings.userNickname) { _ in
                        settings.saveSettings()
                    }
                Text("This nickname will be displayed to other users in voice rooms")
                    .font(.caption)
                    .foregroundColor(.gray)

                Text("Gender")
                    .font(.caption)
                    .foregroundColor(.gray)
                Picker("Gender", selection: $settings.userGender) {
                    ForEach(genderOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: settings.userGender) { _ in
                    settings.saveSettings()
                }
                Text("This is optional and can be changed anytime.")
                    .font(.caption)
                    .foregroundColor(.gray)

                HStack(spacing: 10) {
                    Button("Sync From Connected Accounts") {
                        syncProfileFromConnectedSources(forceNickname: true)
                    }
                    .buttonStyle(.bordered)

                    if AuthenticationManager.shared.currentUser != nil {
                        Text("Uses your signed-in VoiceLink account first, then connected provider details.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
        }

        mastodonSettings
    }

    @ViewBuilder
    private var profileLinksSection: some View {
        SettingsSection(title: "Profile Links") {
            let statusManager = StatusManager.shared

            Toggle("Auto-sync links from Contact Card", isOn: Binding(
                get: { statusManager.syncWithContactCard },
                set: { newValue in
                    statusManager.setSyncWithContactCard(newValue)
                }
            ))

            HStack {
                Button("Sync Connected Accounts") {
                    syncProfileFromConnectedSources(forceNickname: false)
                }
                .buttonStyle(.bordered)

                Button("Sync Now") {
                    statusManager.syncContactCardNow()
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            if settings.userProfileLinks.isEmpty {
                Text("No profile links found yet. Sync connected accounts first, or add links to your macOS Me card and choose Sync Now.")
                    .font(.caption)
                    .foregroundColor(.gray)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(settings.userProfileLinks, id: \.self) { link in
                        HStack {
                            if let url = URL(string: link) {
                                Link(link, destination: url)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text(link)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 8)

                            Button(role: .destructive) {
                                settings.removeProfileLink(link)
                                settings.saveSettings()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove link")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var profileAccountSection: some View {
        SettingsSection(title: "Authentication") {
            let authManager = AuthenticationManager.shared
            if authManager.authState == .authenticated {
                if let user = authManager.currentUser {
                    Text("Signed in as \(user.displayName)")
                        .foregroundColor(.gray)

                    VStack(alignment: .leading, spacing: 8) {
                        accountInfoRow("Provider", value: providerDisplayName(for: user))
                        accountInfoRow("Username", value: user.username)
                        accountInfoRow("Email", value: user.email)
                        accountInfoRow("Gender", value: user.gender)
                        accountInfoRow("Role", value: effectiveRoleSummary(for: user))
                        if user.authMethod == .mastodon {
                            accountInfoRow("Instance", value: user.mastodonInstance)
                        }
                    }
                    .padding(.bottom, 4)

                    HStack(spacing: 10) {
                        Button("Sync Profile From This Account") {
                            syncProfileFromConnectedSources(forceNickname: true)
                        }
                        .buttonStyle(.bordered)

                        if user.authMethod != .mastodon {
                            Button("Connect Mastodon") {
                                showMastodonAuthSheet = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.bottom, 4)
                }
                AccountManagementPanel()
                    .environmentObject(appState)
                    .padding(.top, 6)
            } else {
                HStack(spacing: 10) {
                    Button("Mastodon") { showMastodonAuthSheet = true }
                        .buttonStyle(.borderedProminent)
                    Button("Google") {
                        if let url = URL(string: "https://voicelink.devinecreations.net/auth/google") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    Button("Apple") {
                        if let url = URL(string: "https://voicelink.devinecreations.net/auth/apple") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    Button("GitHub") {
                        if let url = URL(string: "https://voicelink.devinecreations.net/auth/github") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Text("Use any available sign-in provider. Provider support depends on server configuration.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }

    private func accountInfoRow(_ label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 82, alignment: .leading)
            Text((value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value! : "Not available"))
                .font(.caption)
                .foregroundColor(.gray)
            Spacer()
        }
    }

    private func providerDisplayName(for user: AuthenticatedUser) -> String {
        let provider = user.authProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let provider, !provider.isEmpty {
            return provider
        }
        return normalizedAuthMethod(for: user).displayName
    }

    private func effectiveRoleSummary(for user: AuthenticatedUser) -> String {
        let rawRole = user.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawRole.isEmpty {
            return rawRole
        }
        let adminRole = AdminServerManager.shared.adminRole
        switch adminRole {
        case .owner:
            return "owner"
        case .admin:
            return "admin"
        case .moderator:
            return "moderator"
        case .none:
            return AdminServerManager.shared.isAdmin ? "admin" : "user"
        }
    }

    private func normalizedAuthMethod(for user: AuthenticatedUser) -> AuthMethod {
        user.authMethod
    }

    private func syncProfileFromConnectedSourcesIfNeeded() {
        guard let user = AuthenticationManager.shared.currentUser else { return }
        let nickname = settings.userNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if nickname.isEmpty || settings.userProfileLinks.isEmpty {
            syncProfileFromConnectedSources(forceNickname: nickname.isEmpty, user: user)
        }
    }

    private func syncProfileFromConnectedSources(forceNickname: Bool, user explicitUser: AuthenticatedUser? = nil) {
        guard let user = explicitUser ?? AuthenticationManager.shared.currentUser else { return }

        if forceNickname {
            let preferredNickname = [user.displayName, user.username, user.email]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
            if let preferredNickname, !preferredNickname.isEmpty {
                settings.userNickname = preferredNickname
            }
        }

        if let remoteGender = user.gender?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteGender.isEmpty {
            settings.userGender = normalizedGenderOption(from: remoteGender)
        }

        var links: [String] = []

        if let email = user.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            links.append("mailto:\(email)")
        }

        switch user.authMethod {
        case .mastodon:
            if let instance = user.mastodonInstance?.trimmingCharacters(in: .whitespacesAndNewlines),
               !instance.isEmpty {
                let handle = user.username.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                links.append("https://\(instance)/@\(handle)")
            }
        case .whmcs:
            links.append("https://devine-creations.com/clientarea.php")
        case .email, .adminInvite:
            links.append("https://voicelink.devinecreations.net/account")
        case .pairingCode:
            break
        }

        settings.mergeProfileLinks(links)
        settings.saveSettings()
    }

    private func normalizedGenderOption(from rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "male", "man", "m":
            return "Male"
        case "female", "woman", "f":
            return "Female"
        case "non-binary", "nonbinary", "non binary", "nb":
            return "Non-binary"
        case "prefer not to say", "private", "none", "n/a", "na":
            return "Prefer not to say"
        default:
            return "Other"
        }
    }

    // MARK: - Audio Settings
    @ViewBuilder
    var audioSettings: some View {
        SettingsSection(title: "Input Device") {
            Picker("Microphone", selection: $settings.inputDevice) {
                ForEach(settings.availableInputDevices, id: \.self) { device in
                    Text(device).tag(device)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: settings.inputDevice) { _ in
                settings.saveSettings()
            }

            HStack {
                Text("Input Volume")
                Slider(value: $settings.inputVolume, in: 0...1)
                    .onChange(of: settings.inputVolume) { newValue in
                        settings.saveSettings()
                        LocalMonitorManager.shared.setInputGain(newValue)
                    }
                Text("\(Int(settings.inputVolume * 100))%")
                    .frame(width: 40)
            }
        }

        SettingsSection(title: "Current Device Status") {
            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    label: "System Input Device",
                    value: detectedDefaultInputName
                )
                statusRow(
                    label: "Selected Input Name",
                    value: settings.inputDevice
                )
                statusRow(
                    label: "Input Status",
                    value: settings.availableInputDevices.contains(settings.inputDevice) ? "Connected" : "Unavailable"
                )
                statusRow(
                    label: "Input Channels",
                    value: detectedInputChannelSummary
                )

                Divider().background(Color.white.opacity(0.15))

                statusRow(
                    label: "System Output Device",
                    value: detectedDefaultOutputName
                )
                statusRow(
                    label: "Selected Output Name",
                    value: settings.outputDevice
                )
                statusRow(
                    label: "Output Status",
                    value: settings.availableOutputDevices.contains(settings.outputDevice) ? "Connected" : "Unavailable"
                )
                statusRow(
                    label: "Output Channels",
                    value: detectedOutputChannelSummary
                )
            }
            .accessibilityElement(children: .contain)
        }

        SettingsSection(title: "Output Device") {
            Picker("Speakers/Headphones", selection: $settings.outputDevice) {
                ForEach(settings.availableOutputDevices, id: \.self) { device in
                    Text(device).tag(device)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: settings.outputDevice) { _ in
                settings.saveSettings()
            }

            HStack {
                Text("Output Volume")
                Slider(value: $settings.outputVolume, in: 0...1.5)
                    .onChange(of: settings.outputVolume) { newValue in
                        UserAudioControlManager.shared.setMasterVolume(Float(newValue))
                        settings.saveSettings()
                    }
                Text("\(Int(settings.outputVolume * 100))%")
                    .frame(width: 40)
            }

            Button(action: {
                isSoundTestPlaying = true
                AppSoundManager.shared.playSound(.soundTest, force: true)
                let resetAfter = max(0.6, AppSoundManager.shared.soundDuration(.soundTest) + 0.1)
                DispatchQueue.main.asyncAfter(deadline: .now() + resetAfter) {
                    isSoundTestPlaying = false
                }
            }) {
                Text(isSoundTestPlaying ? "Testing..." : "Test My Sound")
            }
            .buttonStyle(.bordered)
            .disabled(isSoundTestPlaying)
        }

        SettingsSection(title: "Audio Processing") {
            Toggle("Noise Suppression", isOn: $settings.noiseSuppression)
            Toggle("Echo Cancellation", isOn: $settings.echoCancellation)
            Toggle("Auto Gain Control", isOn: $settings.autoGainControl)
        }

        SettingsSection(title: "3D Spatial Audio") {
            Toggle("Enable Spatial Audio", isOn: $settings.spatialAudioEnabled)
            Toggle("Head Tracking (AirPods)", isOn: $settings.headTrackingEnabled)
                .disabled(!settings.spatialAudioEnabled)
        }

        SettingsSection(title: "Interface") {
            Toggle("Show Audio Controls on Startup", isOn: $settings.showAudioControlsOnStartup)
                .onChange(of: settings.showAudioControlsOnStartup) { _ in
                    settings.saveSettings()
                }
        }

        SettingsSection(title: "Push-to-Talk") {
            Toggle("Enable PTT Mode", isOn: $settings.pttEnabled)
            if settings.pttEnabled {
                HStack {
                    Text("PTT Key:")
                    Text(settings.pttKey)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)
                    Button("Change") {
                        // PTT key binding - would need key capture UI
                    }
                    .buttonStyle(.bordered)
                }
            }
        }

        SettingsSection(title: "Monitoring") {
            Toggle("Skip self-monitoring warning", isOn: $settings.suppressSelfMonitoringPrompt)
                .onChange(of: settings.suppressSelfMonitoringPrompt) { _ in
                    settings.saveSettings()
                }
            Text("When enabled, turning self monitoring on starts immediately without asking again. Change this here any time.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var detectedDefaultInputName: String {
        defaultDeviceName(isInput: true)
    }

    private var detectedDefaultOutputName: String {
        defaultDeviceName(isInput: false)
    }

    private var detectedInputChannelSummary: String {
        channelSummary(for: detectedDefaultInputName, isInput: true)
    }

    private var detectedOutputChannelSummary: String {
        channelSummary(for: detectedDefaultOutputName, isInput: false)
    }

    private func defaultDeviceName(isInput: Bool) -> String {
        let selector = isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else {
            return "Not detected"
        }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var cfName: CFString?
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &cfName) == noErr,
              let name = cfName as String?,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Not detected"
        }
        return name
    }

    private func channelSummary(for deviceName: String, isInput: Bool) -> String {
        guard deviceName != "Not detected",
              let deviceID = getDeviceID(named: deviceName, isInput: isInput) else {
            return "Unavailable"
        }
        let channels = getChannelCount(deviceID: deviceID, isInput: isInput)
        if channels <= 0 { return "Unavailable" }
        if channels == 1 { return "Mono (1 channel)" }
        if channels == 2 { return "Stereo (2 channels)" }
        return "Multi-channel (\(channels) channels)"
    }

    private func getDeviceID(named targetName: String, isInput: Bool) -> AudioDeviceID? {
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        ) == noErr else {
            return nil
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        let streamScope: AudioObjectPropertyScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        for deviceID in deviceIDs {
            var streamSize: UInt32 = 0
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: streamScope,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr else {
                continue
            }
            if streamSize == 0 { continue }

            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: CFString?
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &cfName) == noErr else {
                continue
            }
            if (cfName as String?) == targetName {
                return deviceID
            }
        }
        return nil
    }

    private func getChannelCount(deviceID: AudioDeviceID, isInput: Bool) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(bufferList)
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    @ViewBuilder
    private func statusRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(label):")
                .foregroundColor(.gray)
            Spacer(minLength: 10)
            Text(value)
                .foregroundColor(.white)
        }
        .font(.caption)
    }

    // MARK: - Sync Settings
    @ViewBuilder
    var syncSettings: some View {
        SettingsSection(title: "Sync Mode") {
            Text("Filter which rooms and servers are visible")
                .font(.caption)
                .foregroundColor(.gray)

            ForEach(SyncMode.allCases) { mode in
                Button(action: { settings.syncMode = mode }) {
                    HStack {
                        Image(systemName: mode.icon)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .fontWeight(settings.syncMode == mode ? .semibold : .regular)
                            Text(mode.description)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        if settings.syncMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(10)
                    .background(settings.syncMode == mode ? Color.blue.opacity(0.2) : Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
            }
        }

        SettingsSection(title: "Room Visibility") {
            Toggle("Show private rooms I'm a member of", isOn: $settings.showPrivateMemberRooms)
            Toggle("Show federated rooms", isOn: $settings.showFederatedRooms)
            Toggle("Show local-only rooms", isOn: $settings.showLocalOnlyRooms)
        }

        CustomFederationServersSection(settings: settings)
    }
}

struct CustomFederationServersSection: View {
    @ObservedObject var settings: SettingsManager
    @State private var customServerName = ""
    @State private var customServerURL = ""

    var body: some View {
        SettingsSection(title: "Custom Servers") {
            Text("Add your own linked servers here. These entries are editable from the desktop client because they are user-managed.")
                .font(.caption)
                .foregroundColor(.gray)

            HStack {
                TextField("Server name", text: $customServerName)
                    .textFieldStyle(.roundedBorder)
                TextField("https://your-server.example", text: $customServerURL)
                    .textFieldStyle(.roundedBorder)
                Button("Add Server") {
                    settings.addCustomFederationServer(name: customServerName, url: customServerURL)
                    customServerName = ""
                    customServerURL = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(customServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if settings.customFederationServers.isEmpty {
                Text("No custom servers added yet.")
                    .font(.caption)
                    .foregroundColor(.gray)
            } else {
                ForEach(settings.customFederationServers) { server in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { server.federationEnabled },
                            set: { settings.updateCustomFederationServerEnabled($0, for: server) }
                        ))
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(server.url)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        Spacer()

                        Button("Remove") {
                            settings.removeCustomFederationServer(server)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }
        }
    }
}

extension SettingsView {
    // MARK: - Notification Settings
    @ViewBuilder
    var notificationSettings: some View {
        SettingsSection(title: "Sound Notifications") {
            Toggle("Enable sound notifications", isOn: $settings.soundNotifications)
                .onChange(of: settings.soundNotifications) { _ in settings.saveSettings() }
            Toggle("Play sound when user joins", isOn: $settings.notifyOnJoin)
                .onChange(of: settings.notifyOnJoin) { _ in settings.saveSettings() }
            Toggle("Play sound when user leaves", isOn: $settings.notifyOnLeave)
                .onChange(of: settings.notifyOnLeave) { _ in settings.saveSettings() }
            Toggle("Play sound for system action notifications", isOn: $settings.systemActionNotificationSound)
                .onChange(of: settings.systemActionNotificationSound) { _ in settings.saveSettings() }
        }

        SettingsSection(title: "Maintenance and Failover Handoff") {
            Picker("When a server asks to hand off rooms or users", selection: $settings.handoffPromptMode) {
                ForEach(HandoffPromptMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Text(settings.handoffPromptMode.description)
                .font(.caption)
                .foregroundColor(.gray)
        }

        SettingsSection(title: "Desktop Notifications") {
            Toggle("Enable desktop notifications", isOn: $settings.desktopNotifications)
                .onChange(of: settings.desktopNotifications) { _ in settings.saveSettings() }
            Toggle("Enable system action push notifications", isOn: $settings.systemActionNotifications)
                .onChange(of: settings.systemActionNotifications) { _ in settings.saveSettings() }

            Button("Test Notification") {
                let notification = NSUserNotification()
                notification.title = "VoiceLink"
                notification.informativeText = "Test notification"
                NSUserNotificationCenter.default.deliver(notification)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - File Sharing Settings
    @ViewBuilder
    var fileSharingSettings: some View {
        SettingsSection(title: "Receive Mode") {
            Picker("When receiving files", selection: $settings.fileReceiveMode) {
                ForEach(FileReceiveMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
        }

        SettingsSection(title: "Auto-Receive Time Limit") {
            HStack {
                Slider(value: Binding(
                    get: { Double(settings.autoReceiveTimeLimit) },
                    set: { settings.autoReceiveTimeLimit = Int($0) }
                ), in: 0...120, step: 10)
                Text(settings.autoReceiveTimeLimit == 0 ? "Always" : "\(settings.autoReceiveTimeLimit) min")
                    .frame(width: 60)
            }
            Text("How long to auto-receive files after joining a room (0 = always)")
                .font(.caption)
                .foregroundColor(.gray)
        }

        SettingsSection(title: "Max Auto-Receive Size") {
            HStack {
                Slider(value: Binding(
                    get: { Double(settings.maxAutoReceiveSize) },
                    set: { settings.maxAutoReceiveSize = Int($0) }
                ), in: 10...1000, step: 10)
                Text("\(settings.maxAutoReceiveSize) MB")
                    .frame(width: 60)
            }
            Text("Maximum file size to auto-receive without confirmation")
                .font(.caption)
                .foregroundColor(.gray)
        }

        SettingsSection(title: "Save Location") {
            HStack {
                TextField("Save path", text: $settings.saveReceivedFilesTo)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        settings.saveReceivedFilesTo = url.path
                    }
                }
            }
        }
    }

    // MARK: - Privacy Settings
    @ViewBuilder
    var privacySettings: some View {
        SettingsSection(title: "Online Status") {
            Toggle("Show my online status to others", isOn: $settings.showOnlineStatus)
        }

        SettingsSection(title: "Direct Messages") {
            Toggle("Allow direct messages", isOn: $settings.allowDirectMessages)
        }

        SettingsSection(title: "Data") {
            Button("Clear Local Data") {
                // Clear caches
            }
            .buttonStyle(.bordered)

            Button("Export My Data") {
                // Export user data
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Mastodon Settings
    @ViewBuilder
    var mastodonSettings: some View {
        let authManager = AuthenticationManager.shared

        if authManager.authState == .authenticated {
            if let user = authManager.currentUser {
                SettingsSection(title: "Connected Account") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(user.displayName)
                                .font(.headline)
                            if let instance = user.mastodonInstance {
                                Text("@\(user.username ?? "")@\(instance)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        Spacer()
                        Button("Logout") {
                            NotificationCenter.default.post(name: .requestLogoutConfirmation, object: nil)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsSection(title: "Direct Messages") {
                Toggle("Use Mastodon for DMs with mutual followers", isOn: $settings.useMastodonForDM)
                Text("Send DMs via Mastodon when both users follow each other")
                    .font(.caption)
                    .foregroundColor(.gray)

                Toggle("Keep local copy of Mastodon DMs", isOn: $settings.storeMastodonDMsLocally)
                    .disabled(!settings.useMastodonForDM)
            }

            SettingsSection(title: "Long Messages") {
                Toggle("Auto-create threads for long messages", isOn: $settings.autoCreateThreads)
                Text("Messages over 500 characters will be split into threads")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            SettingsSection(title: "Media Storage (Coming Soon)") {
                Toggle("Use Mastodon instance for file storage", isOn: $settings.useMastodonForFileStorage)
                    .disabled(true)
                Text("Store shared media on your Mastodon instance")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        } else {
            SettingsSection(title: "Not Connected") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect your Mastodon account to enable federated features:")
                        .foregroundColor(.gray)

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Direct messages with mutual followers", systemImage: "envelope")
                        Label("Threaded conversations for long messages", systemImage: "text.bubble")
                        Label("Media storage on your instance", systemImage: "photo.on.rectangle")
                    }
                    .font(.caption)
                    .foregroundColor(.gray)

                    Button("Login with Mastodon") {
                        showMastodonAuthSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Advanced Settings
    @ViewBuilder
    var advancedSettings: some View {
        SettingsSection(title: "Diagnostics") {
            Toggle("Enable debug logging", isOn: $settings.debugLoggingEnabled)
                .onChange(of: settings.debugLoggingEnabled) { _ in settings.saveSettings() }
                .accessibilityHint("Stores more detailed client diagnostics for troubleshooting.")
            Toggle("Show connection stats", isOn: $settings.showConnectionStats)
                .onChange(of: settings.showConnectionStats) { _ in settings.saveSettings() }
                .accessibilityHint("Shows connection and transport details in status views when available.")
            Toggle("Auto-send diagnostics with bug reports", isOn: $settings.autoSendDiagnostics)
                .onChange(of: settings.autoSendDiagnostics) { _ in settings.saveSettings() }
                .accessibilityHint("Includes device and session diagnostics when you submit a bug report.")
            Toggle("Share crash reports", isOn: $settings.shareCrashReports)
                .onChange(of: settings.shareCrashReports) { _ in settings.saveSettings() }
                .accessibilityHint("Allows VoiceLink to include crash details in diagnostics reports.")

            HStack(spacing: 10) {
                Button("Send Diagnostics Report") {
                    appState.showBugReport = true
                }
                .buttonStyle(.borderedProminent)

                Button("Copy Diagnostics Summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticsSummary, forType: .string)
                }
                .buttonStyle(.bordered)
            }

            Text("Use diagnostics reporting when installs, activation, audio, or connectivity are not behaving correctly.")
                .font(.caption)
                .foregroundColor(.gray)
        }

        SettingsSection(title: "Audio Codec") {
            Picker("Codec", selection: $settings.preferredAudioCodec) {
                Text("Opus (Recommended)").tag("Opus")
                Text("PCM").tag("PCM")
            }
            .pickerStyle(.menu)
            .onChange(of: settings.preferredAudioCodec) { _ in settings.saveSettings() }
        }

        SettingsSection(title: "Network") {
            if settings.showConnectionStats {
                Text("Server URL: \(appState.serverManager.baseURL ?? "Not connected")")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("Server Status: \(appState.serverStatus == .online ? "Connected" : appState.serverStatus == .connecting ? "Connecting" : "Offline")")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("Audio Status: \(appState.serverManager.audioTransmissionStatus)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }

        SettingsSection(title: "Reset") {
            Button("Reset All Settings") {
                settings.resetToDefaults()
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
    }

    private var diagnosticsSummary: String {
        AnnouncementsManager.diagnosticsSummaryText(appState: appState, settings: settings)
    }
}

// MARK: - Settings Section
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)
        }
        .foregroundColor(.white.opacity(0.9))
    }
}

struct AccountManagementPanel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var authManager = AuthenticationManager.shared
    @ObservedObject private var licensing = LicensingManager.shared
    @ObservedObject private var adminManager = AdminServerManager.shared

    private var currentUser: AuthenticatedUser? { authManager.currentUser }

    private var canOpenServerAdministration: Bool {
        adminManager.isAdmin || adminManager.adminRole.canManageUsers || adminManager.adminRole.canManageRooms || adminManager.adminRole.canManageConfig
    }

    private var canOpenAdminDocs: Bool {
        adminManager.isAdmin || adminManager.adminRole.canManageConfig
    }

    private var effectiveRoleLabel: String {
        if let role = currentUser?.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            return role
        }

        switch adminManager.adminRole {
        case .owner:
            return "owner"
        case .admin:
            return "admin"
        case .moderator:
            return "moderator"
        case .none:
            break
        }

        if adminManager.isAdmin {
            return "admin"
        }

        return "user"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account Management")
                .font(.headline)

            if let user = currentUser {
                GroupBox("Signed-In Account") {
                    VStack(alignment: .leading, spacing: 10) {
                        accountRow("Display Name", value: user.displayName)
                        accountRow("Username", value: user.username)
                        accountRow("Email", value: user.email)
                        accountRow("Provider", value: providerDisplayName(for: user))
                        accountRow("Role", value: effectiveRoleLabel)
                        if user.authMethod == .mastodon {
                            accountRow("Instance", value: user.mastodonInstance)
                        }
                        if let key = licensing.licenseKey, !key.isEmpty {
                            accountRow("License Key", value: key)
                        }
                    }
                }

                GroupBox("Actions") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            if let destination = providerURL(for: user) {
                                Button(primaryActionTitle(for: user)) {
                                    NSWorkspace.shared.open(destination)
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if canOpenServerAdministration {
                                Button("Open Server Administration") {
                                    appState.currentScreen = .admin
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        HStack(spacing: 10) {
                            if canOpenAdminDocs {
                                Button("Open Admin Docs") {
                                    if let url = URL(string: "https://voicelink.devinecreations.net/admin/docs/") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }

                            Button("Sign Out") {
                                NotificationCenter.default.post(name: .requestLogoutConfirmation, object: nil)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } else {
                Text("No account is currently signed in.")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    private func accountRow(_ label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 96, alignment: .leading)
            Text((value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value! : "Not available"))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func providerDisplayName(for user: AuthenticatedUser) -> String {
        let provider = user.authProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let provider, !provider.isEmpty {
            return provider
        }
        return user.authMethod.displayName
    }

    private func primaryActionTitle(for user: AuthenticatedUser) -> String {
        switch user.authMethod {
        case .whmcs:
            return canOpenAdminDocs ? "Open WHMCS Admin" : "Open Client Portal"
        case .mastodon:
            return "Open Mastodon Profile"
        case .email, .adminInvite:
            return "Open VoiceLink Account"
        case .pairingCode:
            return "Open Account Page"
        }
    }

    private func providerURL(for user: AuthenticatedUser) -> URL? {
        switch user.authMethod {
        case .whmcs:
            return URL(string: canOpenAdminDocs ? "https://devine-creations.com/admin/" : "https://devine-creations.com/clientarea.php")
        case .mastodon:
            guard let instance = user.mastodonInstance?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !instance.isEmpty else { return nil }
            let handle = user.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user.username
            return URL(string: "https://\(instance)/@\(handle)")
        case .email, .adminInvite:
            return canOpenAdminDocs ? nil : URL(string: "https://voicelink.devinecreations.net/account")
        case .pairingCode:
            return URL(string: "https://voicelink.devinecreations.net/account")
        }
    }
}

private struct SettingsKeyboardHandler: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(onClose: onClose)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(onClose: onClose)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var monitor: Any?
        private var closeAction: (() -> Void)?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install(onClose: @escaping () -> Void) {
            closeAction = onClose
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {
                    self.closeAction?()
                    return nil
                }
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   event.keyCode == 13 {
                    self.closeAction?()
                    return nil
                }
                return event
            }
        }
    }
}

struct LicensingScreenView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var licensing = LicensingManager.shared
    @ObservedObject private var authManager = AuthenticationManager.shared

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Button(action: {
                    appState.currentScreen = .mainMenu
                }) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.8))

                Spacer()

                Text("License Management")
                    .font(.title2.bold())
                    .foregroundColor(.white)

                Spacer()

                // Placeholder for symmetry
                Button(action: {}) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .buttonStyle(.plain)
                .opacity(0)
            }
            .padding(.horizontal)
            .padding(.top)

            Spacer()

            LicensingView()
                .frame(maxWidth: 760)

            VStack(alignment: .leading, spacing: 12) {
                Text("What this license allows")
                    .font(.headline)
                    .foregroundColor(.white)

                HStack(spacing: 20) {
                    FeatureBadge(icon: "globe", text: "Federation")
                    FeatureBadge(icon: "server.rack", text: "Hosting")
                    FeatureBadge(icon: "person.3", text: "\(licensing.maxDevices) Devices")
                }

                if let user = authManager.currentUser {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Signed in as \(user.displayName)")
                            .foregroundColor(.white)
                        Text("Provider: \(user.authProvider?.isEmpty == false ? user.authProvider! : user.authMethod.displayName)")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("Email: \(user.email ?? "Not available")")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("Current Mac: \(licensing.currentDeviceName)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding()

            Spacer()

            // Footer with links
            HStack(spacing: 20) {
                Button("Purchase More Devices") {
                    if let url = URL(string: "https://voicelink.devinecreations.net/purchase") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)

                Button("Support") {
                    if let url = URL(string: "https://voicelink.devinecreations.net/support") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(.bottom)
        }
    }
}
