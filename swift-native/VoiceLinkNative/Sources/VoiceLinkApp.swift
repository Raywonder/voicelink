import SwiftUI
import AVFoundation
import AppKit
import SocketIO
import CoreAudio
import Combine

@main
struct VoiceLinkApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var localDiscovery = LocalServerDiscovery.shared
    @StateObject private var adminManager = AdminServerManager.shared
    @State private var showUpdaterSheet = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(localDiscovery)
                .frame(minWidth: 900, minHeight: 700)
                .frame(width: 1000, height: 750)
                .sheet(isPresented: $appState.showAnnouncements) {
                    AnnouncementsView()
                }
                .sheet(isPresented: $appState.showBugReport) {
                    BugReportView()
                }
                .sheet(isPresented: $showUpdaterSheet) {
                    UpdateSettingsView()
                        .frame(minWidth: 520, minHeight: 380)
                }
                .onReceive(NotificationCenter.default.publisher(for: .updateAvailable)) { _ in
                    showUpdaterSheet = true
                }
                .onAppear {
                    AppDelegate.shared?.appState = appState
                }
        }
        .defaultSize(width: 1000, height: 750)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appState.currentScreen = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Export User Data") {
                    appState.exportUserDataSnapshot()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Export Room Snapshot") {
                    appState.exportRoomSnapshot()
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    showUpdaterSheet = true
                    AutoUpdater.shared.checkForUpdates(silent: false)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandMenu("Room") {
                Button("Create Room") {
                    appState.currentScreen = .createRoom
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Join or Search for Room...") {
                    appState.openJoinRoomPanel()
                }
                .keyboardShortcut("j", modifiers: .command)

                Button(appState.quickJoinCommandTitle) {
                    appState.handleCommandShiftJ()
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])

                Menu("Filter") {
                    Menu("Sync") {
                        ForEach(SyncMode.allCases) { mode in
                            Button(action: { SettingsManager.shared.syncMode = mode }) {
                                HStack {
                                    if SettingsManager.shared.syncMode == mode {
                                        Image(systemName: "checkmark")
                                    }
                                    Image(systemName: mode.icon)
                                    Text(mode.displayName)
                                }
                            }
                        }
                    }

                    Divider()

                    Button("Reset Filters") {
                        NotificationCenter.default.post(name: .roomFilterReset, object: nil)
                    }
                    .keyboardShortcut("0", modifiers: [.command, .option])

                    Divider()

                    Menu("Scope") {
                        Button("All Rooms") {
                            NotificationCenter.default.post(name: .roomFilterScopeChanged, object: nil, userInfo: ["scope": "all"])
                        }
                        .keyboardShortcut("1", modifiers: [.command, .option])

                        Button("Public") {
                            NotificationCenter.default.post(name: .roomFilterScopeChanged, object: nil, userInfo: ["scope": "public"])
                        }
                        .keyboardShortcut("2", modifiers: [.command, .option])

                        Button("Private") {
                            NotificationCenter.default.post(name: .roomFilterScopeChanged, object: nil, userInfo: ["scope": "private"])
                        }
                        .keyboardShortcut("3", modifiers: [.command, .option])

                        Button("Active Users") {
                            NotificationCenter.default.post(name: .roomFilterScopeChanged, object: nil, userInfo: ["scope": "active"])
                        }
                        .keyboardShortcut("4", modifiers: [.command, .option])

                        Button("Media Active") {
                            NotificationCenter.default.post(name: .roomFilterScopeChanged, object: nil, userInfo: ["scope": "media"])
                        }
                        .keyboardShortcut("5", modifiers: [.command, .option])
                    }

                    Menu("Sort") {
                        Button("Active First") {
                            NotificationCenter.default.post(name: .roomFilterSortChanged, object: nil, userInfo: ["sort": "active"])
                        }
                        .keyboardShortcut("6", modifiers: [.command, .option])

                        Button("Most Members") {
                            NotificationCenter.default.post(name: .roomFilterSortChanged, object: nil, userInfo: ["sort": "members"])
                        }
                        .keyboardShortcut("7", modifiers: [.command, .option])

                        Button("Alphabetical A to Z") {
                            NotificationCenter.default.post(name: .roomFilterSortChanged, object: nil, userInfo: ["sort": "az"])
                        }

                        Button("Alphabetical Z to A") {
                            NotificationCenter.default.post(name: .roomFilterSortChanged, object: nil, userInfo: ["sort": "za"])
                        }
                    }

                    Menu("View") {
                        Button("List") {
                            NotificationCenter.default.post(name: .roomFilterLayoutChanged, object: nil, userInfo: ["layout": "list"])
                        }
                        .keyboardShortcut("8", modifiers: [.command, .option])

                        Button("Grid") {
                            NotificationCenter.default.post(name: .roomFilterLayoutChanged, object: nil, userInfo: ["layout": "grid"])
                        }
                        .keyboardShortcut("9", modifiers: [.command, .option])
                    }

                }

                if let lastRoom = appState.recentRooms.first {
                    Button("Rejoin Last Room: \(lastRoom.name)") {
                        _ = appState.rejoinLastRoom()
                    }
                    .disabled(appState.currentRoom != nil)
                }

                Divider()

                Button("Show Room") {
                    appState.restoreMinimizedRoom()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!appState.hasMinimizedRoom)

                Button("Minimize Room") {
                    appState.minimizeCurrentRoom()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(!appState.hasActiveRoom)

                Button("Leave Room") {
                    appState.leaveCurrentRoom()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!appState.hasActiveRoom)

                Button("File Transfer Details") {
                    NotificationCenter.default.post(name: .openFileTransfers, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .option, .shift])
            }
            CommandMenu("Audio") {
                let settings = SettingsManager.shared

                Button("Toggle Mute") {
                    NotificationCenter.default.post(name: .toggleMute, object: nil)
                }
                .keyboardShortcut("m", modifiers: .command)

                Button("Toggle Output Mute") {
                    NotificationCenter.default.post(name: .toggleDeafen, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button(settings.noiseSuppression ? "Disable Noise Suppression" : "Enable Noise Suppression") {
                    settings.noiseSuppression.toggle()
                    settings.saveSettings()
                }

                Button(settings.echoCancellation ? "Disable Echo Cancellation" : "Enable Echo Cancellation") {
                    settings.echoCancellation.toggle()
                    settings.saveSettings()
                }

                Button(settings.autoGainControl ? "Disable Auto Gain Control" : "Enable Auto Gain Control") {
                    settings.autoGainControl.toggle()
                    settings.saveSettings()
                }

                Button(settings.spatialAudioEnabled ? "Disable Spatial Audio" : "Enable Spatial Audio") {
                    settings.spatialAudioEnabled.toggle()
                    settings.saveSettings()
                }

                Divider()

                Menu("Input Device") {
                    ForEach(settings.availableInputDevices, id: \.self) { device in
                        Button(device) {
                            settings.inputDevice = device
                            settings.saveSettings()
                        }
                    }
                }

                Menu("Output Device") {
                    ForEach(settings.availableOutputDevices, id: \.self) { device in
                        Button(device) {
                            settings.outputDevice = device
                            settings.saveSettings()
                        }
                    }
                }

                Button("Refresh Audio Devices") {
                    settings.detectAudioDevices()
                }

                Button("Test Sound") {
                    AppSoundManager.shared.playSound(.soundTest, force: true)
                }

                Divider()

                Button("Audio Settings...") {
                    appState.currentScreen = .settings
                    NotificationCenter.default.post(name: .openAudioSettings, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
            }

            CommandMenu("Account") {
                let authManager = AuthenticationManager.shared
                let statusManager = StatusManager.shared
                let settings = SettingsManager.shared

                if authManager.authState == .authenticated {
                    if let user = authManager.currentUser {
                        if let instance = user.mastodonInstance {
                            Text("You are logged in as \(user.username)@\(instance)")
                        } else {
                            Text("Logged in as: \(user.displayName)")
                        }
                    }

                    Divider()

                    Button("Logout") {
                        authManager.logout()
                    }
                    .keyboardShortcut("q", modifiers: [.command, .shift])
                } else {
                    Button("Login with Mastodon") {
                        appState.currentScreen = .login
                    }
                    .keyboardShortcut("l", modifiers: .command)
                    Button("Sign In with Google") {
                        if let url = URL(string: "https://voicelink.devinecreations.net/auth/google") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Sign In with Apple") {
                        if let url = URL(string: "https://voicelink.devinecreations.net/auth/apple") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Sign In with GitHub") {
                        if let url = URL(string: "https://voicelink.devinecreations.net/auth/github") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Divider()

                Menu("Status") {
                    ForEach(StatusManager.UserStatus.allCases.filter { $0 != .custom }, id: \.rawValue) { status in
                        Button {
                            statusManager.setStatus(status)
                        } label: {
                            Label(status.displayName, systemImage: statusManager.currentStatus == status ? "checkmark.circle.fill" : status.icon)
                        }
                    }

                    Divider()

                    Toggle("Sync with macOS Focus modes", isOn: Binding(
                        get: { statusManager.syncWithSystemFocus },
                        set: { newValue in
                            statusManager.setSyncWithSystemFocus(newValue)
                        }
                    ))

                    Toggle("Sync profile from Contact Card", isOn: Binding(
                        get: { statusManager.syncWithContactCard },
                        set: { newValue in
                            statusManager.setSyncWithContactCard(newValue)
                        }
                    ))
                }

                Button("Set Nickname...") {
                    appState.currentScreen = .settings
                    NotificationCenter.default.post(name: .openProfileSettings, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                if adminManager.isAdmin || adminManager.adminRole == .admin || adminManager.adminRole == .owner {
                    Divider()
                    Menu("Admin Modes") {
                        Button(settings.adminGodModeEnabled ? "Disable God Mode" : "Enable God Mode") {
                            settings.adminGodModeEnabled.toggle()
                            settings.saveSettings()
                        }
                        Button(settings.adminInvisibleMode ? "Disable Invisible Mode" : "Enable Invisible Mode") {
                            settings.adminInvisibleMode.toggle()
                            if settings.adminInvisibleMode {
                                statusManager.goInvisible()
                            } else if statusManager.currentStatus == .invisible {
                                statusManager.goOnline()
                            }
                            settings.saveSettings()
                        }
                    }

                    Button("Server Administration...") {
                        appState.currentScreen = .admin
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .help("Manage remote server settings (admin only)")
                }
            }

            CommandMenu("License") {
                let licensing = LicensingManager.shared
                Button("View License") {
                    appState.currentScreen = .licensing
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                if licensing.licenseStatus == .licensed {
                    Text("Status: Licensed")
                    Text("Devices: \(licensing.activatedDevices)/\(licensing.maxDevices)")
                    if let key = licensing.licenseKey, !key.isEmpty {
                        Text("Key: \(key)")
                    }
                } else if licensing.licenseStatus == .deviceLimitReached {
                    Text(licensing.activationRequired ? "Status: Activation Required" : "Status: Device Limit Reached")
                    Text("Devices: \(licensing.activatedDevices)/\(licensing.maxDevices)")
                    if let key = licensing.licenseKey, !key.isEmpty {
                        Text("Key: \(key)")
                    }
                    if let email = licensing.primaryEmail, !email.isEmpty {
                        Text("Account: \(email)")
                    }
                } else if licensing.licenseStatus == .pending {
                    Text("Status: Pending (\(licensing.remainingMinutes) min)")
                    if let key = licensing.licenseKey, !key.isEmpty {
                        Text("Key: \(key)")
                    }
                } else {
                    if let key = licensing.licenseKey, !key.isEmpty {
                        Text("Status: License Assigned")
                        Text("Key: \(key)")
                    } else {
                        Text("Status: Not Registered")
                    }
                }

                Divider()

                if licensing.currentMachineNeedsActivation && licensing.remainingSlots > 0 {
                    Button("Activate This Device") {
                        Task {
                            _ = await licensing.activateDevice()
                        }
                    }
                }
            }

            CommandMenu("Servers") {
                Button("My Linked Servers...") {
                    appState.currentScreen = .servers
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("View and manage servers you've linked to this device")

                // Local server discovery - requires license
                if LicensingManager.shared.licenseStatus == .licensed {
                    Divider()

                    Button("Discover Local Servers") {
                        localDiscovery.scanForLocalServer()
                    }
                    .help("Scan local network for VoiceLink servers")
                    .disabled(localDiscovery.isScanning)

                    if localDiscovery.localServerFound {
                        Button("Connect to \(localDiscovery.localServerName ?? "Local Server")") {
                            if let _ = localDiscovery.localServerURL {
                                localDiscovery.autoPairWithLocalServer { _ in }
                            }
                        }
                    }
                }

            }

            CommandMenu("Help") {
                Button("What's New...") {
                    appState.showAnnouncements = true
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
                .help("View latest announcements and release notes")

                Button("Report a Bug...") {
                    appState.showBugReport = true
                }
                .help("Submit a bug report")

                Divider()

                Button("Open Bug Tracker") {
                    AnnouncementsManager.shared.openBugTracker()
                }
                .help("View and track reported issues")

                Button("View Announcements Online") {
                    AnnouncementsManager.shared.openAnnouncementsInBrowser()
                }
                .help("View announcements in web browser")

                Divider()

                Button("VoiceLink Help") {
                    if let url = URL(string: "https://voicelink.devinecreations.net/docs/index.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .help("Open VoiceLink documentation")
            }
        }
    }
}

extension Notification.Name {
    static let toggleMute = Notification.Name("toggleMute")
    static let toggleDeafen = Notification.Name("toggleDeafen")
    static let roomJoined = Notification.Name("roomJoined")
    static let pairingSuccess = Notification.Name("pairingSuccess")
    static let discoverServers = Notification.Name("discoverServers")
    static let goToMainMenu = Notification.Name("goToMainMenu")
    static let openProfileSettings = Notification.Name("openProfileSettings")
    static let openAudioSettings = Notification.Name("openAudioSettings")
    static let roomActionMinimize = Notification.Name("roomActionMinimize")
    static let roomActionRestore = Notification.Name("roomActionRestore")
    static let roomActionLeave = Notification.Name("roomActionLeave")
    static let roomActionJoin = Notification.Name("roomActionJoin")
    static let roomActionOpenSettings = Notification.Name("roomActionOpenSettings")
    static let reopenRoomDetailsSheet = Notification.Name("reopenRoomDetailsSheet")
    static let roomActionCreate = Notification.Name("roomActionCreate")
    static let roomActionDelete = Notification.Name("roomActionDelete")
    static let mainWindowCloseRequested = Notification.Name("mainWindowCloseRequested")
    static let openRoomJukebox = Notification.Name("openRoomJukebox")
    static let openFileTransfers = Notification.Name("openFileTransfers")
    static let openDirectMessage = Notification.Name("openDirectMessage")
    static let roomFilterReset = Notification.Name("roomFilterReset")
    static let roomFilterScopeChanged = Notification.Name("roomFilterScopeChanged")
    static let roomFilterSortChanged = Notification.Name("roomFilterSortChanged")
    static let roomFilterLayoutChanged = Notification.Name("roomFilterLayoutChanged")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    static var shared: AppDelegate?
    weak var appState: AppState?
    private let windowController = MainWindowController()
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test-sound-download") {
            Task { @MainActor in
                let passed = await AppSoundManager.shared.runMissingSoundDownloadSelfTest()
                print("SOUND_DOWNLOAD_SELF_TEST: \(passed ? "PASS" : "FAIL")")
                NSApplication.shared.terminate(nil)
            }
            return
        }

        AppDelegate.shared = self

        // Initialize menubar status item
        statusBarController = StatusBarController()

        // Register for URL events
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Auto-connect to server on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.autoConnectOnLaunch()
        }

        // Show window on launch based on user preference.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.configureMainWindowIfNeeded()
            switch SettingsManager.shared.startupBehavior {
            case .openMainWindow:
                self.showMainWindow()
            case .restoreCurrentRoom:
                if self.appState?.hasMinimizedRoom == true {
                    self.appState?.restoreMinimizedRoom()
                    self.showMainWindow()
                } else {
                    self.showMainWindow()
                }
            case .rejoinLastRoom:
                if self.appState?.hasMinimizedRoom == true {
                    self.appState?.restoreMinimizedRoom()
                    self.showMainWindow()
                } else if self.appState?.rejoinLastRoom() == true {
                    self.showMainWindow()
                } else {
                    self.showMainWindow()
                }
            }
            if SettingsManager.shared.startupBehavior == .restoreCurrentRoom && self.appState?.hasActiveRoom != true {
                self.hideMainWindow()
            }
        }

        // Play startup welcome cue; retry once in case launch timing delays audio readiness.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            AppSoundManager.shared.playStartupWelcomeIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            AppSoundManager.shared.playStartupWelcomeIfNeeded()
        }
    }

    func autoConnectOnLaunch() {
        let serverManager = ServerManager.shared

        // Check if already connected
        if serverManager.isConnected {
            print("[AppDelegate] Already connected to server")
            return
        }

        // Check saved server preference
        let savedServer = UserDefaults.standard.string(forKey: "lastConnectedServer") ?? "main"

        print("[AppDelegate] Auto-connecting to server: \(savedServer)")

        if savedServer == "local" {
            serverManager.connectToLocalServer()
        } else if savedServer.hasPrefix("http") {
            serverManager.connectToURL(savedServer)
        } else {
            // Default: try main server first, fallback to local
            serverManager.tryMainThenLocal()
        }

        // Set up auto-reconnect observer
        setupAutoReconnect()
    }

    func setupAutoReconnect() {
        NotificationCenter.default.addObserver(
            forName: .serverConnectionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let serverManager = ServerManager.shared
            let settings = SettingsManager.shared

            // Auto-reconnect if enabled and disconnected
            if !serverManager.isConnected && settings.reconnectOnDisconnect {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if !serverManager.isConnected {
                        print("[AppDelegate] Auto-reconnecting...")
                        serverManager.tryMainThenLocal()
                    }
                }
            }
        }
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }

        print("[AppDelegate] Received URL: \(url)")

        // Show app window and handle URL
        showMainWindow()

        Task { @MainActor in
            URLHandler.shared.handleURL(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Never quit when window closes - stay in menubar
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let settings = SettingsManager.shared
        if settings.confirmBeforeQuit {
            let alert = NSAlert()
            alert.messageText = "Quit VoiceLink?"
            alert.informativeText = "VoiceLink will fully quit even if you are in a room."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            if let suppressionButton = alert.suppressionButton {
                suppressionButton.title = "Never ask again"
                suppressionButton.setAccessibilityLabel("Never ask again")
            }

            let result = alert.runModal()
            if result == .alertFirstButtonReturn,
               alert.suppressionButton?.state == .on {
                settings.confirmBeforeQuit = false
                settings.saveSettings()
            }
            return result == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Disconnect from server on quit
        ServerManager.shared.disconnect()
        LocalServerDiscovery.shared.stopScanning()
    }

    func showMainWindow() {
        configureMainWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow ?? NSApp.windows.first(where: { $0.title.contains("VoiceLink") || $0.contentView != nil }) {
            window.makeKeyAndOrderFront(nil)
            window.center()
            mainWindow = window
        }
    }

    func hideMainWindow() {
        if let window = mainWindow ?? NSApp.windows.first(where: { $0.title.contains("VoiceLink") || $0.contentView != nil }) {
            window.orderOut(nil)
            return
        }
        NSApp.hide(nil)
    }

    func minimizeMainWindow() {
        if let window = mainWindow ?? NSApp.windows.first(where: { $0.title.contains("VoiceLink") || $0.contentView != nil }) {
            window.miniaturize(nil)
        } else {
            NSApp.hide(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    private func configureMainWindowIfNeeded() {
        if let existing = mainWindow {
            existing.delegate = windowController
            return
        }
        if let window = NSApp.windows.first(where: {
            $0.contentViewController != nil && $0.styleMask.contains(.closable) && $0.styleMask.contains(.titled)
        }) {
            mainWindow = window
            window.delegate = windowController
        }
    }
}

final class MainWindowController: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NotificationCenter.default.post(name: .mainWindowCloseRequested, object: nil)
        return false
    }
}

// MARK: - App State
@MainActor
class AppState: ObservableObject {
    struct RecentRoomEntry: Codable, Identifiable, Equatable {
        let id: String
        let name: String
        let description: String
        let serverURL: String
        let hostServerName: String?
        let recordedAt: Date
    }

    struct PendingRoomDraft: Equatable {
        var name: String
        var description: String
        var isPrivate: Bool
        var roomType: String
        var maxUsers: Int
        var inviteOnly: Bool
        var hostingPreference: RoomHostingPreference
    }

    struct HandoffOffer: Identifiable, Equatable {
        let id: String
        let targetServerURL: String
        let room: Room?
        let effectiveMode: HandoffPromptMode
        let sourceServerURL: String

        var targetHostLabel: String {
            URL(string: targetServerURL)?.host ?? targetServerURL
        }
    }

    enum HandoffDecision: String {
        case accept
        case decline
    }

    @Published var currentScreen: Screen = .mainMenu {
        didSet {
            if currentScreen != oldValue {
                previousScreen = oldValue
            }
        }
    }
    @Published var isConnected: Bool = false
    @Published var currentRoom: Room?
    @Published var rooms: [Room] = []
    @Published var localIP: String = "Detecting..."
    @Published var serverStatus: ServerStatus = .offline
    @Published var username: String = "User\(Int.random(in: 1000...9999))"
    @Published var errorMessage: String?
    @Published var showAnnouncements: Bool = false
    @Published var showBugReport: Bool = false
    @Published var minimizedRoom: Room?
    @Published var focusedRoomId: String?
    @Published var pendingCreateRoomName: String = ""
    @Published var roomHasActiveMusic: [String: Bool] = [:]
    @Published var pendingJoinRoomId: String?
    @Published var roomToRestoreAfterAdminClose: Room?
    @Published var recentRooms: [RecentRoomEntry] = []
    @Published var pendingRoomDraft: PendingRoomDraft?
    @Published var activeHandoffOffer: HandoffOffer?
    private var previousScreen: Screen = .mainMenu
    private let recentRoomsKey = "voicelink.recentRooms"
    private let maxRecentRooms = 10
    private let handoffSavedDecisionKey = "voicelink.handoffSavedDecision"
    private var lastHandoffOfferId: String?
    private var pendingHandoffRoom: Room?
    private var pendingHandoffTargetURL: String?

    let serverManager = ServerManager.shared
    let licensing = LicensingManager.shared
    private var cancellables: Set<AnyCancellable> = []

    enum Screen {
        case mainMenu
        case createRoom
        case joinRoom
        case voiceChat
        case settings
        case servers
        case licensing
        case admin
        case login
    }

    enum ServerStatus {
        case online, offline, connecting
    }

    var activeRoomId: String? {
        currentRoom?.id ?? minimizedRoom?.id
    }

    var hasActiveRoom: Bool {
        activeRoomId != nil
    }

    var hasMinimizedRoom: Bool {
        minimizedRoom != nil
    }

    func returnFromSettings() {
        if currentRoom != nil || minimizedRoom != nil {
            currentScreen = .voiceChat
        } else {
            currentScreen = .mainMenu
        }
    }

    var quickJoinCommandTitle: String {
        if currentRoom != nil {
            return "Minimize Current Room"
        }
        if minimizedRoom != nil {
            return "Show Current Room"
        }
        if recentRooms.first != nil {
            return "Rejoin Last Room"
        }
        return "Join Focused Room"
    }

    init() {
        loadRecentRooms()
        detectLocalIP()
        setupServerObservers()
        setupRoomActionObservers()
        setupWindowBehaviorObservers()
        setupAdminObservers()
        initializeLicensing()
        setupLicensingObservers()
        setupURLObservers()
        setupHandoffObservers()
        refreshAdminCapabilities()
    }

    private func setupLicensingObservers() {
        NotificationCenter.default.addObserver(forName: .licenseNoticeReceived, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            let title = notification.userInfo?["title"] as? String ?? "License Update"
            let message = notification.userInfo?["message"] as? String ?? "Your VoiceLink license state changed."
            self.errorMessage = "\(title): \(message)"
            AccessibilityManager.shared.announceStatus(message)
        }
    }

    private func setupURLObservers() {
        // Handle URL join room
        NotificationCenter.default.addObserver(forName: .urlJoinRoom, object: nil, queue: .main) { [weak self] notification in
            guard let data = notification.object as? [String: Any],
                  let roomId = data["roomId"] as? String else { return }

            let server = data["server"] as? String
            self?.handleURLJoinRoom(roomId: roomId, server: server)
        }

        // Handle URL view room
        NotificationCenter.default.addObserver(forName: .urlViewRoom, object: nil, queue: .main) { [weak self] notification in
            guard let data = notification.object as? [String: Any],
                  let roomId = data["roomId"] as? String else { return }

            self?.handleURLViewRoom(roomId: roomId)
        }

        // Handle URL connect server
        NotificationCenter.default.addObserver(forName: .urlConnectServer, object: nil, queue: .main) { [weak self] notification in
            guard let data = notification.object as? [String: Any],
                  let serverUrl = data["serverUrl"] as? String else { return }

            self?.handleURLConnectServer(serverUrl: serverUrl)
        }

        // Handle URL invite
        NotificationCenter.default.addObserver(forName: .urlUseInvite, object: nil, queue: .main) { [weak self] notification in
            guard let data = notification.object as? [String: Any],
                  let code = data["code"] as? String else { return }

            self?.handleURLInvite(code: code)
        }
        NotificationCenter.default.addObserver(forName: .urlAdminInvite, object: nil, queue: .main) { [weak self] notification in
            guard let data = notification.object as? [String: Any],
                  let token = data["token"] as? String else { return }
            let server = data["server"] as? String
            self?.handleURLAdminInvite(token: token, server: server)
        }

        // Handle URL open settings
        NotificationCenter.default.addObserver(forName: .urlOpenSettings, object: nil, queue: .main) { [weak self] _ in
            self?.currentScreen = .settings
        }

        // Handle URL open license
        NotificationCenter.default.addObserver(forName: .urlOpenLicense, object: nil, queue: .main) { [weak self] _ in
            self?.currentScreen = .licensing
        }
    }

    private func handleURLJoinRoom(roomId: String, server: String?) {
        print("[AppState] Joining room from URL: \(roomId)")

        // Connect to specified server if provided, otherwise use current
        if let server = server, !server.isEmpty {
            // Custom server URL provided
            serverManager.connectToURL(server)
        }

        if let room = rooms.first(where: { $0.id == roomId }) {
            joinOrShowRoom(room)
        } else {
            // Join unknown room ID directly
            if let existingRoomId = activeRoomId, existingRoomId != roomId {
                let fromName = currentRoom?.name ?? minimizedRoom?.name ?? "current room"
                errorMessage = "Leaving \(fromName) and joining room \(roomId)."
                AccessibilityManager.shared.announceStatus("Leaving \(fromName) and joining room \(roomId).")
                serverManager.leaveRoom()
                currentRoom = nil
                minimizedRoom = nil
            }
            if activeRoomId == roomId {
                currentScreen = .voiceChat
                return
            }
            let joinName = preferredDisplayName()
            username = joinName
            pendingJoinRoomId = roomId
            errorMessage = "Joining room \(roomId)..."
            serverManager.joinRoom(roomId: roomId, username: joinName)
        }
    }

    private func handleURLViewRoom(roomId: String) {
        print("[AppState] Viewing room from URL: \(roomId)")
        // Show room details/preview - find in rooms list
        if let room = rooms.first(where: { $0.id == roomId }) {
            currentRoom = room
            // Stay on main menu to show preview
        }
    }

    private func handleURLConnectServer(serverUrl: String) {
        print("[AppState] Connecting to server from URL: \(serverUrl)")
        serverManager.connectToURL(serverUrl)
    }

    private func handleURLInvite(code: String) {
        print("[AppState] Using invite code from URL: \(code)")
        // Treat invite code as room ID for now
        if let room = rooms.first(where: { $0.id == code }) {
            joinOrShowRoom(room)
        } else {
            if let existingRoomId = activeRoomId, existingRoomId != code {
                let fromName = currentRoom?.name ?? minimizedRoom?.name ?? "current room"
                errorMessage = "Leaving \(fromName) and joining room \(code)."
                AccessibilityManager.shared.announceStatus("Leaving \(fromName) and joining room \(code).")
                serverManager.leaveRoom()
                currentRoom = nil
                minimizedRoom = nil
            }
            if activeRoomId == code {
                currentScreen = .voiceChat
                return
            }
            let joinName = preferredDisplayName()
            username = joinName
            pendingJoinRoomId = code
            errorMessage = "Joining room \(code)..."
            serverManager.joinRoom(roomId: code, username: joinName)
        }
    }

    private func handleURLAdminInvite(token: String, server: String?) {
        if let current = AuthenticationManager.shared.currentUser {
            currentScreen = .mainMenu
            errorMessage = "Admin invite received, but you are already signed in as \(current.displayName). Sign out first, then open the invite link again."
            AccessibilityManager.shared.announceStatus("Admin invite blocked while another account is signed in. Please sign out and retry.")
            return
        }
        let normalizedServer: String? = {
            guard let server, !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return server
        }()
        AuthenticationManager.shared.stageAdminInvite(token: token, serverURL: normalizedServer)
        currentScreen = .servers
        errorMessage = "Admin invite link received. Opening account activation form."
        AccessibilityManager.shared.announceStatus("Admin invite link received. Opening account activation form.")
    }

    private func initializeLicensing() {
        // Check existing license or start registration
        Task { @MainActor in
            if licensing.licenseKey != nil {
                await licensing.validateLicense()
            } else {
                // Auto-register with generated IDs
                let serverId = "vl_\(getDeviceIdentifier())"
                let nodeId = "node_\(UUID().uuidString.prefix(8))"
                await licensing.registerNode(serverId: serverId, nodeId: nodeId)
            }
        }
    }

    private func getDeviceIdentifier() -> String {
        // Use a persistent identifier for this device
        if let existing = UserDefaults.standard.string(forKey: "device_identifier") {
            return existing
        }
        let newId = UUID().uuidString.prefix(12).description
        UserDefaults.standard.set(newId, forKey: "device_identifier")
        return newId
    }

    func connectToServer() {
        serverStatus = .connecting
        serverManager.tryLocalThenMain()
    }

    func connectToMainServer() {
        serverStatus = .connecting
        serverManager.connectToMainServer()
    }

    func connectToLocalServer() {
        serverStatus = .connecting
        serverManager.connectToLocalServer()
    }

    private func setupServerObservers() {
        // Observe server connection status
        serverManager.$isConnected
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .assign(to: &$isConnected)

        // Observe server status
        serverManager.$serverStatus
            .receive(on: DispatchQueue.main)
            .map { status -> ServerStatus in
                switch status {
                case "Connected": return .online
                case "Reconnecting...": return .connecting
                default: return .offline
                }
            }
            .removeDuplicates()
            .assign(to: &$serverStatus)

        // Observe rooms from server
        serverManager.$rooms
            .receive(on: DispatchQueue.main)
            .map { [weak self] serverRooms in
                let fallbackHost = self?.serverManager.connectedServer.trimmingCharacters(in: .whitespacesAndNewlines)
                return serverRooms.map { room in
                    let mapped = Room(from: room)
                    if mapped.hostServerName == nil || mapped.hostServerName?.isEmpty == true {
                        return Room(
                            id: mapped.id,
                            name: mapped.name,
                            description: mapped.description,
                            userCount: mapped.userCount,
                            isPrivate: mapped.isPrivate,
                            maxUsers: mapped.maxUsers,
                            createdBy: mapped.createdBy,
                            createdByRole: mapped.createdByRole,
                            roomType: mapped.roomType,
                            createdAt: mapped.createdAt,
                            uptimeSeconds: mapped.uptimeSeconds,
                            lastActiveUsername: mapped.lastActiveUsername,
                            lastActivityAt: mapped.lastActivityAt,
                            hostServerName: (fallbackHost?.isEmpty == false ? fallbackHost : nil),
                            hostServerOwner: mapped.hostServerOwner
                        )
                    }
                    return mapped
                }
            }
            .removeDuplicates()
            .sink { [weak self] mappedRooms in
                self?.rooms = mappedRooms
                self?.refreshRoomMediaStatuses(for: mappedRooms)
                self?.attemptPendingHandoffJoin()
            }
            .store(in: &cancellables)

        // Observe errors
        serverManager.$errorMessage
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .assign(to: &$errorMessage)

        // Fallback join completion path: some server variants only update activeRoomId.
        serverManager.$activeRoomId
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] activeRoomId in
                guard let self else { return }
                guard let activeRoomId else { return }
                guard self.pendingJoinRoomId == activeRoomId else { return }

                if let room = self.rooms.first(where: { $0.id == activeRoomId }) {
                    self.currentRoom = room
                } else {
                    let now = Date()
                    self.currentRoom = Room(
                        id: activeRoomId,
                        name: "Room \(activeRoomId)",
                        description: "",
                        userCount: 1,
                        isPrivate: false,
                        maxUsers: 50,
                        createdAt: now,
                        lastActivityAt: now
                    )
                }
                self.minimizedRoom = nil
                self.currentScreen = .voiceChat
                self.pendingJoinRoomId = nil
                self.errorMessage = "Joined \(self.currentRoom?.name ?? "room")."
                if let room = self.currentRoom {
                    self.rememberJoinedRoom(room)
                }
                self.scheduleRoomMediaRefresh()
            }
            .store(in: &cancellables)

        // Keep admin capabilities in sync with active server connection.
        serverManager.$isConnected
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshAdminCapabilities()
                self?.attemptPendingHandoffJoin()
            }
            .store(in: &cancellables)

        // Listen for room joined notification
        NotificationCenter.default.addObserver(forName: .roomJoined, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            guard let roomData = notification.object as? [String: Any] else { return }
            let roomId = roomData["roomId"] as? String ?? roomData["id"] as? String ?? self.pendingJoinRoomId
            guard let roomId else { return }

            let joinedRoom: Room = {
                if let existing = self.rooms.first(where: { $0.id == roomId }) {
                    return Room(
                        id: existing.id,
                        name: existing.name,
                        description: existing.description,
                        userCount: max(existing.userCount, self.serverManager.currentRoomUsers.filter { !$0.isBot }.count),
                        isPrivate: existing.isPrivate,
                        maxUsers: existing.maxUsers,
                        createdBy: existing.createdBy,
                        createdByRole: existing.createdByRole,
                        roomType: existing.roomType,
                        createdAt: existing.createdAt ?? Date(),
                        uptimeSeconds: existing.uptimeSeconds,
                        lastActiveUsername: existing.lastActiveUsername,
                        lastActivityAt: Date(),
                        hostServerName: existing.hostServerName,
                        hostServerOwner: existing.hostServerOwner
                    )
                }
                let fallbackName = (roomData["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackDescription = (roomData["description"] as? String) ?? ""
                let fallbackUsers = (roomData["userCount"] as? Int) ?? 0
                let fallbackPrivate = (roomData["isPrivate"] as? Bool) ?? false
                let fallbackMaxUsers = (roomData["maxUsers"] as? Int) ?? 50
                let now = Date()
                return Room(
                    id: roomId,
                    name: (fallbackName?.isEmpty == false ? fallbackName! : "Room \(roomId)"),
                    description: fallbackDescription,
                    userCount: fallbackUsers,
                    isPrivate: fallbackPrivate,
                    maxUsers: fallbackMaxUsers,
                    createdAt: now,
                    lastActivityAt: now
                )
            }()

            self.currentRoom = joinedRoom
            self.minimizedRoom = nil
            self.currentScreen = .voiceChat
            self.pendingJoinRoomId = nil
            self.errorMessage = "Joined \(joinedRoom.name)."
            self.rememberJoinedRoom(joinedRoom)
            self.scheduleRoomMediaRefresh()
        }

        // Listen for navigation back to main menu
        NotificationCenter.default.addObserver(forName: .goToMainMenu, object: nil, queue: .main) { [weak self] _ in
            self?.returnFromSettings()
        }
    }

    private func scheduleRoomMediaRefresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.serverManager.sendAudioState(
                isMuted: self.serverManager.inputMuted,
                isDeafened: self.serverManager.outputMuted
            )
            self.serverManager.refreshCurrentRoomMedia()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.currentScreen == .voiceChat else { return }
                self.serverManager.sendAudioState(
                    isMuted: self.serverManager.inputMuted,
                    isDeafened: self.serverManager.outputMuted
                )
                self.serverManager.refreshCurrentRoomMedia()
            }
        }
    }

    private func setupHandoffObservers() {
        serverManager.$publicFederationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.evaluateMaintenanceHandoff(using: status)
            }
            .store(in: &cancellables)

        serverManager.$serverConfig
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateMaintenanceHandoff(using: self?.serverManager.publicFederationStatus)
            }
            .store(in: &cancellables)
    }

    private func evaluateMaintenanceHandoff(using status: PublicFederationStatus?) {
        guard isConnected,
              let status,
              status.enabled,
              status.maintenanceModeEnabled,
              status.autoHandoffEnabled,
              let target = status.handoffTargetServer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else {
            activeHandoffOffer = nil
            lastHandoffOfferId = nil
            return
        }

        let sourceBase = APIEndpointResolver.normalize(serverManager.baseURL ?? ServerManager.mainServer)
        let targetBase = APIEndpointResolver.normalize(target)
        guard sourceBase != targetBase else { return }

        let effectiveMode = SettingsManager.shared.effectiveHandoffPromptMode(
            serverDefault: serverManager.serverConfig?.handoffPromptMode
        )
        let offer = HandoffOffer(
            id: "\(sourceBase)->\(targetBase)",
            targetServerURL: targetBase,
            room: currentRoom ?? minimizedRoom,
            effectiveMode: effectiveMode,
            sourceServerURL: sourceBase
        )

        switch effectiveMode {
        case .askAlways:
            if activeHandoffOffer?.id != offer.id && lastHandoffOfferId != offer.id {
                activeHandoffOffer = offer
            }
        case .askOnce, .autoUseSavedChoice:
            if let saved = savedHandoffDecision() {
                applyHandoffDecision(saved, for: offer, rememberChoice: effectiveMode == .autoUseSavedChoice || effectiveMode == .askOnce)
            } else if lastHandoffOfferId != offer.id {
                activeHandoffOffer = offer
            }
        case .serverRecommended:
            if activeHandoffOffer?.id != offer.id {
                activeHandoffOffer = offer
            }
        }
    }

    private func savedHandoffDecision() -> HandoffDecision? {
        guard let raw = UserDefaults.standard.string(forKey: handoffSavedDecisionKey) else { return nil }
        return HandoffDecision(rawValue: raw)
    }

    private func saveHandoffDecision(_ decision: HandoffDecision?) {
        if let decision {
            UserDefaults.standard.set(decision.rawValue, forKey: handoffSavedDecisionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: handoffSavedDecisionKey)
        }
    }

    func respondToActiveHandoff(accept: Bool) {
        guard let offer = activeHandoffOffer else { return }
        let shouldRemember = offer.effectiveMode == .askOnce || offer.effectiveMode == .autoUseSavedChoice
        applyHandoffDecision(accept ? .accept : .decline, for: offer, rememberChoice: shouldRemember)
    }

    private func applyHandoffDecision(_ decision: HandoffDecision, for offer: HandoffOffer, rememberChoice: Bool) {
        activeHandoffOffer = nil
        lastHandoffOfferId = offer.id
        if rememberChoice {
            saveHandoffDecision(decision)
        }

        switch decision {
        case .accept:
            performMaintenanceHandoff(to: offer.targetServerURL, room: offer.room)
        case .decline:
            errorMessage = "Stayed on the current server. Maintenance handoff was declined."
        }
    }

    private func performMaintenanceHandoff(to targetServerURL: String, room: Room?) {
        pendingHandoffTargetURL = APIEndpointResolver.normalize(targetServerURL)
        pendingHandoffRoom = room
        let targetHost = URL(string: targetServerURL)?.host ?? targetServerURL

        if let room {
            errorMessage = "Moving \(room.name) to \(targetHost)..."
        } else {
            errorMessage = "Connecting to \(targetHost)..."
        }

        currentRoom = nil
        minimizedRoom = nil
        pendingJoinRoomId = nil
        serverManager.connectToURL(targetServerURL)
    }

    private func attemptPendingHandoffJoin() {
        guard isConnected,
              let targetURL = pendingHandoffTargetURL,
              let currentBase = serverManager.baseURL,
              APIEndpointResolver.normalize(currentBase) == targetURL else {
            return
        }

        let targetHost = URL(string: targetURL)?.host ?? targetURL
        guard let room = pendingHandoffRoom else {
            pendingHandoffTargetURL = nil
            return
        }

        if let match = rooms.first(where: {
            $0.id == room.id || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(room.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }) {
            pendingHandoffRoom = nil
            pendingHandoffTargetURL = nil
            joinOrShowRoom(match)
            errorMessage = "Connected to \(targetHost) and rejoined \(match.name)."
            return
        }

        pendingRoomDraft = PendingRoomDraft(
            name: room.name,
            description: room.description,
            isPrivate: room.isPrivate,
            roomType: room.roomType ?? (room.isPrivate ? "private" : "standard"),
            maxUsers: room.maxUsers,
            inviteOnly: false,
            hostingPreference: .currentServer
        )
        pendingCreateRoomName = room.name
        pendingHandoffRoom = nil
        pendingHandoffTargetURL = nil
        currentScreen = .createRoom
        errorMessage = "Room \(room.name) is not on \(targetHost) yet. Review the prefilled room settings and create it to continue the handoff."
    }

    private func setupRoomActionObservers() {
        NotificationCenter.default.addObserver(forName: .roomActionMinimize, object: nil, queue: .main) { [weak self] _ in
            self?.minimizeCurrentRoom()
        }
        NotificationCenter.default.addObserver(forName: .roomActionRestore, object: nil, queue: .main) { [weak self] _ in
            self?.restoreMinimizedRoom()
        }
        NotificationCenter.default.addObserver(forName: .roomActionLeave, object: nil, queue: .main) { [weak self] _ in
            self?.leaveCurrentRoom()
        }
        NotificationCenter.default.addObserver(forName: .roomActionJoin, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            guard let room = notification.object as? Room else { return }
            self.setFocusedRoom(room)
            self.joinOrShowRoom(room)
        }
        NotificationCenter.default.addObserver(forName: .roomActionOpenSettings, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            guard let room = notification.object as? Room else { return }
            guard self.canManageRoom(room) else {
                self.errorMessage = "Room settings denied for \(room.name). Your current account is not recognized as owner/admin on this server."
                return
            }
            self.setFocusedRoom(room)
            self.roomToRestoreAfterAdminClose = room
            self.currentScreen = .admin
        }
        NotificationCenter.default.addObserver(forName: .roomActionCreate, object: nil, queue: .main) { [weak self] _ in
            self?.currentScreen = .createRoom
        }
        NotificationCenter.default.addObserver(forName: .roomActionDelete, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            guard let room = notification.object as? Room else { return }
            guard self.canManageRoom(room) else {
                self.errorMessage = "Delete denied for \(room.name). Your current account is not recognized as owner/admin on this server."
                return
            }
            self.deleteRoomFromMenu(room)
        }
    }

    private func setupWindowBehaviorObservers() {
        NotificationCenter.default.addObserver(forName: .mainWindowCloseRequested, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let settings = SettingsManager.shared

            if self.currentScreen != .mainMenu {
                if self.currentRoom != nil {
                    self.currentScreen = .voiceChat
                    self.errorMessage = nil
                    return
                }
                if self.minimizedRoom != nil {
                    self.restoreMinimizedRoom()
                    self.errorMessage = nil
                    return
                }
                let fallback: Screen = (self.previousScreen != self.currentScreen) ? self.previousScreen : .mainMenu
                self.currentScreen = fallback
                self.errorMessage = nil
                return
            }

            // If user is actively in a room, always minimize the room first
            // so session continuity is preserved before hiding/minimizing window.
            if self.currentRoom != nil {
                self.minimizeCurrentRoom()
            }

            switch settings.closeButtonBehavior {
            case .hideToTray:
                AppDelegate.shared?.hideMainWindow()
            case .minimizeWindow:
                AppDelegate.shared?.minimizeMainWindow()
            case .goToMainThenHide:
                AppDelegate.shared?.hideMainWindow()
            }
        }
    }

    private func setupAdminObservers() {
        // Refresh admin capabilities after Mastodon auth completes.
        NotificationCenter.default.addObserver(forName: .mastodonAccountLoaded, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAdminCapabilities()
        }

        // Refresh when server endpoint changes (switch, disconnect, reconnect).
        NotificationCenter.default.addObserver(forName: .serverConnectionChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAdminCapabilities()
        }

        // Email and persisted auth sessions don't emit mastodonAccountLoaded.
        AuthenticationManager.shared.$currentUser
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAdminCapabilities()
            }
            .store(in: &cancellables)
    }

    func refreshAdminCapabilities() {
        guard let serverURL = serverManager.baseURL, !serverURL.isEmpty else {
            AdminServerManager.shared.isAdmin = false
            AdminServerManager.shared.adminRole = .none
            return
        }

        let token = AuthenticationManager.shared.currentUser?.accessToken
        Task {
            await AdminServerManager.shared.checkAdminStatus(serverURL: serverURL, token: token)
            applyLocalAdminFallbackIfNeeded()
        }
    }

    @MainActor
    private func applyLocalAdminFallbackIfNeeded() {
        guard let user = AuthenticationManager.shared.currentUser else { return }

        let normalizedEmail = user.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedUsername = user.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedRole = user.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedProvider = user.authProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedPermissions = Set(user.permissions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        let trustedAdminEmails: Set<String> = [
            "datboydommo@layor8.space",
            "webmaster@raywonderis.me",
            "d.stansberry@me.com"
        ]
        let trustedAdminUsernames: Set<String> = [
            "domdom"
        ]
        let hasElevatedRole = normalizedRole.contains("owner") || normalizedRole.contains("admin")
        let hasElevatedProvider = normalizedProvider.contains("whmcs_admin")
        let hasManagePermission = normalizedPermissions.contains("admin")
            || normalizedPermissions.contains("owner")
            || normalizedPermissions.contains("manage.rooms")
            || normalizedPermissions.contains("manage.server")
            || normalizedPermissions.contains("manage.config")
        let isTrustedIdentity = trustedAdminEmails.contains(normalizedEmail) || trustedAdminUsernames.contains(normalizedUsername)

        guard hasElevatedRole || hasElevatedProvider || hasManagePermission || isTrustedIdentity else { return }

        AdminServerManager.shared.isAdmin = true
        if normalizedRole.contains("owner") || trustedAdminEmails.contains(normalizedEmail) || trustedAdminUsernames.contains(normalizedUsername) {
            AdminServerManager.shared.adminRole = .owner
        } else if AdminServerManager.shared.adminRole == .none {
            AdminServerManager.shared.adminRole = .admin
        }
    }

    func refreshRooms() {
        serverManager.getRooms()
        Task { @MainActor in
            await fetchRoomsViaHTTPFallback()
        }
    }

    @MainActor
    private func fetchRoomsViaHTTPFallback() async {
        var aggregated: [ServerRoom] = []

        func sourceLabel(from base: String) -> String {
            if let host = URL(string: base)?.host, !host.isEmpty {
                return host
            }
            return APIEndpointResolver.normalize(base)
        }

        func fetchRooms(from base: String) async -> [ServerRoom] {
            guard var components = URLComponents(string: base) else { return [] }
            components.path = "/api/rooms"
            components.queryItems = [URLQueryItem(name: "source", value: "app")]
            guard let url = components.url else { return [] }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
                guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
                let source = sourceLabel(from: base)
                return array.compactMap { ServerRoom(from: $0) }.map { room in
                    if let host = room.hostServerName?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
                        return room
                    }
                    return ServerRoom(
                        id: room.id,
                        name: room.name,
                        description: room.description,
                        userCount: room.userCount,
                        isPrivate: room.isPrivate,
                        maxUsers: room.maxUsers,
                        createdBy: room.createdBy,
                        createdByRole: room.createdByRole,
                        roomType: room.roomType,
                        createdAt: room.createdAt,
                        uptimeSeconds: room.uptimeSeconds,
                        lastActiveUsername: room.lastActiveUsername,
                        lastActivityAt: room.lastActivityAt,
                        hostServerName: source,
                        hostServerOwner: room.hostServerOwner
                    )
                }
            } catch {
                return []
            }
        }

        let candidates = APIEndpointResolver.mainBaseCandidates(preferred: serverManager.baseURL)
        for base in candidates {
            aggregated.append(contentsOf: await fetchRooms(from: base))
        }
        if let connectedBase = serverManager.baseURL,
           !connectedBase.isEmpty,
           !candidates.contains(APIEndpointResolver.normalize(connectedBase)) {
            aggregated.append(contentsOf: await fetchRooms(from: connectedBase))
        }

        let deduped = serverManager.deduplicateRooms(aggregated).map(Room.init(from:))
        if !deduped.isEmpty {
            rooms = deduped
            refreshRoomMediaStatuses(for: deduped)
        }
    }

    private func refreshRoomMediaStatuses(for roomList: [Room]) {
        guard let base = serverManager.baseURL, !base.isEmpty else { return }
        let ids = roomList.map(\.id)
        Task(priority: .utility) {
            var statusMap: [String: Bool] = [:]
            for roomId in ids {
                guard let encoded = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let url = URL(string: "\(base)/api/jellyfin/room-stream/\(encoded)") else {
                    continue
                }
                if let (data, response) = try? await URLSession.shared.data(from: url),
                   let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    statusMap[roomId] = (json["active"] as? Bool) == true
                }
            }
            let resolvedStatusMap = statusMap
            await MainActor.run {
                self.roomHasActiveMusic = resolvedStatusMap
            }
        }
    }

    func canManageRoom(_ room: Room) -> Bool {
        let role = room.createdByRole?.lowercased() ?? ""
        let createdBy = room.createdBy?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let currentUser = AuthenticationManager.shared.currentUser
        let ownerCandidates = Set([
            preferredDisplayName().trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            currentUser?.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            currentUser?.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            currentUser?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        ]).filter { !$0.isEmpty }
        let isRoomOwnerByIdentity = !createdBy.isEmpty && ownerCandidates.contains(createdBy)

        return SettingsManager.shared.adminGodModeEnabled
            || AdminServerManager.shared.isAdmin
            || AdminServerManager.shared.adminRole.canManageRooms
            || role.contains("admin")
            || role.contains("owner")
            || isRoomOwnerByIdentity
    }

    func displayDescription(for room: Room) -> String {
        let trimmed = room.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "No description provided." : trimmed
        if roomHasActiveMusic[room.id] == true {
            if base.localizedCaseInsensitiveContains("music playing") || base.localizedCaseInsensitiveContains("live music") {
                return base
            }
            return "\(base) Live music playing."
        }
        return base
    }

    func preferredDisplayName() -> String {
        let nickname = SettingsManager.shared.userNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty {
            return nickname
        }
        if let user = AuthenticationManager.shared.currentUser {
            let display = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !display.isEmpty {
                return display
            }
            let username = user.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !username.isEmpty {
                return username
            }
        }
        return username
    }

    func exportUserDataSnapshot() {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let exportDir = (NSString(string: "~/Downloads/VoiceLink/exports").expandingTildeInPath)
        let filePath = "\(exportDir)/voicelink-user-export-\(timestamp).json"

        let payload: [String: Any] = [
            "exportedAt": formatter.string(from: Date()),
            "appUser": preferredDisplayName(),
            "syncMode": SettingsManager.shared.syncMode.rawValue,
            "roomCount": rooms.count,
            "currentRoomId": currentRoom?.id as Any,
            "currentRoomName": currentRoom?.name as Any,
            "minimizedRoomId": minimizedRoom?.id as Any,
            "connected": isConnected
        ]

        do {
            try FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            errorMessage = "Exported user data to \(filePath)"
        } catch {
            errorMessage = "Failed to export user data: \(error.localizedDescription)"
        }
    }

    func exportRoomSnapshot() {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let exportDir = (NSString(string: "~/Downloads/VoiceLink/exports").expandingTildeInPath)
        let filePath = "\(exportDir)/voicelink-room-snapshot-\(timestamp).json"

        let roomPayload = rooms.map { room in
            [
                "id": room.id,
                "name": room.name,
                "description": room.description,
                "userCount": room.userCount,
                "isPrivate": room.isPrivate
            ] as [String: Any]
        }

        let payload: [String: Any] = [
            "exportedAt": formatter.string(from: Date()),
            "rooms": roomPayload,
            "activeRoomId": activeRoomId as Any,
            "currentRoomUsers": serverManager.currentRoomUsers.map { user in
                [
                    "id": user.id,
                    "username": user.username,
                    "muted": user.isMuted,
                    "deafened": user.isDeafened,
                    "speaking": user.isSpeaking
                ] as [String: Any]
            }
        ]

        do {
            try FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            errorMessage = "Exported room snapshot to \(filePath)"
        } catch {
            errorMessage = "Failed to export room snapshot: \(error.localizedDescription)"
        }
    }

    func joinOrShowRoom(_ room: Room) {
        focusedRoomId = room.id
        if activeRoomId == room.id {
            currentRoom = Room(
                id: room.id,
                name: room.name,
                description: room.description,
                userCount: max(room.userCount, serverManager.currentRoomUsers.filter { !$0.isBot }.count),
                isPrivate: room.isPrivate,
                maxUsers: room.maxUsers,
                createdBy: room.createdBy,
                createdByRole: room.createdByRole,
                roomType: room.roomType,
                createdAt: room.createdAt ?? Date(),
                uptimeSeconds: room.uptimeSeconds,
                lastActiveUsername: room.lastActiveUsername,
                lastActivityAt: Date(),
                hostServerName: room.hostServerName,
                hostServerOwner: room.hostServerOwner
            )
            minimizedRoom = nil
            currentScreen = .voiceChat
            errorMessage = "Room already joined. Showing room."
            return
        }

        if hasActiveRoom {
            let fromName = currentRoom?.name ?? minimizedRoom?.name ?? "current room"
            errorMessage = "Leaving \(fromName) and joining \(room.name)."
            AccessibilityManager.shared.announceStatus("Leaving \(fromName) and joining \(room.name).")
            serverManager.leaveRoom()
            currentRoom = nil
            minimizedRoom = nil
        }

        errorMessage = nil
        let joinName = preferredDisplayName()
        username = joinName
        pendingJoinRoomId = room.id
        errorMessage = "Joining \(room.name)..."
        serverManager.joinRoom(roomId: room.id, username: joinName)
    }

    func setFocusedRoom(_ room: Room?) {
        focusedRoomId = room?.id
    }

    func focusedRoomForQuickJoin() -> Room? {
        if let focusedRoomId,
           let focused = rooms.first(where: { $0.id == focusedRoomId }) {
            return focused
        }
        if let active = rooms.first(where: { $0.userCount > 0 }) {
            return active
        }
        return rooms.first
    }

    func openJoinRoomPanel() {
        currentScreen = .joinRoom
    }

    func handleCommandShiftJ() {
        if currentRoom != nil {
            minimizeCurrentRoom()
            return
        }
        if minimizedRoom != nil {
            restoreMinimizedRoom()
            return
        }
        if rejoinLastRoom() {
            return
        }
        if let focused = focusedRoomForQuickJoin() {
            joinOrShowRoom(focused)
            return
        }
        openJoinRoomPanel()
    }

    @discardableResult
    func joinRoomByCodeOrName(_ rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            errorMessage = "Enter a room ID or room name."
            return false
        }

        let q = query.lowercased()
        if let exact = rooms.first(where: { $0.id.lowercased() == q || $0.name.lowercased() == q }) {
            joinOrShowRoom(exact)
            return true
        }

        if let fuzzy = rooms.first(where: {
            $0.id.lowercased().contains(q)
            || $0.name.lowercased().contains(q)
            || $0.description.lowercased().contains(q)
            || ($0.hostedFromLine?.lowercased().contains(q) ?? false)
        }) {
            joinOrShowRoom(fuzzy)
            return true
        }

        errorMessage = "No room found for \"\(query)\". You can create it now."
        return false
    }

    func minimizeCurrentRoom() {
        guard let room = currentRoom else { return }
        minimizedRoom = room
        currentRoom = nil
        currentScreen = .mainMenu
        errorMessage = "Room minimized. Select Show Room to return."
    }

    func restoreMinimizedRoom() {
        guard let room = minimizedRoom else { return }
        currentRoom = room
        minimizedRoom = nil
        currentScreen = .voiceChat
        errorMessage = nil
    }

    func closeAdminScreen() {
        let roomToRestore = roomToRestoreAfterAdminClose
        roomToRestoreAfterAdminClose = nil
        currentScreen = .mainMenu
        errorMessage = nil

        guard let room = roomToRestore else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .reopenRoomDetailsSheet, object: room)
        }
    }

    func leaveCurrentRoom() {
        serverManager.leaveRoom()
        currentRoom = nil
        minimizedRoom = nil
        currentScreen = .mainMenu
        errorMessage = nil
    }

    @discardableResult
    func rejoinLastRoom() -> Bool {
        guard let last = recentRooms.first else { return false }
        if let currentBase = serverManager.baseURL,
           !currentBase.isEmpty,
           APIEndpointResolver.normalize(currentBase) != APIEndpointResolver.normalize(last.serverURL) {
            serverManager.connectToURL(last.serverURL)
        } else if serverManager.baseURL == nil {
            serverManager.connectToURL(last.serverURL)
        }

        let fallbackRoom = Room(
            id: last.id,
            name: last.name,
            description: last.description,
            userCount: 0,
            isPrivate: false,
            maxUsers: 50,
            hostServerName: last.hostServerName,
            hostServerOwner: nil
        )
        joinOrShowRoom(rooms.first(where: { $0.id == last.id }) ?? fallbackRoom)
        DispatchQueue.main.async {
            AppDelegate.shared?.showMainWindow()
        }
        return true
    }

    private func rememberJoinedRoom(_ room: Room) {
        let base = APIEndpointResolver.normalize(serverManager.baseURL ?? ServerManager.mainServer)
        let entry = RecentRoomEntry(
            id: room.id,
            name: room.name,
            description: room.description,
            serverURL: base,
            hostServerName: room.hostServerName,
            recordedAt: Date()
        )
        recentRooms.removeAll {
            $0.id == entry.id && APIEndpointResolver.normalize($0.serverURL) == entry.serverURL
        }
        recentRooms.insert(entry, at: 0)
        if recentRooms.count > maxRecentRooms {
            recentRooms = Array(recentRooms.prefix(maxRecentRooms))
        }
        saveRecentRooms()
    }

    private func loadRecentRooms() {
        guard let data = UserDefaults.standard.data(forKey: recentRoomsKey),
              let decoded = try? JSONDecoder().decode([RecentRoomEntry].self, from: data) else {
            recentRooms = []
            return
        }
        recentRooms = Array(decoded.prefix(maxRecentRooms))
    }

    private func saveRecentRooms() {
        guard let data = try? JSONEncoder().encode(recentRooms) else { return }
        UserDefaults.standard.set(data, forKey: recentRoomsKey)
    }

    func deleteRoomFromMenu(_ room: Room) {
        Task {
            if !self.canManageRoom(room),
               let serverURL = self.serverManager.baseURL,
               !serverURL.isEmpty {
                let token = AuthenticationManager.shared.currentUser?.accessToken
                await AdminServerManager.shared.checkAdminStatus(serverURL: serverURL, token: token)
            }

            guard self.canManageRoom(room) else {
                await MainActor.run {
                    self.errorMessage = "You do not have permission to delete this room."
                }
                return
            }

            if SettingsManager.shared.confirmBeforeDeletingRooms {
                let action = await MainActor.run { self.confirmRoomDeletionChoice(for: room) }
                switch action {
                case .cancel:
                    return
                case .disableInstead:
                    let disabled = await self.disableRoomFromDeletionPrompt(room)
                    await MainActor.run {
                        self.errorMessage = disabled
                            ? "Room disabled instead of deleting: \(room.name)"
                            : "Unable to disable room \(room.name)."
                    }
                    return
                case .openReplacement:
                    await MainActor.run {
                        if let fallback = self.suggestedReplacementRoom(excluding: room) {
                            NotificationCenter.default.post(name: .reopenRoomDetailsSheet, object: fallback)
                            self.errorMessage = "Open the suggested room and move users there before deleting \(room.name)."
                        } else {
                            self.errorMessage = "No replacement room is currently available."
                        }
                    }
                    return
                case .deleteNow:
                    break
                }
            }

            let deleted = await AdminServerManager.shared.deleteRoom(room.id)
            await MainActor.run {
                if deleted {
                    if self.activeRoomId == room.id {
                        self.leaveCurrentRoom()
                    }
                    self.rooms.removeAll { $0.id == room.id }
                    self.refreshRooms()
                    self.errorMessage = "Room deleted: \(room.name)"
                } else {
                    self.errorMessage = "Failed to delete room \(room.name)."
                }
            }
        }
    }

    private enum RoomDeletionChoice {
        case cancel
        case disableInstead
        case openReplacement
        case deleteNow
    }

    @MainActor
    private func confirmRoomDeletionChoice(for room: Room) -> RoomDeletionChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete room \(room.name)?"

        if room.userCount > 0 {
            let replacement = suggestedReplacementRoom(excluding: room)?.name ?? "another active room"
            alert.informativeText = "This room currently has \(room.userCount) user(s). You should move them to \(replacement) or disable this room before deleting it."
            alert.addButton(withTitle: "Disable Instead")
            alert.addButton(withTitle: "Open Replacement Room")
            alert.addButton(withTitle: "Delete Anyway")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return .disableInstead
            case .alertSecondButtonReturn:
                return .openReplacement
            case .alertThirdButtonReturn:
                return .deleteNow
            default:
                return .cancel
            }
        } else {
            alert.informativeText = "This removes the room from the server. This action should only be used when the room is no longer needed."
            alert.addButton(withTitle: "Delete Room")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .deleteNow : .cancel
        }
    }

    private func suggestedReplacementRoom(excluding room: Room) -> Room? {
        let preferredNames = [
            "Town Square",
            "Community Cafe",
            "General Chat",
            "Open Mic Lounge",
            "Support Dock"
        ]
        for name in preferredNames {
            if let match = rooms.first(where: { candidate in
                candidate.id != room.id && candidate.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                return match
            }
        }
        return rooms.first(where: { candidate in
            candidate.id != room.id && !candidate.isPrivate
        })
    }

    private func disableRoomFromDeletionPrompt(_ room: Room) async -> Bool {
        let replacement = suggestedReplacementRoom(excluding: room)
        let adminRoom = AdminRoomInfo(
            id: room.id,
            name: room.name,
            description: room.description,
            isPrivate: room.isPrivate,
            maxUsers: room.maxUsers,
            userCount: room.userCount,
            createdBy: nil,
            createdAt: nil,
            isPermanent: false,
            backgroundStream: nil,
            visibility: room.isPrivate ? "private" : "public",
            accessType: room.roomType,
            hidden: true,
            locked: room.userCount > 0 ? true : nil,
            enabled: false,
            isDefault: false,
            hostServerName: room.hostServerName,
            hostServerOwner: nil,
            serverSource: room.hostServerName
        )
        let updated = await AdminServerManager.shared.updateRoom(adminRoom)
        if updated {
            await MainActor.run {
                if let replacement {
                    self.errorMessage = "Room disabled. Suggested destination for users: \(replacement.name)"
                }
                self.refreshRooms()
            }
        }
        return updated
    }

    func detectLocalIP() {
        // Get local IP address
        var address: String = "Unknown"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family

                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }

        DispatchQueue.main.async {
            self.localIP = address
        }
    }

}

// MARK: - Models
struct Room: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    var userCount: Int
    let isPrivate: Bool
    let maxUsers: Int
    let createdBy: String?
    let createdByRole: String?
    let roomType: String?
    let createdAt: Date?
    let uptimeSeconds: Int?
    let lastActiveUsername: String?
    let lastActivityAt: Date?
    let hostServerName: String?
    let hostServerOwner: String?

    init(
        id: String,
        name: String,
        description: String,
        userCount: Int,
        isPrivate: Bool,
        maxUsers: Int = 50,
        createdBy: String? = nil,
        createdByRole: String? = nil,
        roomType: String? = nil,
        createdAt: Date? = nil,
        uptimeSeconds: Int? = nil,
        lastActiveUsername: String? = nil,
        lastActivityAt: Date? = nil,
        hostServerName: String? = nil,
        hostServerOwner: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.userCount = userCount
        self.isPrivate = isPrivate
        self.maxUsers = maxUsers
        self.createdBy = createdBy
        self.createdByRole = createdByRole
        self.roomType = roomType
        self.createdAt = createdAt
        self.uptimeSeconds = uptimeSeconds
        self.lastActiveUsername = lastActiveUsername
        self.lastActivityAt = lastActivityAt
        self.hostServerName = hostServerName
        self.hostServerOwner = hostServerOwner
    }

    init(from serverRoom: ServerRoom) {
        self.id = serverRoom.id
        self.name = serverRoom.name
        self.description = serverRoom.description
        self.userCount = serverRoom.userCount
        self.isPrivate = serverRoom.isPrivate
        self.maxUsers = serverRoom.maxUsers
        self.createdBy = serverRoom.createdBy
        self.createdByRole = serverRoom.createdByRole
        self.roomType = serverRoom.roomType
        self.createdAt = serverRoom.createdAt
        self.uptimeSeconds = serverRoom.uptimeSeconds
        self.lastActiveUsername = serverRoom.lastActiveUsername
        self.lastActivityAt = serverRoom.lastActivityAt
        self.hostServerName = serverRoom.hostServerName
        self.hostServerOwner = serverRoom.hostServerOwner
    }

    var hostedFromLine: String? {
        let host = hostServerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = hostServerOwner?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? createdBy?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let host, !host.isEmpty, let owner, !owner.isEmpty {
            return "Hosted from: \(host) • Owner: \(owner)"
        }
        if let host, !host.isEmpty {
            return "Hosted from: \(host)"
        }
        if let owner, !owner.isEmpty {
            return "Owner: \(owner)"
        }
        return nil
    }
}

// MARK: - Content View
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var soundManager = AppSoundManager.shared
    @State private var showJukeboxSheet = false
    @State private var showFileTransfersSheet = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.1, green: 0.1, blue: 0.2),
                    Color(red: 0.05, green: 0.05, blue: 0.15)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Current screen
            switch appState.currentScreen {
            case .mainMenu:
                MainMenuView()
            case .createRoom:
                CreateRoomView()
            case .joinRoom:
                JoinRoomView()
            case .voiceChat:
                VoiceChatView()
            case .settings:
                SettingsView()
            case .servers:
                ServersView()
            case .licensing:
                LicensingScreenView()
            case .admin:
                AdminSettingsView()
            case .login:
                LoginView()
            }

            if let notice = soundManager.activeSoundDownloadNotice {
                VStack {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: notice.isReminder ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.down.circle.fill")
                            .foregroundColor(.yellow)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice.title)
                                .font(.headline)
                                .foregroundColor(.white)
                            Text(notice.message)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.9))
                        }
                        Spacer(minLength: 8)
                        Button("Dismiss") {
                            soundManager.activeSoundDownloadNotice = nil
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.yellow.opacity(0.7), lineWidth: 1)
                    )
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer()
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(notice.title). \(notice.message)")
            }
        }
        .animation(.none, value: appState.currentScreen)
        .onReceive(soundManager.$activeSoundDownloadNotice) { notice in
            guard notice != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if soundManager.activeSoundDownloadNotice?.id == notice?.id {
                    soundManager.activeSoundDownloadNotice = nil
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRoomJukebox)) { _ in
            showJukeboxSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileTransfers)) { _ in
            showFileTransfersSheet = true
        }
        .sheet(isPresented: $showJukeboxSheet) {
            NavigationView {
                JellyfinView()
                    .navigationTitle("Jukebox")
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button("Done") { showJukeboxSheet = false }
                        }
                    }
            }
            .frame(minWidth: 920, minHeight: 620)
        }
        .sheet(isPresented: $showFileTransfersSheet) {
            NavigationView {
                FileTransfersPanel()
                    .navigationTitle("File Transfers")
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button("Done") { showFileTransfersSheet = false }
                        }
                    }
            }
            .frame(minWidth: 760, minHeight: 520)
        }
        .alert(
            "Maintenance Handoff Available",
            isPresented: Binding(
                get: { appState.activeHandoffOffer != nil },
                set: { newValue in
                    if !newValue {
                        appState.activeHandoffOffer = nil
                    }
                }
            ),
            actions: {
                Button("Move to Recommended Server") {
                    appState.respondToActiveHandoff(accept: true)
                }
                Button("Stay Here", role: .cancel) {
                    appState.respondToActiveHandoff(accept: false)
                }
            },
            message: {
                if let offer = appState.activeHandoffOffer {
                    let roomText = offer.room?.name ?? "your current session"
                    Text("This server is asking to hand off \(roomText) to \(offer.targetHostLabel). Your current client preference is \(offer.effectiveMode.displayName).")
                } else {
                    Text("A maintenance handoff is available.")
                }
            }
        )
    }
}

// MARK: - Main Menu View
struct VoiceChatView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var messagingManager = MessagingManager.shared
    @ObservedObject var adminManager = AdminServerManager.shared
    @ObservedObject var roomLockManager = RoomLockManager.shared
    @ObservedObject var audioControl = UserAudioControlManager.shared
    @ObservedObject var settings = SettingsManager.shared
    @ObservedObject private var authManager = AuthenticationManager.shared
    @State private var isMuted = false
    @State private var isDeafened = false
    @State private var messageText = ""
    @State private var showChat = true
    @State private var showRoomActionsSheet = false
    @State private var pendingEscapeTimestamp: Date?
    @State private var escapeKeyMonitor: Any?
    @State private var selectedDirectMessageUserId: String?
    @State private var selectedDirectMessageUserName: String?
    @State private var pendingChatShareURLs: [URL] = []
    @State private var showChatShareSheet = false
    @State private var chatShareKeepForever = false
    @State private var chatShareCaption = ""
    @State private var chatShareExpiryHours = 24
    @State private var chatShareInProgress = false
    @State private var selectedRoomDetails: Room?

    private var meDisplayName: String {
        appState.preferredDisplayName()
    }

    private var visibleRoomUsers: [RoomUser] {
        let selfCandidates = Set([
            appState.username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            appState.preferredDisplayName().lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        ])
        return appState.serverManager.currentRoomUsers.filter { user in
            !selfCandidates.contains(user.username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private var selectedDirectMessages: [MessagingManager.ChatMessage] {
        guard let userId = selectedDirectMessageUserId else { return [] }
        return messagingManager.getDirectMessages(with: userId)
    }

    private var currentChatMessages: [MessagingManager.ChatMessage] {
        selectedDirectMessageUserId == nil ? messagingManager.messages : selectedDirectMessages
    }

    private var chatTitle: String {
        if let name = selectedDirectMessageUserName, !name.isEmpty {
            return "Direct Messages with \(name)"
        }
        return "Room Chat"
    }

    private var currentChatPlaceholder: String {
        if let name = selectedDirectMessageUserName, !name.isEmpty {
            return "Message \(name)..."
        }
        return "Type a message..."
    }

    private var currentHistoryStatus: String {
        if let userId = selectedDirectMessageUserId {
            return messagingManager.directHistoryStatus[userId] ?? ""
        }
        return messagingManager.roomHistoryStatus
    }

    private var canLoadOlderMessages: Bool {
        if let userId = selectedDirectMessageUserId {
            return messagingManager.directMessageHasMore[userId] ?? false
        }
        return messagingManager.roomHasMoreMessages
    }

    private var inRoomAnnouncementText: String {
        guard let config = appState.serverManager.serverConfig else { return "" }
        let welcome = config.welcomeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let motd = config.motd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let settings = config.motdSettings

        guard settings.enabled, settings.showInRoom else { return "" }

        if settings.appendToWelcomeMessage {
            return [welcome, motd].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        return motd.isEmpty ? welcome : motd
    }

    private var canControlRoomMedia: Bool {
        authManager.authState == .authenticated && authManager.currentUser != nil
    }

    private var hasRoomMediaAvailable: Bool {
        appState.roomHasActiveMusic[appState.currentRoom?.id ?? ""] == true
            || ((appState.serverManager.currentRoomMedia?.active) == true)
    }

    @ViewBuilder
    private var roomMediaSection: some View {
        if let media = appState.serverManager.currentRoomMedia, media.active {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Now Playing")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(media.title?.isEmpty == false ? media.title! : "Room media stream")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.9))
                        Text(media.type?.isEmpty == false ? (media.type!.capitalized) : "Audio Stream")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Text(appState.serverManager.isCurrentRoomMediaMuted ? "Muted" : "Live")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(appState.serverManager.isCurrentRoomMediaMuted ? .orange : .green)
                }

                if let url = URL(string: media.streamURL) {
                    Text(url.host ?? media.streamURL)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    Button(appState.serverManager.isCurrentRoomMediaMuted ? "Unmute Stream" : "Mute Stream") {
                        appState.serverManager.toggleCurrentRoomMediaMuted()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canControlRoomMedia)

                    Text(canControlRoomMedia ? "Room media follows your current room session." : "Sign in to control room media playback.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.green.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.green.opacity(0.28), lineWidth: 1)
            )
            .cornerRadius(10)
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var roomSidebar: some View {
        VStack {
            HStack {
                VStack(alignment: .leading) {
                    Text(appState.currentRoom?.name ?? "Room")
                        .font(.title)
                        .foregroundColor(.white)
                    Text(appState.currentRoom?.description ?? "")
                        .foregroundColor(.gray)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(appState.serverManager.isAudioTransmitting ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text("Audio: \(appState.serverManager.audioTransmissionStatus)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Text("Input: \(isMuted ? "Muted" : "Unmuted") • Output: \(isDeafened ? "Muted" : "Unmuted")")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                Spacer()

                Menu {
                    Button("Room Actions...") {
                        showRoomActionsSheet = true
                    }
                    Button("Room Details") {
                        if let room = appState.currentRoom {
                            selectedRoomDetails = room
                        }
                    }
                    Button("Open Jukebox") {
                        NotificationCenter.default.post(name: .openRoomJukebox, object: nil)
                    }
                    Button("Share Room Link") {
                        guard let room = appState.currentRoom else { return }
                        let roomURL = "https://voicelink.devinecreations.net/?room=\(room.id)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(roomURL, forType: .string)
                        AppSoundManager.shared.playSound(.success)
                    }
                    Button("Copy Room ID") {
                        guard let room = appState.currentRoom else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(room.id, forType: .string)
                    }
                    if roomLockManager.canCurrentUserLock {
                        Button(roomLockManager.isRoomLocked ? "Unlock Room" : "Lock Room") {
                            roomLockManager.toggleLock()
                        }
                    }
                    if let room = appState.currentRoom, appState.canManageRoom(room) {
                        Button("Server Administration") {
                            appState.currentScreen = .admin
                        }
                        Divider()
                    }
                    Button("Minimize Room") {
                        appState.minimizeCurrentRoom()
                    }
                    Button("Leave Room", role: .destructive) {
                        appState.leaveCurrentRoom()
                    }
                } label: {
                    Label("Room", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .menuStyle(.borderlessButton)
            }
            .padding()

            if !inRoomAnnouncementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server Message")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                    Text(inRoomAnnouncementText)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.88))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.blue.opacity(0.35), lineWidth: 1)
                )
                .cornerRadius(10)
                .padding(.horizontal)
            }

            roomMediaSection

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Users in Room")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(visibleRoomUsers.filter { !$0.isBot }.count + 1)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                ScrollView {
                    LazyVStack(spacing: 8) {
                        UserRow(
                            userId: "self",
                            username: "\(meDisplayName) (Me)",
                            isMuted: isMuted,
                            isDeafened: isDeafened,
                            isSpeaking: appState.serverManager.isAudioTransmitting && !isMuted,
                            isCurrentUser: true,
                            roomName: appState.currentRoom?.name,
                            connectedServerName: appState.serverManager.connectedServer
                        )

                        ForEach(visibleRoomUsers) { user in
                            UserRow(
                                userId: user.odId,
                                username: user.username,
                                isMuted: user.isMuted,
                                isDeafened: user.isDeafened,
                                isSpeaking: user.isSpeaking,
                                roomUser: user,
                                roomName: appState.currentRoom?.name,
                                connectedServerName: appState.serverManager.connectedServer
                            )
                        }
                    }
                }
            }
            .padding(.horizontal)

            Spacer()

            HStack(spacing: 30) {
                VoiceControlButton(icon: isMuted ? "mic.slash.fill" : "mic.fill",
                                  label: isMuted ? "Unmute Microphone" : "Mute Microphone",
                                  isActive: !isMuted) {
                    isMuted.toggle()
                    appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
                    AppSoundManager.shared.playSound(isMuted ? .toggleOff : .toggleOn)
                    AccessibilityManager.shared.announceAudioStatus(isMuted ? "muted" : "unmuted")
                }
                .accessibilityLabel(isMuted ? "Unmute Microphone" : "Mute Microphone")
                .accessibilityHint("Toggle microphone input. Currently \(isMuted ? "muted" : "unmuted")")

                VoiceControlButton(icon: isDeafened ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                  label: isDeafened ? "Unmute Output" : "Mute Output",
                                  isActive: !isDeafened) {
                    isDeafened.toggle()
                    appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
                    AppSoundManager.shared.playSound(isDeafened ? .toggleOff : .toggleOn)
                    AccessibilityManager.shared.announceAudioStatus(isDeafened ? "deafened" : "undeafened")
                }
                .accessibilityLabel(isDeafened ? "Unmute Output" : "Mute Output")
                .accessibilityHint("Toggle audio output. Currently \(isDeafened ? "muted - you cannot hear others" : "unmuted - you can hear others")")

                VoiceControlButton(icon: showChat ? "bubble.left.fill" : "bubble.left",
                                  label: showChat ? "Hide Chat" : "Show Chat",
                                  isActive: showChat) {
                    showChat.toggle()
                }
            }
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 10) {
                Text("Playback")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))

                HStack(spacing: 10) {
                    if hasRoomMediaAvailable {
                        Button(appState.serverManager.isCurrentRoomMediaMuted ? "Unmute Media" : "Mute Media") {
                            appState.serverManager.toggleCurrentRoomMediaMuted()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canControlRoomMedia)
                        .accessibilityHint("Mutes or unmutes room media playback for your current session.")
                    }

                    Text("VoiceLink Volume")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 104, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { settings.outputVolume },
                            set: { newValue in
                                settings.outputVolume = newValue
                                audioControl.setMasterVolume(Float(newValue))
                                settings.saveSettings()
                            }
                        ),
                        in: 0...1.5
                    )
                    .accessibilityLabel("VoiceLink master volume")
                    .accessibilityHint("Adjusts overall VoiceLink playback volume for heard users, room media, and preview audio.")

                    Text("\(Int(settings.outputVolume * 100))%")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.bottom, 12)

            HStack(spacing: 15) {
                Text("⌘M Mute Microphone")
                Text("⌘D Mute Output")
                Text("⌘Enter Send")
            }
            .font(.caption)
            .foregroundColor(.gray)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 300)
    }

    @ViewBuilder
    private var chatPanel: some View {
        HStack(spacing: 0) {
            ChatConversationSidebar(
                visibleRoomUsers: visibleRoomUsers,
                selectedDirectMessageUserId: selectedDirectMessageUserId,
                unreadCounts: messagingManager.unreadCounts,
                onSelectMainRoomChat: {
                    selectedDirectMessageUserId = nil
                    selectedDirectMessageUserName = nil
                    Task { @MainActor in
                        await messagingManager.skipToLatestRoomMessages()
                    }
                },
                onOpenDirectMessage: { user in
                    openDirectMessage(with: user)
                }
            )

            Divider().overlay(Color.white.opacity(0.08))

            ChatConversationPanel(
                chatTitle: chatTitle,
                selectedDirectMessageUserId: selectedDirectMessageUserId,
                selectedDirectMessageUserName: selectedDirectMessageUserName,
                totalUnreadCount: messagingManager.totalUnreadCount,
                canLoadOlderMessages: canLoadOlderMessages,
                currentHistoryStatus: currentHistoryStatus,
                currentChatMessages: currentChatMessages,
                currentChatPlaceholder: currentChatPlaceholder,
                isOnline: appState.serverStatus == .online,
                hasCurrentRoom: appState.currentRoom != nil,
                isSharing: chatShareInProgress,
                messageText: $messageText,
                onBack: {
                    selectedDirectMessageUserId = nil
                    selectedDirectMessageUserName = nil
                },
                onLoadOlder: {
                    Task { @MainActor in
                        if let userId = selectedDirectMessageUserId {
                            await messagingManager.loadOlderDirectMessages(with: userId)
                        } else {
                            await messagingManager.loadOlderRoomMessages()
                        }
                    }
                },
                onSkipToLatest: {
                    Task { @MainActor in
                        if let userId = selectedDirectMessageUserId {
                            await messagingManager.skipToLatestDirectMessages(with: userId)
                        } else {
                            await messagingManager.skipToLatestRoomMessages()
                        }
                    }
                },
                onSelectAttachment: selectChatFileForSharing,
                onSendMessage: sendMessage,
                onSendFileToSender: actionForSendingFile(to:),
                onDirectMessageSender: actionForDirectMessage(to:),
                onViewSenderProfile: actionForViewingSenderProfile(for:)
            )
        }
        .frame(minWidth: 420, idealWidth: 520)
        .background(Color.black.opacity(0.2))
    }

    var body: some View {
        HSplitView {
            roomSidebar

            if showChat {
                chatPanel
            }
        }
        .onAppear {
            // Ensure room audio path is active when chat view is visible.
            appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
            appState.serverManager.refreshCurrentRoomMedia()
            setupEscapeMonitor()
            if let roomId = appState.currentRoom?.id {
                Task { @MainActor in
                    messagingManager.beginRoomSession(roomId: roomId)
                }
            }
        }
        .onChange(of: appState.activeRoomId) { _ in
            appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
            appState.serverManager.refreshCurrentRoomMedia()
        }
        .onDisappear {
            tearDownEscapeMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDirectMessage)) { notification in
            guard let info = notification.userInfo else { return }
            guard let userId = info["userId"] as? String else { return }
            let userName = info["userName"] as? String ?? "User"
            selectedDirectMessageUserId = userId
            selectedDirectMessageUserName = userName
            Task { @MainActor in
                await messagingManager.loadDirectHistory(with: userId, reset: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMute)) { _ in
            isMuted.toggle()
            appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
            AppSoundManager.shared.playSound(isMuted ? .toggleOff : .toggleOn)
            // Announce state change
            AccessibilityManager.shared.announceAudioStatus(isMuted ? "muted" : "unmuted")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleDeafen)) { _ in
            isDeafened.toggle()
            appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
            AppSoundManager.shared.playSound(isDeafened ? .toggleOff : .toggleOn)
            // Announce state change
            AccessibilityManager.shared.announceAudioStatus(isDeafened ? "deafened" : "undeafened")
        }
        .sheet(isPresented: $showRoomActionsSheet) {
            if let room = appState.currentRoom {
                RoomActionMenu(room: room, isInRoom: true, isPresented: $showRoomActionsSheet)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $selectedRoomDetails) { room in
            RoomDetailsSheet(
                room: room,
                roomHasActiveMedia: appState.roomHasActiveMusic[room.id] == true,
                isActiveRoom: appState.activeRoomId == room.id,
                onJoin: { appState.joinOrShowRoom(room) },
                onShare: { shareCurrentRoom(room) },
                onPreview: appState.activeRoomId == room.id ? nil : {
                    PeekManager.shared.togglePreview(
                        for: room,
                        canPreview: SettingsManager.shared.canPreviewRoom(
                            roomId: room.id,
                            userCount: room.userCount,
                            hasActiveMedia: appState.roomHasActiveMusic[room.id] == true
                        )
                    )
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .reopenRoomDetailsSheet)) { notification in
            guard appState.currentScreen == .voiceChat else { return }
            guard let room = notification.object as? Room else { return }
            selectedRoomDetails = room
        }
        .sheet(isPresented: $showChatShareSheet, onDismiss: resetChatShareDraft) {
            if !pendingChatShareURLs.isEmpty {
                ProtectedFileShareSheet(
                    fileURLs: pendingChatShareURLs,
                    recipientName: selectedDirectMessageUserName ?? (appState.currentRoom?.name ?? "this room"),
                    keepForever: $chatShareKeepForever,
                    caption: $chatShareCaption,
                    expiryHours: $chatShareExpiryHours,
                    isSending: chatShareInProgress,
                    onCancel: {
                        showChatShareSheet = false
                    },
                    onSend: {
                        shareSelectedChatFile()
                    }
                )
            }
        }
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }

        // Check if we're connected
        guard appState.serverStatus == .online else {
            print("Cannot send message: Not connected to server")
            return
        }

        // Check if we're in a room
        guard appState.currentRoom != nil else {
            print("Cannot send message: Not in a room")
            return
        }

        print("Sending message: \(messageText)")
        if let userId = selectedDirectMessageUserId {
            messagingManager.sendDirectMessage(to: userId, username: selectedDirectMessageUserName ?? "User", content: messageText)
            messagingManager.markAsRead(userId: userId)
        } else {
            messagingManager.sendRoomMessage(messageText)
        }
        AppSoundManager.shared.playSound(.messageSent)
        messageText = ""
    }

    private func openDirectMessage(with user: RoomUser) {
        selectedDirectMessageUserId = user.odId
        selectedDirectMessageUserName = user.displayName ?? user.username
        Task { @MainActor in
            await messagingManager.loadDirectHistory(with: user.odId, reset: true)
        }
    }

    private func selectChatFileForSharing() {
        FileTransferManager.shared.showFilePicker(allowsMultipleSelection: true) { urls in
            guard !urls.isEmpty else { return }
            pendingChatShareURLs = urls
            chatShareCaption = ""
            chatShareKeepForever = false
            chatShareExpiryHours = max(1, min(24 * 60, CopyPartyManager.shared.config.defaultExternalLinkExpiryHours))
            showChatShareSheet = true
        }
    }

    private func shareSelectedChatFile() {
        guard !pendingChatShareURLs.isEmpty else { return }
        chatShareInProgress = true
        let keepForever = chatShareKeepForever
        let expiryHours = keepForever ? nil : max(1, min(24 * 60, chatShareExpiryHours))
        let caption = chatShareCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedFiles = pendingChatShareURLs

        Task {
            defer {
                DispatchQueue.main.async {
                    chatShareInProgress = false
                }
            }
            do {
                let attachmentName = selectedFiles.count > 1
                    ? "\(selectedFiles.count) files"
                    : selectedFiles[0].lastPathComponent
                let link: CopyPartyManager.ProtectedShareLink
                if selectedFiles.count > 1 {
                    link = try await CopyPartyManager.shared.uploadFilesAndCreateProtectedLink(
                        from: selectedFiles,
                        to: "/uploads/chat",
                        folderName: "VoiceLink-Chat-Files",
                        keepForever: keepForever,
                        expiryHours: expiryHours
                    )
                } else {
                    link = try await CopyPartyManager.shared.uploadFileAndCreateProtectedLink(
                        from: selectedFiles[0],
                        to: "/uploads/chat",
                        keepForever: keepForever,
                        expiryHours: expiryHours
                    )
                }
                DispatchQueue.main.async {
                    if let userId = selectedDirectMessageUserId {
                        messagingManager.sendDirectAttachment(
                            to: userId,
                            username: selectedDirectMessageUserName ?? "User",
                            content: selectedFiles.count > 1 ? "Shared \(selectedFiles.count) files." : "Shared file: \(attachmentName)",
                            attachmentName: attachmentName,
                            attachmentURL: link.url,
                            caption: caption,
                            expiresAt: link.expiresAt
                        )
                    } else {
                        messagingManager.sendRoomAttachment(
                            content: selectedFiles.count > 1 ? "Shared \(selectedFiles.count) files." : "Shared file: \(attachmentName)",
                            attachmentName: attachmentName,
                            attachmentURL: link.url,
                            caption: caption,
                            expiresAt: link.expiresAt
                        )
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url, forType: .string)
                    showChatShareSheet = false
                }
            } catch {
                DispatchQueue.main.async {
                    messagingManager.sendSystemMessage("File share failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func shareCurrentRoom(_ room: Room) {
        let roomURL = "https://voicelink.devinecreations.net/?room=\(room.id)"
        let url = URL(string: roomURL) ?? URL(fileURLWithPath: roomURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(roomURL, forType: .string)
        if let contentView = NSApp.keyWindow?.contentView {
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
        } else {
            NSWorkspace.shared.open(url)
        }
        AppSoundManager.shared.playSound(.success)
    }

    private func resetChatShareDraft() {
        pendingChatShareURLs = []
        chatShareCaption = ""
        chatShareKeepForever = false
        chatShareExpiryHours = 24
    }

    private func actionForDirectMessage(to message: MessagingManager.ChatMessage) -> (() -> Void)? {
        guard message.type != .system else { return nil }
        let senderId = message.senderId
        let senderName = message.senderName
        guard !senderId.isEmpty, !isMessageFromCurrentUser(message) else { return nil }
        return {
            selectedDirectMessageUserId = senderId
            selectedDirectMessageUserName = senderName
            Task { @MainActor in
                await messagingManager.loadDirectHistory(with: senderId, reset: true)
            }
        }
    }

    private func actionForSendingFile(to message: MessagingManager.ChatMessage) -> (() -> Void)? {
        guard message.type != .system else { return nil }
        let senderId = message.senderId
        let senderName = message.senderName
        guard !senderId.isEmpty, !isMessageFromCurrentUser(message) else { return nil }
        return {
            selectedDirectMessageUserId = senderId
            selectedDirectMessageUserName = senderName
            selectChatFileForSharing()
        }
    }

    private func actionForViewingSenderProfile(for message: MessagingManager.ChatMessage) -> (() -> Void)? {
        guard message.type != .system else { return nil }
        let senderId = message.senderId
        guard !senderId.isEmpty, !isMessageFromCurrentUser(message) else { return nil }
        return {
            NotificationCenter.default.post(
                name: .openDirectMessage,
                object: nil,
                userInfo: ["userId": senderId, "userName": message.senderName]
            )
        }
    }

    private func isMessageFromCurrentUser(_ message: MessagingManager.ChatMessage) -> Bool {
        let currentUsername = appState.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let currentDisplay = appState.preferredDisplayName().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let senderId = message.senderId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let senderName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return senderId == "self" || senderName == currentUsername || senderName == currentDisplay
    }

    private func setupEscapeMonitor() {
        guard escapeKeyMonitor == nil else { return }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape key
            guard event.keyCode == 53 else { return event }

            // Let text fields keep normal Escape behavior.
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }

            let now = Date()
            if let previous = pendingEscapeTimestamp,
               now.timeIntervalSince(previous) <= 1.0 {
                pendingEscapeTimestamp = nil
                showRoomActionsSheet = true
                AppSoundManager.shared.playSound(.menuOpen)
                AccessibilityManager.shared.announce("Room actions menu opened")
                return nil
            }

            pendingEscapeTimestamp = now
            AccessibilityManager.shared.announce("Press Escape again to open room actions")
            return nil
        }
    }

    private func tearDownEscapeMonitor() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
        pendingEscapeTimestamp = nil
    }
}

// Chat message row view
struct FeatureBadge: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
            Text(text)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(8)
        .background(Color.white.opacity(0.1))
        .cornerRadius(8)
    }
}
