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

                Button("Join or Search Rooms...") {
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

                        Button("Column") {
                            NotificationCenter.default.post(name: .roomFilterLayoutChanged, object: nil, userInfo: ["layout": "column"])
                        }
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
                } else if licensing.licenseStatus == .pending {
                    Text("Status: Pending (\(licensing.remainingMinutes) min)")
                } else {
                    Text("Status: Not Registered")
                }

                Divider()

                Button("Refresh License") {
                    Task {
                        await licensing.checkStatus()
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
    static let roomFilterReset = Notification.Name("roomFilterReset")
    static let roomFilterScopeChanged = Notification.Name("roomFilterScopeChanged")
    static let roomFilterSortChanged = Notification.Name("roomFilterSortChanged")
    static let roomFilterLayoutChanged = Notification.Name("roomFilterLayoutChanged")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    static var shared: AppDelegate?
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
            if SettingsManager.shared.openMainWindowOnLaunch {
                self.showMainWindow()
            } else {
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
    private var previousScreen: Screen = .mainMenu
    private let recentRoomsKey = "voicelink.recentRooms"
    private let maxRecentRooms = 10

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
        setupURLObservers()
        refreshAdminCapabilities()
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
            }
            .store(in: &cancellables)

        // Keep admin capabilities in sync with active server connection.
        serverManager.$isConnected
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshAdminCapabilities()
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
                    return existing
                }
                let fallbackName = (roomData["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackDescription = (roomData["description"] as? String) ?? ""
                let fallbackUsers = (roomData["userCount"] as? Int) ?? 0
                let fallbackPrivate = (roomData["isPrivate"] as? Bool) ?? false
                let fallbackMaxUsers = (roomData["maxUsers"] as? Int) ?? 50
                return Room(
                    id: roomId,
                    name: (fallbackName?.isEmpty == false ? fallbackName! : "Room \(roomId)"),
                    description: fallbackDescription,
                    userCount: fallbackUsers,
                    isPrivate: fallbackPrivate,
                    maxUsers: fallbackMaxUsers
                )
            }()

            self.currentRoom = joinedRoom
            self.minimizedRoom = nil
            self.currentScreen = .voiceChat
            self.pendingJoinRoomId = nil
            self.errorMessage = "Joined \(joinedRoom.name)."
            self.rememberJoinedRoom(joinedRoom)
        }

        // Listen for navigation back to main menu
        NotificationCenter.default.addObserver(forName: .goToMainMenu, object: nil, queue: .main) { [weak self] _ in
            self?.currentScreen = .mainMenu
        }
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
            currentRoom = room
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
    }
}

// MARK: - Main Menu View
struct MainMenuView: View {
    enum RoomSortOption: String, CaseIterable, Identifiable {
        case activeFirst = "Active First"
        case mostMembers = "Most Members"
        case alphabeticalAZ = "A-Z"
        case alphabeticalZA = "Z-A"

        var id: String { rawValue }
    }
    enum RoomLayoutOption: String, CaseIterable, Identifiable {
        case list = "List"
        case grid = "Grid"
        case column = "Column"
        var id: String { rawValue }
    }
    enum RoomScopeFilter: String, CaseIterable, Identifiable {
        case all = "All Rooms"
        case publicOnly = "Public"
        case privateOnly = "Private"
        case activeUsers = "Active Users"
        case mediaActive = "Media Active"
        var id: String { rawValue }
    }

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var localDiscovery: LocalServerDiscovery
    @ObservedObject private var authManager = AuthenticationManager.shared
    @ObservedObject private var adminManager = AdminServerManager.shared
    @State private var roomSortOption: RoomSortOption = .activeFirst
    @State private var roomLayoutOption: RoomLayoutOption = .list
    @State private var roomScopeFilter: RoomScopeFilter = .all
    @State private var selectedServerFilter: String = "All Servers"
    @State private var roomDomainFilter: String = ""
    @State private var selectedRoomDetails: Room?
    @State private var selectedRoomActionRoom: Room?
    @State private var showRoomActionMenuSheet = false
    @State private var showCreateInviteSheet = false
    @State private var showServerStatusSheet = false
    @State private var showRoomBrowserOptionsSheet = false
    @State private var showMastodonAuthSheet = false
    @State private var showEmailAuthSheet = false
    @State private var showAdminInviteSheet = false
    private let statusRefreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var isAuthenticatedForRoomAccess: Bool {
        authManager.authState == .authenticated && authManager.currentUser != nil
    }

    private var effectiveAuthServerURL: String {
        if let pending = authManager.pendingAdminInviteServerURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pending.isEmpty {
            return pending
        }
        if let base = appState.serverManager.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !base.isEmpty {
            return base
        }
        return ServerManager.mainServer
    }

    private var registrationPortalURL: URL? {
        URL(string: "https://devine-creations.com/register.php")
    }

    private func openRegistrationPortal() {
        guard let url = registrationPortalURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var hasPendingAdminInvite: Bool {
        guard let token = authManager.pendingAdminInviteToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !token.isEmpty
    }

    var statusColor: Color {
        switch appState.serverStatus {
        case .online: return .green
        case .connecting: return .yellow
        case .offline: return .red
        }
    }

    var statusText: String {
        switch appState.serverStatus {
        case .online: return "Connected"
        case .connecting: return "Connecting..."
        case .offline: return "Offline"
        }
    }

    var serverStatusSummary: String {
        let base = appState.serverManager.baseURL ?? ""
        let host = URL(string: base)?.host
            ?? URL(string: appState.serverManager.connectedServer)?.host
            ?? appState.serverManager.connectedServer
        let resolvedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return appState.isConnected
            ? "Connected to \(resolvedHost.isEmpty ? "active server" : resolvedHost)"
            : statusText
    }

    private var roomFilterSummary: String {
        var parts: [String] = []
        if selectedServerFilter != "All Servers" {
            parts.append(selectedServerFilter)
        }
        let trimmedDomain = roomDomainFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDomain.isEmpty {
            parts.append("Domain: \(trimmedDomain)")
        }
        if roomScopeFilter != .all {
            parts.append(roomScopeFilter.rawValue)
        }
        if roomSortOption != .activeFirst {
            parts.append(roomSortOption.rawValue)
        }
        if roomLayoutOption != .list {
            parts.append(roomLayoutOption.rawValue)
        }
        return parts.isEmpty ? "All rooms" : parts.joined(separator: " • ")
    }

    var sortedRooms: [Room] {
        switch roomSortOption {
        case .activeFirst:
            return appState.rooms.sorted {
                if ($0.userCount > 0) != ($1.userCount > 0) {
                    return $0.userCount > 0
                }
                if $0.userCount != $1.userCount {
                    return $0.userCount > $1.userCount
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .mostMembers:
            return appState.rooms.sorted {
                if $0.userCount != $1.userCount {
                    return $0.userCount > $1.userCount
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .alphabeticalAZ:
            return appState.rooms.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .alphabeticalZA:
            return appState.rooms.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending
            }
        }
    }

    private func serverLabel(for room: Room) -> String {
        let hostName = room.hostServerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hostName.isEmpty {
            return hostName
        }
        let hostedFrom = room.hostedFromLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if hostedFrom.lowercased().hasPrefix("hosted by "), hostedFrom.count > 10 {
            return String(hostedFrom.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !hostedFrom.isEmpty {
            return hostedFrom
        }
        return "Unknown Server"
    }

    var availableServerFilters: [String] {
        var unique = Set(appState.rooms.map { serverLabel(for: $0) })
        if let base = appState.serverManager.baseURL,
           let host = URL(string: base)?.host,
           !host.isEmpty {
            unique.insert(host)
        }
        return ["All Servers"] + unique.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var filteredRooms: [Room] {
        sortedRooms.filter { room in
            let roomServerLabel = serverLabel(for: room)
            let matchesServer = selectedServerFilter == "All Servers" || roomServerLabel == selectedServerFilter
            let domainQuery = roomDomainFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesDomain = domainQuery.isEmpty || roomServerLabel.lowercased().contains(domainQuery)
            let lowerServerLabel = roomServerLabel.lowercased()
            let isLocalOnlyRoom = lowerServerLabel.contains("localhost") || lowerServerLabel.contains("local server")
            let matchesVisibility = (!room.isPrivate || SettingsManager.shared.showPrivateMemberRooms)
                && (SettingsManager.shared.showLocalOnlyRooms || !isLocalOnlyRoom)
                && (SettingsManager.shared.showFederatedRooms || !SettingsManager.shared.isVisibleFederationHost(roomServerLabel))
                && SettingsManager.shared.isVisibleFederationHost(roomServerLabel)
            let matchesScope: Bool
            switch roomScopeFilter {
            case .all:
                matchesScope = true
            case .publicOnly:
                matchesScope = !room.isPrivate
            case .privateOnly:
                matchesScope = room.isPrivate
            case .activeUsers:
                matchesScope = room.userCount > 0
            case .mediaActive:
                matchesScope = appState.roomHasActiveMusic[room.id] == true
            }
            return matchesServer && matchesDomain && matchesVisibility && matchesScope
        }
    }

    private func resetRoomFilters() {
        selectedServerFilter = "All Servers"
        roomDomainFilter = ""
        roomScopeFilter = .all
        roomSortOption = .activeFirst
        roomLayoutOption = .list
    }

    private func applyScopeShortcut(_ rawValue: String) {
        switch rawValue {
        case "all":
            roomScopeFilter = .all
        case "public":
            roomScopeFilter = .publicOnly
        case "private":
            roomScopeFilter = .privateOnly
        case "active":
            roomScopeFilter = .activeUsers
        case "media":
            roomScopeFilter = .mediaActive
        default:
            break
        }
    }

    private func applySortShortcut(_ rawValue: String) {
        switch rawValue {
        case "active":
            roomSortOption = .activeFirst
        case "members":
            roomSortOption = .mostMembers
        case "az":
            roomSortOption = .alphabeticalAZ
        case "za":
            roomSortOption = .alphabeticalZA
        default:
            break
        }
    }

    private func applyLayoutShortcut(_ rawValue: String) {
        switch rawValue {
        case "list":
            roomLayoutOption = .list
        case "grid":
            roomLayoutOption = .grid
        case "column":
            roomLayoutOption = .column
        default:
            break
        }
    }

    @ViewBuilder
    private var authRequiredOverlay: some View {
        VStack(spacing: 14) {
            Text("Guest Mode Active")
                .font(.title2.weight(.semibold))
                .foregroundColor(.white)

            Text("You can browse and join rooms as a guest. Sign in to unlock full room creation and account linking.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)

            if hasPendingAdminInvite {
                Text("An admin invite was detected. Activate it first, then continue.")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }

            HStack(spacing: 10) {
                Button("Sign In: Email") { showEmailAuthSheet = true }
                    .buttonStyle(.borderedProminent)
                Button("Mastodon") { showMastodonAuthSheet = true }
                    .buttonStyle(.bordered)
                Button("Admin Invite") { showAdminInviteSheet = true }
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button("Google") {
                    if let url = URL(string: "https://voicelink.devinecreations.net/auth/google") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Apple") {
                    if let url = URL(string: "https://voicelink.devinecreations.net/auth/apple") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("GitHub") {
                    if let url = URL(string: "https://voicelink.devinecreations.net/auth/github") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Alternative sign in providers")
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(Color.black.opacity(0.82))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 10)
    }

    @ViewBuilder
    private var mainWindowHeaderPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(serverStatusSummary)
                            .foregroundColor(.white)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("Local IP: \(appState.localIP)")
                        .foregroundColor(.white.opacity(0.6))
                        .font(.caption)
                }

                Spacer()

                Button("Server Status") {
                    showServerStatusSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(alignment: .top, spacing: 16) {
                summaryChip(title: "Rooms", value: "\(appState.rooms.count)")
                summaryChip(title: "Layout", value: roomLayoutOption.rawValue)
                summaryChip(title: "Sync", value: SettingsManager.shared.syncMode.displayName)
                summaryChip(title: "Current Room", value: (appState.currentRoom ?? appState.minimizedRoom)?.name ?? "None")
                summaryChip(title: "Audio", value: appState.serverManager.audioTransmissionStatus)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private func summaryChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.gray)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
    }

    var body: some View {
        let roomsForDisplay = filteredRooms
        HStack(spacing: 0) {
            // Main Content
            VStack(spacing: 30) {
                // Header
                VStack(spacing: 10) {
                    Text("VoiceLink")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.top, 40)

                if !isAuthenticatedForRoomAccess {
                    authRequiredOverlay
                        .padding(.horizontal, 40)
                }

                mainWindowHeaderPanel

            // Error message
            if let error = appState.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal, 40)
            }

                // Room List
            VStack(alignment: .leading, spacing: 15) {
                Text("Available Rooms")
                    .font(.headline)
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Room Filters")
                        .font(.caption)
                        .foregroundColor(.gray)

                    HStack(spacing: 12) {
                        Label(roomFilterSummary, systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.82))
                        Spacer()
                        Text("Room > Filter or Command-Option 0-9")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }

                    TextField("Filter by server domain", text: $roomDomainFilter)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Filter rooms by server domain")
                        .accessibilityHint("Type part or all of a server domain to show rooms hosted on matching servers.")
                }

                if let minimized = appState.minimizedRoom {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Minimized Room: \(minimized.name)")
                                .foregroundColor(.white)
                                .font(.subheadline.weight(.semibold))
                            Text("You are still connected. Use Show Room to restore.")
                                .foregroundColor(.gray)
                                .font(.caption)
                        }
                        Spacer()
                        Button("Show Room") {
                            appState.restoreMinimizedRoom()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Leave") {
                            appState.leaveCurrentRoom()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .padding(10)
                    .background(Color.yellow.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
                    )
                    .cornerRadius(10)
                }

                ScrollView {
                    if roomLayoutOption == .list {
                        LazyVStack(spacing: 12) {
                            ForEach(roomsForDisplay) { room in
                                let canAdminRoom = appState.canManageRoom(room)
                                RoomCard(
                                    room: room,
                                    descriptionText: appState.displayDescription(for: room),
                                    roomHasActiveMedia: appState.roomHasActiveMusic[room.id] == true,
                                    isActiveRoom: appState.activeRoomId == room.id,
                                    isAdmin: canAdminRoom,
                                    onFocus: { appState.setFocusedRoom(room) }
                                ) {
                                    appState.joinOrShowRoom(room)
                                } onPreview: {
                                    PeekManager.shared.togglePreview(
                                        for: room,
                                        canPreview: SettingsManager.shared.canPreviewRoom(
                                            roomId: room.id,
                                            userCount: room.userCount,
                                            hasActiveMedia: appState.roomHasActiveMusic[room.id] == true
                                        )
                                    )
                                } onShare: {
                                    let roomURL = "https://voicelink.devinecreations.net/?room=\(room.id)"
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(roomURL, forType: .string)
                                    AppSoundManager.shared.playSound(.success)
                                } onOpenAdmin: {
                                    appState.currentScreen = .admin
                                } onCreateRoom: {
                                    appState.currentScreen = .createRoom
                                } onDeleteRoom: {
                                    appState.deleteRoomFromMenu(room)
                                } onOpenDetails: {
                                    selectedRoomDetails = room
                                } onOpenActionMenu: {
                                    selectedRoomActionRoom = room
                                    showRoomActionMenuSheet = true
                                }
                            }
                        }
                    } else if roomLayoutOption == .grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                            ForEach(roomsForDisplay) { room in
                                let canAdminRoom = appState.canManageRoom(room)
                                RoomCard(
                                    room: room,
                                    descriptionText: appState.displayDescription(for: room),
                                    roomHasActiveMedia: appState.roomHasActiveMusic[room.id] == true,
                                    isActiveRoom: appState.activeRoomId == room.id,
                                    isAdmin: canAdminRoom,
                                    onFocus: { appState.setFocusedRoom(room) }
                                ) {
                                    appState.joinOrShowRoom(room)
                                } onPreview: {
                                    PeekManager.shared.togglePreview(
                                        for: room,
                                        canPreview: SettingsManager.shared.canPreviewRoom(
                                            roomId: room.id,
                                            userCount: room.userCount,
                                            hasActiveMedia: appState.roomHasActiveMusic[room.id] == true
                                        )
                                    )
                                } onShare: {
                                    let roomURL = "https://voicelink.devinecreations.net/?room=\(room.id)"
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(roomURL, forType: .string)
                                    AppSoundManager.shared.playSound(.success)
                                } onOpenAdmin: {
                                    appState.currentScreen = .admin
                                } onCreateRoom: {
                                    appState.currentScreen = .createRoom
                                } onDeleteRoom: {
                                    appState.deleteRoomFromMenu(room)
                                } onOpenDetails: {
                                    selectedRoomDetails = room
                                } onOpenActionMenu: {
                                    selectedRoomActionRoom = room
                                    showRoomActionMenuSheet = true
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                Text("Room").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Users").frame(width: 70, alignment: .trailing)
                                Text("Status").frame(width: 90, alignment: .leading)
                                Text("Actions").frame(width: 170, alignment: .trailing)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 8)

                            ForEach(roomsForDisplay) { room in
                                let canAdminRoom = appState.canManageRoom(room)
                                RoomColumnRow(
                                    room: room,
                                    descriptionText: appState.displayDescription(for: room),
                                    roomHasActiveMedia: appState.roomHasActiveMusic[room.id] == true,
                                    isActiveRoom: appState.activeRoomId == room.id,
                                    isAdmin: canAdminRoom,
                                    onFocus: { appState.setFocusedRoom(room) }
                                ) {
                                    appState.joinOrShowRoom(room)
                                } onPreview: {
                                    PeekManager.shared.togglePreview(
                                        for: room,
                                        canPreview: SettingsManager.shared.canPreviewRoom(
                                            roomId: room.id,
                                            userCount: room.userCount,
                                            hasActiveMedia: appState.roomHasActiveMusic[room.id] == true
                                        )
                                    )
                                } onShare: {
                                    let roomURL = "https://voicelink.devinecreations.net/?room=\(room.id)"
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(roomURL, forType: .string)
                                    AppSoundManager.shared.playSound(.success)
                                } onOpenAdmin: {
                                    appState.currentScreen = .admin
                                } onCreateRoom: {
                                    appState.currentScreen = .createRoom
                                } onDeleteRoom: {
                                    appState.deleteRoomFromMenu(room)
                                } onOpenDetails: {
                                    selectedRoomDetails = room
                                } onOpenActionMenu: {
                                    selectedRoomActionRoom = room
                                    showRoomActionMenuSheet = true
                                }
                            }
                        }
                    }

                        if appState.rooms.isEmpty && appState.isConnected {
                            Text("No rooms available. Create one!")
                                .foregroundColor(.gray)
                                .padding()
                        } else if appState.rooms.isEmpty && !appState.isConnected {
                            Text("Connect to server to see rooms")
                                .foregroundColor(.gray)
                                .padding()
                        }
                    }
                }
                .frame(maxHeight: 300)
                .sheet(item: $selectedRoomDetails) { room in
                    RoomDetailsSheet(
                        room: room,
                        roomHasActiveMedia: appState.roomHasActiveMusic[room.id] == true,
                        isActiveRoom: appState.activeRoomId == room.id,
                        onJoin: { appState.joinOrShowRoom(room) },
                        onShare: {
                            let roomURL = "https://voicelink.devinecreations.net/?room=\(room.id)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(roomURL, forType: .string)
                            AppSoundManager.shared.playSound(.success)
                        },
                        onPreview: {
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
                    guard let room = notification.object as? Room else { return }
                    selectedRoomDetails = room
                }
                .onAppear {
                    if appState.isConnected {
                        appState.refreshRooms()
                        appState.refreshAdminCapabilities()
                    }
                }
                .onReceive(statusRefreshTimer) { _ in
                    guard appState.currentScreen == .mainMenu else { return }
                    guard appState.isConnected else { return }
                    appState.refreshRooms()
                    appState.refreshAdminCapabilities()
                }
                .onReceive(NotificationCenter.default.publisher(for: .roomFilterReset)) { _ in
                    resetRoomFilters()
                }
                .onReceive(NotificationCenter.default.publisher(for: .roomFilterScopeChanged)) { notification in
                    guard let value = notification.userInfo?["scope"] as? String else { return }
                    applyScopeShortcut(value)
                }
                .onReceive(NotificationCenter.default.publisher(for: .roomFilterSortChanged)) { notification in
                    guard let value = notification.userInfo?["sort"] as? String else { return }
                    applySortShortcut(value)
                }
                .onReceive(NotificationCenter.default.publisher(for: .roomFilterLayoutChanged)) { notification in
                    guard let value = notification.userInfo?["layout"] as? String else { return }
                    applyLayoutShortcut(value)
                }
                .sheet(isPresented: $showRoomActionMenuSheet) {
                    if let room = selectedRoomActionRoom {
                        RoomActionMenu(
                            room: room,
                            isInRoom: appState.activeRoomId == room.id,
                            isPresented: $showRoomActionMenuSheet
                        )
                        .presentationDetents([.medium, .large])
                    }
                }
                .sheet(isPresented: $showCreateInviteSheet) {
                    CreateAdminInviteView(isPresented: $showCreateInviteSheet)
                }
                .sheet(isPresented: $showServerStatusSheet) {
                    MainWindowServerStatusSheet(appState: appState)
                }
            }
            .padding(.horizontal, 40)

            // Action Buttons
            HStack(spacing: 20) {
                ActionButton(title: "Create Room", icon: "plus.circle.fill", color: .blue) {
                    appState.currentScreen = .createRoom
                }

                ActionButton(title: "Join or Search Rooms", icon: "link.circle.fill", color: .green) {
                    appState.openJoinRoomPanel()
                }
            }
            .padding(.horizontal, 40)

            // Account Button
            HStack {
                let authManager = AuthenticationManager.shared
                if authManager.authState == .authenticated {
                    if let user = authManager.currentUser {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading) {
                                Text(user.displayName)
                                    .foregroundColor(.white)
                                    .font(.subheadline)
                                if let instance = user.mastodonInstance {
                                    Text("@\(instance)")
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                            }
                            Spacer()
                            if adminManager.isAdmin || adminManager.adminRole == .admin || adminManager.adminRole == .owner {
                                Button("Server Administration") {
                                    appState.currentScreen = .admin
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Button("Invite Someone") {
                                showCreateInviteSheet = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Logout") {
                                authManager.logout()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(10)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Open Registration") {
                            openRegistrationPortal()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        ActionButton(title: "Login with Mastodon", icon: "person.circle.fill", color: .purple) {
                            appState.currentScreen = .login
                        }
                        HStack(spacing: 8) {
                            Button("Google") {
                                if let url = URL(string: "https://voicelink.devinecreations.net/auth/google") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Apple") {
                                if let url = URL(string: "https://voicelink.devinecreations.net/auth/apple") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("GitHub") {
                                if let url = URL(string: "https://voicelink.devinecreations.net/auth/github") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .onAppear {
                selectedServerFilter = "All Servers"
                roomScopeFilter = .all
                if !isAuthenticatedForRoomAccess && hasPendingAdminInvite {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        showAdminInviteSheet = true
                    }
                }
            }
            .sheet(isPresented: $showMastodonAuthSheet) {
                MastodonAuthView(isPresented: $showMastodonAuthSheet)
            }
            .sheet(isPresented: $showEmailAuthSheet) {
                EmailAuthView(
                    isPresented: $showEmailAuthSheet,
                    serverURL: effectiveAuthServerURL
                )
            }
            .sheet(isPresented: $showAdminInviteSheet) {
                AdminInviteAuthView(isPresented: $showAdminInviteSheet)
            }

            // Right Sidebar - Connection Health & Servers
            VStack(spacing: 16) {
                Spacer()

                // Settings tip at bottom of sidebar
                HStack(spacing: 10) {
                    Text("Settings: ⌘,")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.85))
                }
                .padding(.bottom, 8)
            }
            .frame(width: 280)
            .padding()
            .background(Color.black.opacity(0.2))
        }
    }
// MARK: - Room Card
struct RoomCard: View {
    @ObservedObject private var settings = SettingsManager.shared
    let room: Room
    var descriptionText: String? = nil
    let roomHasActiveMedia: Bool
    let isActiveRoom: Bool
    let isAdmin: Bool
    var onFocus: () -> Void = {}
    let onJoin: () -> Void
    var onPreview: () -> Void = {}
    var onShare: () -> Void = {}
    var onOpenAdmin: () -> Void = {}
    var onCreateRoom: () -> Void = {}
    var onDeleteRoom: () -> Void = {}
    var onOpenDetails: () -> Void = {}
    var onOpenActionMenu: () -> Void = {}

    var displayDescription: String {
        if let descriptionText {
            return descriptionText
        }
        let trimmed = room.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No description provided." : trimmed
    }

    var primaryActionLabel: String {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            return "Room Details"
        case .joinOrShow:
            return isActiveRoom ? "Show Room" : "Join"
        case .preview:
            return "Preview"
        case .share:
            return "Share"
        }
    }

    var primaryActionEffectText: String {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            return "opens room details"
        case .joinOrShow:
            return isActiveRoom ? "returns to your active room" : "joins this room"
        case .preview:
            return previewAvailable ? "starts room audio preview" : "opens room details because preview is unavailable"
        case .share:
            return "copies a room share link"
        }
    }

    var previewAvailable: Bool {
        settings.canPreviewRoom(roomId: room.id, userCount: room.userCount, hasActiveMedia: roomHasActiveMedia)
    }

    var mediaStatusText: String {
        roomHasActiveMedia ? "Media is playing." : "No media is playing."
    }

    var roomAccessibilitySummary: String {
        "\(room.name). \(displayDescription). Users \(room.userCount) of \(room.maxUsers). \(mediaStatusText)"
    }

    var showJoinActionSeparately: Bool {
        settings.defaultRoomPrimaryAction != .joinOrShow
    }

    func runPrimaryAction() {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            onOpenDetails()
        case .joinOrShow:
            onJoin()
        case .preview:
            if previewAvailable { onPreview() } else { onOpenDetails() }
        case .share:
            onShare()
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(room.name)
                        .font(.headline)
                        .foregroundColor(.white)

                    if room.isPrivate {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                }

                if settings.showRoomDescriptions {
                    Text(displayDescription)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                }

                if let hostedFrom = room.hostedFromLine {
                    Text(hostedFrom)
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.85))
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                Text("\(room.userCount)")
            }
            .foregroundColor(.white.opacity(0.6))
            .font(.caption)

            RoomActionSplitButton(
                primaryLabel: primaryActionLabel,
                isActiveRoom: isActiveRoom,
                isPrimaryDisabled: settings.defaultRoomPrimaryAction == .preview && !previewAvailable,
                primaryActionEffectText: primaryActionEffectText,
                onPrimaryAction: { runPrimaryAction() },
                onJoin: onJoin,
                onPreview: onPreview,
                onShare: onShare,
                onOpenDetails: onOpenDetails,
                onOpenAdmin: onOpenAdmin,
                onCreateRoom: onCreateRoom,
                onDeleteRoom: onDeleteRoom,
                onOpenActionMenu: onOpenActionMenu,
                roomId: room.id,
                roomCanPreview: previewAvailable,
                showJoinAction: showJoinActionSeparately,
                isPrimaryPreviewAction: settings.defaultRoomPrimaryAction == .preview,
                onPreviewHoldStart: {
                    PeekManager.shared.startHoldPreview(for: room, canPreview: previewAvailable)
                },
                onPreviewHoldEnd: {
                    PeekManager.shared.stopHoldPreview(for: room)
                },
                isAdmin: isAdmin
            )

            VStack(alignment: .trailing, spacing: 2) {
                Text(roomHasActiveMedia ? "Media: Active" : "Media: None")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.95))
                Text("Users: \(room.userCount)/\(room.maxUsers)")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.8))
                Text(displayDescription)
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.75))
                    .lineLimit(2)
            }
            .frame(maxWidth: 260, alignment: .trailing)
        }
        .padding()
        .background(Color.white.opacity(0.1))
        .cornerRadius(12)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onHover { hovering in
            if hovering { onFocus() }
        }
        .contextMenu {
            Button("Room Actions...") { onOpenActionMenu() }
            Divider()
            Button("Room Details") { onOpenDetails() }
            if showJoinActionSeparately {
                Button(isActiveRoom ? "Show Room" : "Join Room") { onJoin() }
            }
            Button("Open Jukebox") { NotificationCenter.default.post(name: .openRoomJukebox, object: nil) }
            Button("Preview Room Audio") {
                if previewAvailable { onPreview() } else { onOpenDetails() }
            }
            .disabled(!previewAvailable)
            Button("Share Room Link") { onShare() }
            Button("Copy Room ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(room.id, forType: .string)
            }
            Divider()
            Button("Open Server Administration") { onOpenAdmin() }
            Button("Create New Room") { onCreateRoom() }
            Button("Delete This Room", role: .destructive) { onDeleteRoom() }
                .disabled(!isAdmin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(roomAccessibilitySummary)
        .accessibilityHint("Primary button runs \(primaryActionLabel). Use room actions for more options.")
        .accessibilityAction(named: Text(primaryActionLabel)) { runPrimaryAction() }
        .accessibilityAction(named: Text("Preview Room Audio")) {
            if previewAvailable { onPreview() } else { onOpenDetails() }
        }
        .accessibilityAction(named: Text("Share Room Link")) { onShare() }
        .accessibilityAction(named: Text("Room Details")) { onOpenDetails() }
    }

}

struct MainWindowServerStatusSheet: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var adminManager = AdminServerManager.shared
    @State private var federationSettings: FederationSettings?
    @State private var isLoadingFederation = false
    @State private var isRefreshing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Server Status")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Refresh") {
                        Task { await refresh() }
                    }
                    .disabled(isRefreshing)
                    Button("Done") { dismiss() }
                }

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow(
                            "Status",
                            value: appState.serverStatus == AppState.ServerStatus.online
                                ? "Connected"
                                : appState.serverStatus == AppState.ServerStatus.connecting
                                    ? "Connecting"
                                    : "Offline"
                        )
                        statusRow("Base URL", value: appState.serverManager.baseURL ?? "Not connected")
                        statusRow("Server Label", value: appState.serverManager.connectedServer.isEmpty ? "Not available" : appState.serverManager.connectedServer)
                        statusRow("Local IP", value: appState.localIP)
                        statusRow("Sync Mode", value: SettingsManager.shared.syncMode.displayName)
                        statusRow("Audio Status", value: appState.serverManager.audioTransmissionStatus)
                    }
                }

                GroupBox("Statistics") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow("Rooms Loaded", value: "\(appState.rooms.count)")
                        statusRow("Current Room", value: (appState.currentRoom ?? appState.minimizedRoom)?.name ?? "None")
                        statusRow("Admin Role", value: adminManager.adminRole.rawValue.capitalized)
                        statusRow("Users", value: adminManager.serverStats.map { "\($0.activeUsers) active / \($0.totalUsers) total" } ?? "Not available")
                        statusRow("Rooms", value: adminManager.serverStats.map { "\($0.activeRooms) active / \($0.totalRooms) total" } ?? "Not available")
                        statusRow("Peak Users", value: adminManager.serverStats.map { "\($0.peakUsers)" } ?? "Not available")
                        statusRow("Messages per Minute", value: adminManager.serverStats.map { String(format: "%.2f", $0.messagesPerMinute) } ?? "Not available")
                        statusRow("Bandwidth", value: adminManager.serverStats.map { String(format: "%.2f", $0.bandwidthUsage) } ?? "Not available")
                        statusRow("Uptime", value: adminManager.serverStats.map { formatDuration(seconds: $0.uptime) } ?? "Not available")
                    }
                }

                GroupBox("Federation") {
                    VStack(alignment: .leading, spacing: 10) {
                        if isLoadingFederation {
                            ProgressView()
                        } else if federationSettings == nil {
                            statusRow("Status", value: "Unavailable")
                            statusRow("Details", value: "Federation settings could not be loaded from the current server.")
                        } else {
                            statusRow("Enabled", value: boolLabel(federationSettings?.enabled))
                            statusRow("Allow Incoming", value: boolLabel(federationSettings?.allowIncoming))
                            statusRow("Allow Outgoing", value: boolLabel(federationSettings?.allowOutgoing))
                            statusRow("Trusted Servers", value: federationSettings?.trustedServers.joined(separator: ", ").nilIfEmpty ?? "None")
                            statusRow("Blocked Servers", value: federationSettings?.blockedServers.joined(separator: ", ").nilIfEmpty ?? "None")
                            statusRow("Auto Accept Trusted", value: boolLabel(federationSettings?.autoAcceptTrusted))
                            statusRow("Require Approval", value: boolLabel(federationSettings?.requireApproval))
                        }
                    }
                }

                if let config = adminManager.serverConfig {
                    GroupBox("Server Config") {
                        VStack(alignment: .leading, spacing: 10) {
                            statusRow("Name", value: config.serverName)
                            statusRow("Description", value: config.serverDescription.nilIfEmpty ?? "Not available")
                            statusRow("Max Users", value: "\(config.maxUsers)")
                            statusRow("Max Rooms", value: "\(config.maxRooms)")
                            statusRow("Max Users Per Room", value: "\(config.maxUsersPerRoom)")
                            statusRow("Registration", value: boolLabel(config.registrationEnabled))
                            statusRow("Require Auth", value: boolLabel(config.requireAuth))
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 520)
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoadingFederation = true
        defer {
            isRefreshing = false
            isLoadingFederation = false
        }

        async let stats: Void = adminManager.fetchServerStats()
        async let config: Void = adminManager.fetchServerConfig()
        let federation = await adminManager.fetchFederationSettings()
        _ = await (stats, config)
        federationSettings = federation
    }

    @ViewBuilder
    private func statusRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.gray)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .foregroundColor(.white)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func boolLabel(_ value: Bool?) -> String {
        guard let value else { return "Not available" }
        return value ? "Enabled" : "Disabled"
    }

    private func formatDuration(seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RoomActionSplitButton: View {
    let primaryLabel: String
    let isActiveRoom: Bool
    let isPrimaryDisabled: Bool
    let primaryActionEffectText: String
    let onPrimaryAction: () -> Void
    let onJoin: () -> Void
    let onPreview: () -> Void
    let onShare: () -> Void
    let onOpenDetails: () -> Void
    let onOpenAdmin: () -> Void
    let onCreateRoom: () -> Void
    let onDeleteRoom: () -> Void
    let onOpenActionMenu: () -> Void
    let roomId: String
    let roomCanPreview: Bool
    let showJoinAction: Bool
    let isPrimaryPreviewAction: Bool
    let onPreviewHoldStart: () -> Void
    let onPreviewHoldEnd: () -> Void
    let isAdmin: Bool
    @State private var previewHoldActive = false
    @State private var previewHoldTriggered = false

    private func previewOrExplain() {
        if roomCanPreview {
            onPreview()
            return
        }
        AccessibilityManager.shared.announceStatus("Preview is unavailable. No active room audio is available or preview is disabled by policy.")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(primaryLabel) {
                if isPrimaryPreviewAction && previewHoldTriggered {
                    return
                }
                onPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .tint(isActiveRoom ? .green : .blue)
            .disabled(isPrimaryDisabled)
            .help("Default action \(primaryLabel). When pressed, this \(primaryActionEffectText). You can change it in Settings > General.")
            .accessibilityLabel("\(primaryLabel)")
            .accessibilityHint("Default action button. This \(primaryActionEffectText).")
            .onLongPressGesture(minimumDuration: 0.18, maximumDistance: 16, pressing: { pressing in
                guard isPrimaryPreviewAction else { return }
                if pressing {
                    guard !previewHoldActive else { return }
                    previewHoldActive = true
                    previewHoldTriggered = true
                    onPreviewHoldStart()
                } else if previewHoldActive {
                    previewHoldActive = false
                    onPreviewHoldEnd()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        previewHoldTriggered = false
                    }
                }
            }, perform: {})

            Menu {
                Button("Room Actions...") { onOpenActionMenu() }
                Divider()
                Button("Room Details") { onOpenDetails() }
                if showJoinAction {
                    Button(isActiveRoom ? "Show Room" : "Join Room") { onJoin() }
                }
                Button("Preview Room Audio") { previewOrExplain() }
                    .disabled(!roomCanPreview)
                    .accessibilityHint(roomCanPreview ? "Preview live room audio." : "Unavailable because room audio preview is currently disabled or there is no active room audio.")
                Button("Share Room Link") { onShare() }
                if isAdmin {
                    Divider()
                    Menu("Manage Room") {
                        Button("Open Server Administration") { onOpenAdmin() }
                        Button("Create New Room") { onCreateRoom() }
                        Button("Delete This Room", role: .destructive) { onDeleteRoom() }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background((isActiveRoom ? Color.green : Color.blue).opacity(0.8))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Room actions menu")
            .accessibilityHint("Open room details, join or show, preview, and share actions.")
            .help("Full room actions menu. VoiceOver users can also open the actions menu with VO+Shift+M.")
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct RoomColumnRow: View {
    @ObservedObject private var settings = SettingsManager.shared
    let room: Room
    var descriptionText: String? = nil
    let roomHasActiveMedia: Bool
    let isActiveRoom: Bool
    let isAdmin: Bool
    var onFocus: () -> Void = {}
    let onJoin: () -> Void
    var onPreview: () -> Void = {}
    var onShare: () -> Void = {}
    var onOpenAdmin: () -> Void = {}
    var onCreateRoom: () -> Void = {}
    var onDeleteRoom: () -> Void = {}
    var onOpenDetails: () -> Void = {}
    var onOpenActionMenu: () -> Void = {}

    var primaryLabel: String {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            return "Room Details"
        case .joinOrShow:
            return isActiveRoom ? "Show Room" : "Join"
        case .preview:
            return "Preview"
        case .share:
            return "Share"
        }
    }

    var primaryActionEffectText: String {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            return "opens room details"
        case .joinOrShow:
            return isActiveRoom ? "returns to your active room" : "joins this room"
        case .preview:
            return previewAvailable ? "starts room audio preview" : "opens room details because preview is unavailable"
        case .share:
            return "copies a room share link"
        }
    }

    var displayDescription: String {
        descriptionText ?? (room.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No description provided." : room.description)
    }

    var mediaStatusText: String {
        roomHasActiveMedia ? "Media is playing." : "No media is playing."
    }

    var previewAvailable: Bool {
        settings.canPreviewRoom(roomId: room.id, userCount: room.userCount, hasActiveMedia: roomHasActiveMedia)
    }

    var roomAccessibilitySummary: String {
        "\(room.name). \(displayDescription). Users \(room.userCount) of \(room.maxUsers). \(mediaStatusText)"
    }

    var showJoinActionSeparately: Bool {
        settings.defaultRoomPrimaryAction != .joinOrShow
    }

    func runPrimaryAction() {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            onOpenDetails()
        case .joinOrShow:
            onJoin()
        case .preview:
            if previewAvailable { onPreview() } else { onOpenDetails() }
        case .share:
            onShare()
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .foregroundColor(.white)
                    .font(.subheadline.weight(.semibold))
                Text(displayDescription)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                if let hostedFrom = room.hostedFromLine {
                    Text(hostedFrom)
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(room.userCount)")
                .frame(width: 70, alignment: .trailing)
                .foregroundColor(.white.opacity(0.75))
                .font(.caption)

            Text(isActiveRoom ? "In room" : "Available")
                .frame(width: 90, alignment: .leading)
                .foregroundColor(isActiveRoom ? .green : .gray)
                .font(.caption)

            Text(roomHasActiveMedia ? "Media" : "No Media")
                .frame(width: 70, alignment: .leading)
                .foregroundColor(roomHasActiveMedia ? .yellow : .gray)
                .font(.caption2)

            RoomActionSplitButton(
                primaryLabel: primaryLabel,
                isActiveRoom: isActiveRoom,
                isPrimaryDisabled: settings.defaultRoomPrimaryAction == .preview && !previewAvailable,
                primaryActionEffectText: primaryActionEffectText,
                onPrimaryAction: { runPrimaryAction() },
                onJoin: onJoin,
                onPreview: onPreview,
                onShare: onShare,
                onOpenDetails: onOpenDetails,
                onOpenAdmin: onOpenAdmin,
                onCreateRoom: onCreateRoom,
                onDeleteRoom: onDeleteRoom,
                onOpenActionMenu: onOpenActionMenu,
                roomId: room.id,
                roomCanPreview: previewAvailable,
                showJoinAction: showJoinActionSeparately,
                isPrimaryPreviewAction: settings.defaultRoomPrimaryAction == .preview,
                onPreviewHoldStart: {
                    PeekManager.shared.startHoldPreview(for: room, canPreview: previewAvailable)
                },
                onPreviewHoldEnd: {
                    PeekManager.shared.stopHoldPreview(for: room)
                },
                isAdmin: isAdmin
            )
            .frame(width: 170, alignment: .trailing)
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onHover { hovering in
            if hovering { onFocus() }
        }
        .contextMenu {
            Button("Room Actions...") { onOpenActionMenu() }
            Divider()
            Button("Room Details") { onOpenDetails() }
            if showJoinActionSeparately {
                Button(isActiveRoom ? "Show Room" : "Join Room") { onJoin() }
            }
            Button("Open Jukebox") { NotificationCenter.default.post(name: .openRoomJukebox, object: nil) }
            Button("Preview Room Audio") {
                if previewAvailable { onPreview() } else { onOpenDetails() }
            }
            .disabled(!previewAvailable)
            Button("Share Room Link") { onShare() }
            Button("Copy Room ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(room.id, forType: .string)
            }
            Divider()
            Button("Open Server Administration") { onOpenAdmin() }
            Button("Create New Room") { onCreateRoom() }
            Button("Delete This Room", role: .destructive) { onDeleteRoom() }
                .disabled(!isAdmin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(roomAccessibilitySummary)
        .accessibilityHint("Primary button runs \(primaryLabel). Use VoiceOver plus Shift plus M for the actions menu.")
        .accessibilityAction(named: Text(primaryLabel)) { runPrimaryAction() }
        .accessibilityAction(named: Text("Preview Room Audio")) {
            if previewAvailable { onPreview() } else { onOpenDetails() }
        }
        .accessibilityAction(named: Text("Share Room Link")) { onShare() }
        .accessibilityAction(named: Text("Room Details")) { onOpenDetails() }
    }
}

struct RoomDetailsSheet: View {
    let room: Room
    let roomHasActiveMedia: Bool
    let isActiveRoom: Bool
    let onJoin: () -> Void
    let onShare: () -> Void
    let onPreview: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var holdPreviewActive = false
    @State private var holdPreviewTriggered = false

    private var canPreviewFromSheet: Bool {
        SettingsManager.shared.canPreviewRoom(
            roomId: room.id,
            userCount: room.userCount,
            hasActiveMedia: roomHasActiveMedia
        )
    }

    private var totalUsersLabel: String {
        let liveCount = ServerManager.shared.currentRoomUsers.count
        let effectiveCount = isActiveRoom && liveCount > 0 ? liveCount : room.userCount
        return "Total users in room: \(effectiveCount) of \(room.maxUsers)"
    }

    private var mediaStatusLabel: String {
        roomHasActiveMedia ? "Playing" : "Not playing"
    }

    private var serverAnnouncementTitle: String {
        roomAnnouncementText.contains("\n\n") ? "Welcome and Message of the Day" : "Message of the Day"
    }

    private var roomAnnouncementText: String {
        guard let config = ServerManager.shared.serverConfig else { return "" }
        let welcome = config.welcomeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let motd = config.motd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let motdSettings = config.motdSettings

        if motdSettings.appendToWelcomeMessage {
            let parts = [welcome, motd].filter { !$0.isEmpty }
            return parts.joined(separator: "\n\n")
        }

        if motdSettings.enabled && motdSettings.showBeforeJoin && !motd.isEmpty {
            return motd
        }

        return welcome
    }

    private var shouldShowAnnouncement: Bool {
        let text = roomAnnouncementText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }

    private var uptimeLabel: String {
        if let uptimeSeconds = room.uptimeSeconds {
            return formatDuration(seconds: uptimeSeconds)
        }
        if let createdAt = room.createdAt {
            return formatDuration(seconds: max(0, Int(Date().timeIntervalSince(createdAt))))
        }
        return "Unknown"
    }

    private var lastActivityLabel: String {
        guard let activityDate = room.lastActivityAt else {
            return "No recent room activity recorded"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: activityDate, relativeTo: Date())
        if let user = room.lastActiveUsername?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            return "\(user) was last active \(relative)"
        }
        return "Last activity was \(relative)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(room.name).font(.title2.weight(.bold))
            Text(room.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No description provided." : room.description)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(totalUsersLabel)
                Text("Access level: \(room.isPrivate ? "Private room" : "Public room")")
                Text("Media status: \(mediaStatusLabel)")
                    .italic()
                Text("Uptime: \(uptimeLabel)")
                Text("Last activity: \(lastActivityLabel)")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if let hostedFrom = room.hostedFromLine {
                Text(hostedFrom)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if shouldShowAnnouncement {
                VStack(alignment: .leading, spacing: 8) {
                    Text(serverAnnouncementTitle)
                        .font(.headline)
                    Text(roomAnnouncementText)
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.88))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.blue.opacity(0.35), lineWidth: 1)
                )
                .cornerRadius(10)
            }

            HStack(spacing: 10) {
                Button(isActiveRoom ? "Return to Room" : "Join Room") { onJoin(); dismiss() }
                    .buttonStyle(.borderedProminent)
                Button("Share") { onShare() }
                    .buttonStyle(.bordered)
                Button("Preview / Peek") {
                    if holdPreviewTriggered { return }
                    onPreview()
                }
                    .buttonStyle(.bordered)
                    .disabled(!canPreviewFromSheet)
                    .onLongPressGesture(minimumDuration: 0.18, maximumDistance: 16, pressing: { pressing in
                        if pressing {
                            guard !holdPreviewActive else { return }
                            holdPreviewActive = true
                            holdPreviewTriggered = true
                            PeekManager.shared.startHoldPreview(for: room, canPreview: canPreviewFromSheet)
                        } else if holdPreviewActive {
                            holdPreviewActive = false
                            PeekManager.shared.stopHoldPreview(for: room)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                holdPreviewTriggered = false
                            }
                        }
                    }, perform: {})
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 300)
    }

    private func formatDuration(seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Action Button
struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(width: 100, height: 80)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Placeholder Views
struct CreateRoomView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var authManager = AuthenticationManager.shared
    @ObservedObject private var adminManager = AdminServerManager.shared
    @State private var roomName = ""
    @State private var roomDescription = ""
    @State private var isPrivate = false
    @State private var password = ""
    @State private var roomType: String = "standard"
    @State private var maxUsers: Int = 50
    @State private var inviteOnly: Bool = false
    @State private var enableMediaAutoPlay: Bool = true
    @State private var moderationNotes = ""

    private var isLoggedIn: Bool {
        authManager.authState == .authenticated && authManager.currentUser != nil
    }

    private var canCreateAdminType: Bool {
        adminManager.isAdmin || adminManager.adminRole == .admin || adminManager.adminRole == .owner
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Create Room")
                .font(.largeTitle)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 15) {
                TextField("Room Name", text: $roomName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)

                TextField("Description (optional)", text: $roomDescription)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)

                Toggle("Private Room", isOn: $isPrivate)
                    .foregroundColor(.white)
                    .frame(width: 350)
                    .disabled(!isLoggedIn)

                if !isLoggedIn {
                    Text("Guest mode limits: 1 room at a time, public room only, max \(RoomManager.guestRoomMaxMembers) users.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(width: 350, alignment: .leading)
                }

                if isPrivate {
                    SecureField("Room Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 350)
                }

                if isLoggedIn {
                    Picker("Room Type", selection: $roomType) {
                        Text("Standard").tag("standard")
                        Text("Private").tag("private")
                        Text("Moderated").tag("moderated")
                        if canCreateAdminType {
                            Text("Admin").tag("admin")
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 350)
                    .onChange(of: roomType) { newValue in
                        if newValue == "private" || newValue == "moderated" {
                            isPrivate = true
                        }
                    }

                    Stepper("Max Users: \(maxUsers)", value: $maxUsers, in: 2...500, step: 1)
                        .foregroundColor(.white)
                        .frame(width: 350)

                    Toggle("Invite Only", isOn: $inviteOnly)
                        .foregroundColor(.white)
                        .frame(width: 350)

                    Toggle("Enable Auto-Play Room Media", isOn: $enableMediaAutoPlay)
                        .foregroundColor(.white)
                        .frame(width: 350)

                    if roomType == "moderated" || roomType == "admin" {
                        TextField("Moderation notes (optional)", text: $moderationNotes)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 350)
                    }
                }
            }

            HStack(spacing: 15) {
                Button("Create") {
                    if !isLoggedIn && !RoomManager.shared.canGuestCreateRoom {
                        appState.errorMessage = "Guest limit reached. Sign in to create more rooms."
                        return
                    }

                    let effectiveRoomType = isLoggedIn ? roomType : "guest"
                    let effectiveInviteOnly = isLoggedIn ? inviteOnly : false
                    let effectiveMediaAutoPlay = isLoggedIn ? enableMediaAutoPlay : true
                    let effectiveMaxUsers = isLoggedIn
                        ? maxUsers
                        : min(maxUsers, RoomManager.guestRoomMaxMembers)
                    let effectivePrivate = isLoggedIn ? isPrivate : false

                    var metadata: [String: Any] = [
                        "maxUsers": effectiveMaxUsers,
                        "roomType": effectiveRoomType,
                        "inviteOnly": effectiveInviteOnly,
                        "mediaAutoPlay": effectiveMediaAutoPlay
                    ]
                    if isLoggedIn, let currentUser = authManager.currentUser {
                        metadata["createdBy"] = currentUser.username
                        metadata["createdByRole"] = adminManager.adminRole.rawValue
                    }
                    if !moderationNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        metadata["moderationNotes"] = moderationNotes
                    }

                    // Create room via server
                    appState.serverManager.createRoom(
                        name: roomName,
                        description: roomDescription,
                        isPrivate: effectivePrivate,
                        password: effectivePrivate ? password : nil,
                        metadata: metadata
                    )
                    // Go back to main menu - room will appear in list
                    appState.pendingCreateRoomName = ""
                    appState.currentScreen = .mainMenu
                }
                .buttonStyle(.borderedProminent)
                .disabled(roomName.isEmpty || !appState.isConnected)

                Button("Cancel") {
                    appState.pendingCreateRoomName = ""
                    appState.currentScreen = .mainMenu
                }
                .buttonStyle(.bordered)
            }

            if !appState.isConnected {
                Text("Connect to server to create rooms")
                    .foregroundColor(.orange)
                    .font(.caption)
            }
        }
        .onAppear {
            if roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !appState.pendingCreateRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                roomName = appState.pendingCreateRoomName
            }
        }
    }
}

struct JoinRoomView: View {
    @EnvironmentObject var appState: AppState
    @State private var roomCode = ""

    private var query: String {
        roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredRooms: [Room] {
        let q = query.lowercased()
        guard !q.isEmpty else { return appState.rooms }
        return appState.rooms.filter {
            $0.id.lowercased().contains(q)
            || $0.name.lowercased().contains(q)
            || $0.description.lowercased().contains(q)
            || ($0.hostedFromLine?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Join or Search Rooms")
                .font(.largeTitle)
                .foregroundColor(.white)

            Text("Use room ID, room name, or keywords. Search runs against the backend room list across connected public servers.")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)

            TextField("Room ID, name, or keyword", text: $roomCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 520)
                .onSubmit {
                    _ = appState.joinRoomByCodeOrName(roomCode)
                }

            HStack(spacing: 10) {
                Button("Join Match") {
                    _ = appState.joinRoomByCodeOrName(roomCode)
                }
                .buttonStyle(.borderedProminent)
                .disabled(query.isEmpty)

                Button("Search Servers") {
                    appState.refreshRooms()
                }
                .buttonStyle(.bordered)

                Button("Create Room with This Name") {
                    let name = query.isEmpty ? "New Room" : query
                    appState.pendingCreateRoomName = name
                    appState.currentScreen = .createRoom
                }
                .buttonStyle(.bordered)

                Button("Back") {
                    appState.currentScreen = .mainMenu
                }
                .buttonStyle(.bordered)
            }

            if filteredRooms.isEmpty {
                VStack(spacing: 8) {
                    Text("No rooms found.")
                        .foregroundColor(.gray)
                    if !query.isEmpty {
                        Text("Create \"\(query)\" or refresh from connected servers.")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                }
                .padding(.top, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredRooms.prefix(80)) { room in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(room.name)
                                        .foregroundColor(.white)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(room.id) • \(room.userCount)/\(room.maxUsers)")
                                        .foregroundColor(.gray)
                                        .font(.caption2)
                                    if let hosted = room.hostedFromLine {
                                        Text(hosted)
                                            .foregroundColor(.gray.opacity(0.9))
                                            .font(.caption2)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Button(appState.activeRoomId == room.id ? "Show" : "Join") {
                                    appState.setFocusedRoom(room)
                                    appState.joinOrShowRoom(room)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(10)
                        }
                    }
                }
                .frame(width: 620, height: 300)
            }
        }
        .onAppear {
            if roomCode.isEmpty, let focused = appState.focusedRoomForQuickJoin() {
                roomCode = focused.name
            }
        }
    }
}

struct VoiceChatView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var messagingManager = MessagingManager.shared
    @ObservedObject var adminManager = AdminServerManager.shared
    @ObservedObject var roomLockManager = RoomLockManager.shared
    @State private var isMuted = false
    @State private var isDeafened = false
    @State private var messageText = ""
    @State private var showChat = true
    @State private var showRoomActionsSheet = false
    @State private var pendingEscapeTimestamp: Date?
    @State private var escapeKeyMonitor: Any?

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

    var body: some View {
        HSplitView {
            // Left side - Users and Voice Controls
            VStack {
                // Room Header
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
                                NotificationCenter.default.post(name: .reopenRoomDetailsSheet, object: room)
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

                // Users in room
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Users in Room")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(visibleRoomUsers.count + 1)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            // Show yourself
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

                            // Show other users from server
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

                // Voice Controls
                HStack(spacing: 30) {
                    VoiceControlButton(icon: isMuted ? "mic.slash.fill" : "mic.fill",
                                      label: isMuted ? "Unmute Microphone" : "Mute Microphone",
                                      isActive: !isMuted) {
                        isMuted.toggle()
                        appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
                        AppSoundManager.shared.playSound(isMuted ? .toggleOff : .toggleOn)
                        // Announce state change
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
                        // Announce state change
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

                // Keyboard shortcuts hint
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

            // Right side - Chat Panel
            if showChat {
                VStack(spacing: 0) {
                    // Chat header
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                        Text("Room Chat")
                            .font(.headline)
                        Spacer()
                        if messagingManager.totalUnreadCount > 0 {
                            Text("\(messagingManager.totalUnreadCount)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .cornerRadius(10)
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.3))

                    // Messages list
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(messagingManager.messages) { message in
                                    ChatMessageRow(message: message)
                                        .id(message.id)
                                }
                            }
                            .padding()
                        }
                        .onChange(of: messagingManager.messages.count) { _ in
                            if let lastMessage = messagingManager.messages.last {
                                withAnimation {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                    }

                    // Message input
                    HStack(spacing: 8) {
                        TextField(appState.serverStatus == .online ? "Type a message..." : "Connect to send messages", text: $messageText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(appState.serverStatus != .online || appState.currentRoom == nil)
                            .onSubmit {
                                sendMessage()
                            }

                        Button(action: sendMessage) {
                            HStack(spacing: 4) {
                                Text("Send")
                                    .fontWeight(.medium)
                                Image(systemName: "paperplane.fill")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .disabled(messageText.isEmpty || appState.serverStatus != .online || appState.currentRoom == nil)
                        .buttonStyle(.borderedProminent)
                        .tint((messageText.isEmpty || appState.serverStatus != .online) ? .gray : .blue)
                    }
                    .padding()
                    .background(Color.black.opacity(0.3))
                }
                .frame(minWidth: 250, idealWidth: 300)
                .background(Color.black.opacity(0.2))
            }
        }
        .onAppear {
            // Ensure room audio path is active when chat view is visible.
            appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
            setupEscapeMonitor()
        }
        .onDisappear {
            tearDownEscapeMonitor()
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
        messagingManager.sendRoomMessage(messageText)
        AppSoundManager.shared.playSound(.messageSent)
        messageText = ""
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
struct ChatMessageRow: View {
    let message: MessagingManager.ChatMessage
    @State private var copiedNotice = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Avatar placeholder
            Circle()
                .fill(avatarColor)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(message.senderName.prefix(1)).uppercased())
                        .font(.caption)
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.senderName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(message.type == .system ? .gray : .white)

                    Text(formatTime(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Text(message.content)
                    .font(.body)
                    .foregroundColor(message.type == .system ? .gray : .white)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                copiedNotice = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.senderName). \(message.content)")
        .accessibilityHint("Message sent at \(formatTime(message.timestamp)). Open context menu for actions.")
    }

    private var avatarColor: Color {
        if message.type == .system {
            return .gray
        }
        // Generate consistent color from sender ID
        let hash = message.senderId.hashValue
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]
        return colors[abs(hash) % colors.count]
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct UserRow: View {
    let userId: String
    let username: String
    let isMuted: Bool
    let isDeafened: Bool
    let isSpeaking: Bool
    var isCurrentUser: Bool = false
    var roomUser: RoomUser? = nil
    var roomName: String? = nil
    var connectedServerName: String? = nil

    @State private var showControls = false
    @State private var showMonitoringWarning = false
    @State private var showProfileSheet = false
    @State private var userVolume: Double = 1.0
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var audioControl = UserAudioControlManager.shared
    @ObservedObject private var monitor = LocalMonitorManager.shared
    @ObservedObject private var serverManager = ServerManager.shared
    @State private var shareInProgress = false

    private var resolvedVolume: Double {
        if isCurrentUser {
            return settings.inputVolume
        }
        return Double(audioControl.getVolume(for: userId))
    }

    private var isUserMuted: Bool {
        if isCurrentUser { return false }
        return audioControl.isMuted(userId)
    }

    private var isSoloed: Bool {
        if isCurrentUser { return monitor.isMonitoring }
        return audioControl.isSolo(userId)
    }

    private var isRoomAudioActive: Bool {
        serverManager.activeRoomId != nil || serverManager.isAudioTransmitting
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack {
                // Speaking indicator
                Circle()
                    .fill(isSpeaking ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)

                Text(username)
                    .foregroundColor(.white)

                Spacer()

                if isMuted {
                    Image(systemName: "mic.slash.fill")
                        .foregroundColor(.red)
                }
                if isDeafened {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundColor(.red)
                }

                // Expand/collapse button with explicit accessible labels.
                Button(action: { showControls.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showControls ? "chevron.up" : "chevron.down")
                            .foregroundColor(.white.opacity(0.7))
                        Text(showControls ? "Hide Audio Controls for User" : "Show Audio Controls for User")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showControls ? "Hide Audio Controls for User" : "Show Audio Controls for User")
                .accessibilityHint("Toggles per-user audio controls for \(username)")
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .contextMenu {
                Button(action: {
                    // TODO: Implement whisper mode
                    print("Whisper to \(username)")
                }) {
                    Label("Whisper", systemImage: "mic.badge.plus")
                }

                Button(action: {
                    MessagingManager.shared.sendDirectMessage(
                        to: username,
                        username: username,
                        content: "Hi \(username)"
                    )
                }) {
                    Label("Send Direct Message", systemImage: "message")
                }

                Button(action: {
                    sendFileToUser()
                }) {
                    Label("Send File", systemImage: "doc")
                }

                Button(action: {
                    shareProtectedLinkToUser(keepForever: false)
                }) {
                    Label("Share Protected Link (Expires)", systemImage: "link.badge.plus")
                }

                Button(action: {
                    shareProtectedLinkToUser(keepForever: true)
                }) {
                    Label("Share Protected Link (Keep Forever)", systemImage: "link.circle")
                }
                .disabled(shareInProgress)

                Divider()

                Button(action: {
                    showProfileSheet = true
                }) {
                    Label("View Profile", systemImage: "person.circle")
                }
            }

            // Expandable audio controls
            if showControls {
                VStack(spacing: 8) {
                    // Volume slider
                    HStack {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        Slider(
                            value: Binding(
                                get: { resolvedVolume },
                                set: { newValue in
                                    if isCurrentUser {
                                        settings.inputVolume = newValue
                                        settings.saveSettings()
                                    } else {
                                        audioControl.setVolume(for: userId, volume: Float(newValue))
                                    }
                                }
                            ),
                            in: 0...1
                        )
                            .frame(maxWidth: .infinity)
                        Text("\(Int(resolvedVolume * 100))%")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 35)
                    }

                    if isCurrentUser {
                        Text("This slider controls your microphone input level.")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }

                    // Mute and Solo buttons
                    HStack(spacing: 12) {
                        Button(action: {
                            if !isCurrentUser {
                                audioControl.toggleMute(for: userId)
                            }
                        }) {
                            HStack {
                                Image(systemName: isUserMuted ? "speaker.slash.fill" : "speaker.fill")
                                Text(isUserMuted ? "Unmute" : "Mute")
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isUserMuted ? Color.red.opacity(0.3) : Color.gray.opacity(0.2))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .disabled(isCurrentUser)

                        Button(action: {
                            if isCurrentUser {
                                if monitor.isMonitoring {
                                    monitor.toggleMonitoring()
                                } else {
                                    showMonitoringWarning = true
                                }
                            } else {
                                audioControl.toggleSolo(for: userId)
                            }
                        }) {
                            HStack {
                                Image(systemName: isSoloed ? "ear.fill" : "ear")
                                Text(isCurrentUser ? (isSoloed ? "Stop Monitor" : "Monitor") : (isSoloed ? "Unsolo" : "Solo"))
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSoloed ? Color.yellow.opacity(0.3) : Color.gray.opacity(0.2))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }

                    if isCurrentUser {
                        Text("You cannot mute yourself in this list. Use main room mute controls. Monitor lets you hear your current input device and may cause feedback if speakers are active.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.02))
            }
        }
        .cornerRadius(8)
        .confirmationDialog(
            "Enable self monitoring?",
            isPresented: $showMonitoringWarning,
            titleVisibility: .visible
        ) {
            Button("Enable Monitoring") {
                monitor.toggleMonitoring()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This plays your current input device back to your selected output device. Use headphones to avoid feedback.")
        }
        .sheet(isPresented: $showProfileSheet) {
            UserProfileSheet(
                userId: userId,
                username: username,
                isCurrentUser: isCurrentUser,
                roomUser: roomUser,
                roomName: roomName,
                connectedServerName: connectedServerName,
                isRoomAudioActive: isRoomAudioActive,
                isUserMuted: isUserMuted,
                isSoloed: isSoloed,
                monitorIsActive: monitor.isMonitoring,
                onDirectMessage: {
                    MessagingManager.shared.sendDirectMessage(
                        to: username,
                        username: username,
                        content: "Hi \(username)"
                    )
                },
                onSendFile: {
                    sendFileToUser()
                },
                onShareExpiringLink: {
                    shareProtectedLinkToUser(keepForever: false)
                },
                onSharePermanentLink: {
                    shareProtectedLinkToUser(keepForever: true)
                },
                onToggleMute: {
                    if !isCurrentUser {
                        audioControl.toggleMute(for: userId)
                    }
                },
                onToggleSolo: {
                    if !isCurrentUser {
                        audioControl.toggleSolo(for: userId)
                    }
                },
                onToggleMonitor: {
                    if isCurrentUser {
                        if monitor.isMonitoring {
                            monitor.toggleMonitoring()
                        } else {
                            showMonitoringWarning = true
                        }
                    }
                }
            )
        }
        .accessibilityAction(named: Text(showControls ? "Hide Audio Controls for User" : "Show Audio Controls for User")) {
            showControls.toggle()
        }
    }

    private func sendFileToUser() {
        FileTransferManager.shared.showFilePicker { url in
            guard let url else { return }
            FileTransferManager.shared.sendFileToDirect(
                url: url,
                recipientId: username,
                recipientName: username
            )
        }
    }

    private func shareProtectedLinkToUser(keepForever: Bool) {
        FileTransferManager.shared.showFilePicker { url in
            guard let url else { return }
            shareInProgress = true
            Task {
                defer {
                    DispatchQueue.main.async { shareInProgress = false }
                }
                do {
                    let link = try await CopyPartyManager.shared.uploadFileAndCreateProtectedLink(
                        from: url,
                        to: "/uploads/\(username)",
                        keepForever: keepForever,
                        expiryHours: keepForever ? nil : CopyPartyManager.shared.config.defaultExternalLinkExpiryHours
                    )
                    DispatchQueue.main.async {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.url, forType: .string)
                        let expiryText = link.expiresAt.map { " Expires \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
                        let body = "Protected link copied to clipboard for \(self.username).\(expiryText)"
                        MessagingManager.shared.sendSystemMessage(body)
                        MessagingManager.shared.sendDirectMessage(
                            to: self.username,
                            username: self.username,
                            content: "Secure file link: \(link.url)"
                        )
                    }
                } catch {
                    DispatchQueue.main.async {
                        MessagingManager.shared.sendSystemMessage("Protected link share failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

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
    let onShareExpiringLink: () -> Void
    let onSharePermanentLink: () -> Void
    let onToggleMute: () -> Void
    let onToggleSolo: () -> Void
    let onToggleMonitor: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var authManager = AuthenticationManager.shared

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
                        Button("Send Direct Message") {
                            onDirectMessage()
                        }
                        Button("Send File") {
                            onSendFile()
                        }
                        Button("Copy User ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(userId, forType: .string)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Share Expiring Link") {
                            onShareExpiringLink()
                        }
                        Button("Share Permanent Link") {
                            onSharePermanentLink()
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
            UserDefaults.standard.set(syncMode.rawValue, forKey: "syncMode")
            NotificationCenter.default.post(name: .syncModeChanged, object: syncMode)
        }
    }
    @Published var showPrivateMemberRooms: Bool = true
    @Published var showFederatedRooms: Bool = true
    @Published var showLocalOnlyRooms: Bool = true
    @Published var managedFederationVisibility: [String: Bool] = [:]
    @Published var customFederationServers: [CustomFederationServer] = []

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
    @Published var openMainWindowOnLaunch: Bool = true
    @Published var confirmBeforeQuit: Bool = false
    @Published var confirmBeforeDeletingRooms: Bool = true
    @Published var expandServerStatusByDefault: Bool = true
    @Published var showRoomDescriptions: Bool = true
    @Published var allowPreviewWhenMediaActive: Bool = true
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

    // Profile Settings
    @Published var userNickname: String = ""
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
        if let mode = UserDefaults.standard.string(forKey: "syncMode"),
           let syncMode = SyncMode(rawValue: mode) {
            self.syncMode = syncMode
        }
        showPrivateMemberRooms = UserDefaults.standard.object(forKey: "showPrivateMemberRooms") as? Bool ?? true
        showFederatedRooms = UserDefaults.standard.object(forKey: "showFederatedRooms") as? Bool ?? true
        showLocalOnlyRooms = UserDefaults.standard.object(forKey: "showLocalOnlyRooms") as? Bool ?? true
        managedFederationVisibility = UserDefaults.standard.dictionary(forKey: "managedFederationVisibility") as? [String: Bool] ?? [:]
        if let data = UserDefaults.standard.data(forKey: "customFederationServers"),
           let decoded = try? JSONDecoder().decode([CustomFederationServer].self, from: data) {
            customFederationServers = decoded
        } else {
            customFederationServers = []
        }

        if let savedInputDevice = UserDefaults.standard.string(forKey: "inputDevice"), !savedInputDevice.isEmpty {
            inputDevice = savedInputDevice
        }

        if let savedOutputDevice = UserDefaults.standard.string(forKey: "outputDevice"), !savedOutputDevice.isEmpty {
            outputDevice = savedOutputDevice
        }

        inputVolume = UserDefaults.standard.double(forKey: "inputVolume")
        if inputVolume == 0 { inputVolume = 0.8 }

        outputVolume = UserDefaults.standard.double(forKey: "outputVolume")
        if outputVolume == 0 { outputVolume = 0.8 }
        confirmBeforeDeletingRooms = UserDefaults.standard.object(forKey: "confirmBeforeDeletingRooms") as? Bool ?? true

        noiseSuppression = UserDefaults.standard.bool(forKey: "noiseSuppression")
        echoCancellation = UserDefaults.standard.bool(forKey: "echoCancellation")
        autoGainControl = UserDefaults.standard.bool(forKey: "autoGainControl")
        autoConnect = UserDefaults.standard.bool(forKey: "autoConnect")
        preferLocalServer = UserDefaults.standard.bool(forKey: "preferLocalServer")
        pttEnabled = UserDefaults.standard.bool(forKey: "pttEnabled")
        spatialAudioEnabled = UserDefaults.standard.bool(forKey: "spatialAudioEnabled")

        // UI settings
        showAudioControlsOnStartup = UserDefaults.standard.object(forKey: "showAudioControlsOnStartup") as? Bool ?? true
        if let value = UserDefaults.standard.string(forKey: "closeButtonBehavior"),
           let parsed = CloseButtonBehavior(rawValue: value) {
            closeButtonBehavior = parsed
        } else {
            closeButtonBehavior = .goToMainThenHide
        }
        openMainWindowOnLaunch = UserDefaults.standard.object(forKey: "openMainWindowOnLaunch") as? Bool ?? true
        confirmBeforeQuit = UserDefaults.standard.object(forKey: "confirmBeforeQuit") as? Bool ?? false
        expandServerStatusByDefault = UserDefaults.standard.object(forKey: "expandServerStatusByDefault") as? Bool ?? true
        showRoomDescriptions = UserDefaults.standard.object(forKey: "showRoomDescriptions") as? Bool ?? true
        allowPreviewWhenMediaActive = UserDefaults.standard.object(forKey: "allowPreviewWhenMediaActive") as? Bool ?? true
        previewSoundCuesEnabled = UserDefaults.standard.object(forKey: "previewSoundCuesEnabled") as? Bool ?? true
        roomPreviewPolicyByRoom = UserDefaults.standard.dictionary(forKey: "roomPreviewPolicyByRoom") as? [String: Bool] ?? [:]
        if let value = UserDefaults.standard.string(forKey: "defaultRoomPrimaryAction"),
           let parsed = RoomPrimaryAction(rawValue: value) {
            defaultRoomPrimaryAction = parsed
        } else {
            defaultRoomPrimaryAction = .joinOrShow
        }
        if !UserDefaults.standard.bool(forKey: "migratedDefaultRoomActionToJoin"),
           defaultRoomPrimaryAction == .openDetails {
            defaultRoomPrimaryAction = .joinOrShow
            UserDefaults.standard.set(defaultRoomPrimaryAction.rawValue, forKey: "defaultRoomPrimaryAction")
            UserDefaults.standard.set(true, forKey: "migratedDefaultRoomActionToJoin")
        }
        adminGodModeEnabled = UserDefaults.standard.object(forKey: "adminGodModeEnabled") as? Bool ?? false
        adminInvisibleMode = UserDefaults.standard.object(forKey: "adminInvisibleMode") as? Bool ?? false

        // Profile settings
        userNickname = UserDefaults.standard.string(forKey: "userNickname") ?? ""
        userProfileLinks = UserDefaults.standard.stringArray(forKey: "userProfileLinks") ?? []

        // File sharing settings
        if let mode = UserDefaults.standard.string(forKey: "fileReceiveMode"),
           let receiveMode = FileReceiveMode(rawValue: mode) {
            self.fileReceiveMode = receiveMode
        }
        autoReceiveTimeLimit = UserDefaults.standard.integer(forKey: "autoReceiveTimeLimit")
        if autoReceiveTimeLimit == 0 { autoReceiveTimeLimit = 30 }
        maxAutoReceiveSize = UserDefaults.standard.integer(forKey: "maxAutoReceiveSize")
        if maxAutoReceiveSize == 0 { maxAutoReceiveSize = 100 }
        if let savePath = UserDefaults.standard.string(forKey: "saveReceivedFilesTo") {
            saveReceivedFilesTo = savePath
        }

        // Mastodon settings
        useMastodonForDM = UserDefaults.standard.bool(forKey: "useMastodonForDM")
        autoCreateThreads = UserDefaults.standard.bool(forKey: "autoCreateThreads")
        storeMastodonDMsLocally = UserDefaults.standard.bool(forKey: "storeMastodonDMsLocally")
        useMastodonForFileStorage = UserDefaults.standard.bool(forKey: "useMastodonForFileStorage")

        // Defaults that should be true
        if !UserDefaults.standard.bool(forKey: "settingsInitialized") {
            noiseSuppression = true
            echoCancellation = true
            autoGainControl = true
            autoConnect = true
            preferLocalServer = true
            soundNotifications = true
            desktopNotifications = true
            notifyOnJoin = true
            notifyOnLeave = true
            showOnlineStatus = true
            allowDirectMessages = true
            showPrivateMemberRooms = true
            showFederatedRooms = true
            showLocalOnlyRooms = true
            spatialAudioEnabled = true
            reconnectOnDisconnect = true
            showAudioControlsOnStartup = true
            closeButtonBehavior = .goToMainThenHide
            openMainWindowOnLaunch = true
            confirmBeforeQuit = false
            expandServerStatusByDefault = true
            showRoomDescriptions = true
            allowPreviewWhenMediaActive = true
            previewSoundCuesEnabled = true
            defaultRoomPrimaryAction = .joinOrShow
            adminGodModeEnabled = false
            adminInvisibleMode = false
            UserDefaults.standard.set(true, forKey: "settingsInitialized")
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(syncMode.rawValue, forKey: "syncMode")
        UserDefaults.standard.set(showPrivateMemberRooms, forKey: "showPrivateMemberRooms")
        UserDefaults.standard.set(showFederatedRooms, forKey: "showFederatedRooms")
        UserDefaults.standard.set(showLocalOnlyRooms, forKey: "showLocalOnlyRooms")
        UserDefaults.standard.set(managedFederationVisibility, forKey: "managedFederationVisibility")
        if let customData = try? JSONEncoder().encode(customFederationServers) {
            UserDefaults.standard.set(customData, forKey: "customFederationServers")
        }
        UserDefaults.standard.set(inputDevice, forKey: "inputDevice")
        UserDefaults.standard.set(outputDevice, forKey: "outputDevice")
        UserDefaults.standard.set(inputVolume, forKey: "inputVolume")
        UserDefaults.standard.set(outputVolume, forKey: "outputVolume")
        UserDefaults.standard.set(confirmBeforeDeletingRooms, forKey: "confirmBeforeDeletingRooms")
        UserDefaults.standard.set(noiseSuppression, forKey: "noiseSuppression")
        UserDefaults.standard.set(echoCancellation, forKey: "echoCancellation")
        UserDefaults.standard.set(autoGainControl, forKey: "autoGainControl")
        UserDefaults.standard.set(autoConnect, forKey: "autoConnect")
        UserDefaults.standard.set(preferLocalServer, forKey: "preferLocalServer")
        UserDefaults.standard.set(pttEnabled, forKey: "pttEnabled")
        UserDefaults.standard.set(spatialAudioEnabled, forKey: "spatialAudioEnabled")

        // UI settings
        UserDefaults.standard.set(showAudioControlsOnStartup, forKey: "showAudioControlsOnStartup")
        UserDefaults.standard.set(closeButtonBehavior.rawValue, forKey: "closeButtonBehavior")
        UserDefaults.standard.set(openMainWindowOnLaunch, forKey: "openMainWindowOnLaunch")
        UserDefaults.standard.set(confirmBeforeQuit, forKey: "confirmBeforeQuit")
        UserDefaults.standard.set(expandServerStatusByDefault, forKey: "expandServerStatusByDefault")
        UserDefaults.standard.set(showRoomDescriptions, forKey: "showRoomDescriptions")
        UserDefaults.standard.set(allowPreviewWhenMediaActive, forKey: "allowPreviewWhenMediaActive")
        UserDefaults.standard.set(previewSoundCuesEnabled, forKey: "previewSoundCuesEnabled")
        UserDefaults.standard.set(roomPreviewPolicyByRoom, forKey: "roomPreviewPolicyByRoom")
        UserDefaults.standard.set(defaultRoomPrimaryAction.rawValue, forKey: "defaultRoomPrimaryAction")
        UserDefaults.standard.set(adminGodModeEnabled, forKey: "adminGodModeEnabled")
        UserDefaults.standard.set(adminInvisibleMode, forKey: "adminInvisibleMode")

        // Profile settings
        UserDefaults.standard.set(userNickname, forKey: "userNickname")
        UserDefaults.standard.set(userProfileLinks, forKey: "userProfileLinks")

        // File sharing settings
        UserDefaults.standard.set(fileReceiveMode.rawValue, forKey: "fileReceiveMode")
        UserDefaults.standard.set(autoReceiveTimeLimit, forKey: "autoReceiveTimeLimit")
        UserDefaults.standard.set(maxAutoReceiveSize, forKey: "maxAutoReceiveSize")
        UserDefaults.standard.set(saveReceivedFilesTo, forKey: "saveReceivedFilesTo")

        // Mastodon settings
        UserDefaults.standard.set(useMastodonForDM, forKey: "useMastodonForDM")
        UserDefaults.standard.set(autoCreateThreads, forKey: "autoCreateThreads")
        UserDefaults.standard.set(storeMastodonDMsLocally, forKey: "storeMastodonDMsLocally")
        UserDefaults.standard.set(useMastodonForFileStorage, forKey: "useMastodonForFileStorage")

        // Apply selected devices so audio routing follows settings in active sessions.
        applySelectedAudioDevices()
    }

    func managedFederationEnabled(_ server: ManagedFederationServer) -> Bool {
        managedFederationVisibility[server.id] ?? true
    }

    func setManagedFederationEnabled(_ enabled: Bool, for server: ManagedFederationServer) {
        managedFederationVisibility[server.id] = enabled
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

        if let managed = Self.managedFederationServers.first(where: { normalizedHost.contains($0.host) || $0.host.contains(normalizedHost) }) {
            return managedFederationEnabled(managed)
        }

        if let custom = customFederationServers.first(where: { normalizedHost.contains($0.host) || $0.host.contains(normalizedHost) }) {
            return custom.federationEnabled
        }

        return true
    }

    func roomPreviewOverride(for roomId: String) -> Bool? {
        roomPreviewPolicyByRoom[roomId]
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
        return userCount > 0 || (allowPreviewWhenMediaActive && hasActiveMedia)
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

    func applySelectedAudioDevices() {
        guard !isApplyingAudioDeviceSelection else { return }
        isApplyingAudioDeviceSelection = true
        defer { isApplyingAudioDeviceSelection = false }

        if inputDevice != "Default" {
            let switched = setPreferredDevice(named: inputDevice, isInput: true)
            if !switched {
                print("[Settings] Failed to apply input device selection: \(inputDevice)")
            }
            let resolvedInput = currentDefaultDeviceName(isInput: true)
            print("[Settings] Effective input device after apply: \(resolvedInput)")
        }

        if outputDevice != "Default" {
            let switched = setPreferredDevice(named: outputDevice, isInput: false)
            if !switched {
                print("[Settings] Failed to apply output device selection: \(outputDevice)")
            }
            let resolvedOutput = currentDefaultDeviceName(isInput: false)
            print("[Settings] Effective output device after apply: \(resolvedOutput)")
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
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = SettingsManager.shared
    @State private var selectedTab: SettingsTab = .audio
    @State private var isSoundTestPlaying = false

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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    settings.saveSettings()
                    appState.currentScreen = .mainMenu
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.8))

                Spacer()

                Text("Settings")
                    .font(.title2.bold())
                    .foregroundColor(.white)

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
        .onReceive(NotificationCenter.default.publisher(for: .openProfileSettings)) { _ in
            selectedTab = .profile
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAudioSettings)) { _ in
            selectedTab = .audio
        }
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
            Toggle("Open main window on launch", isOn: $settings.openMainWindowOnLaunch)
                .onChange(of: settings.openMainWindowOnLaunch) { _ in settings.saveSettings() }
                .accessibilityHint("When enabled, VoiceLink opens the main window automatically at startup.")
            Toggle("Expand server status details by default", isOn: $settings.expandServerStatusByDefault)
                .onChange(of: settings.expandServerStatusByDefault) { _ in settings.saveSettings() }
                .accessibilityHint("When enabled, server details start expanded. Turn off to keep that section collapsed.")
            Toggle("Show room descriptions in room list", isOn: $settings.showRoomDescriptions)
                .onChange(of: settings.showRoomDescriptions) { _ in settings.saveSettings() }
                .accessibilityHint("Shows or hides room description text in list and grid views.")
            Toggle("Allow preview when room media is active", isOn: $settings.allowPreviewWhenMediaActive)
                .onChange(of: settings.allowPreviewWhenMediaActive) { _ in settings.saveSettings() }
                .accessibilityHint("Lets room preview start when media is playing, even if no users are actively speaking.")
            Toggle("Play sound cues when preview starts and stops", isOn: $settings.previewSoundCuesEnabled)
                .onChange(of: settings.previewSoundCuesEnabled) { _ in settings.saveSettings() }
                .accessibilityHint("Plays the configured preview in/out sounds when toggling room preview.")
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
            }
        }

        SettingsSection(title: "Profile Links") {
            let statusManager = StatusManager.shared

            Toggle("Auto-sync links from Contact Card", isOn: Binding(
                get: { statusManager.syncWithContactCard },
                set: { newValue in
                    statusManager.setSyncWithContactCard(newValue)
                }
            ))

            HStack {
                Button("Sync Now") {
                    statusManager.syncContactCardNow()
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            if settings.userProfileLinks.isEmpty {
                Text("No profile links found yet. Add links to your macOS Me card, then choose Sync Now.")
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

        SettingsSection(title: "Authentication") {
            let authManager = AuthenticationManager.shared
            if authManager.authState == .authenticated {
                if let user = authManager.currentUser {
                    Text("Signed in as \(user.displayName)")
                        .foregroundColor(.gray)
                }
                Button("Manage Connected Account") {
                    appState.currentScreen = .login
                }
                .buttonStyle(.bordered)
            } else {
                HStack(spacing: 10) {
                    Button("Mastodon") { appState.currentScreen = .login }
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

        mastodonSettings
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
                Slider(value: $settings.outputVolume, in: 0...1)
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

        SettingsSection(title: "Federated Servers") {
            Text("Main-managed defaults stay listed here for visibility control. Turning them off only hides their rooms in this desktop client. It does not rewrite server-side federation settings.")
                .font(.caption)
                .foregroundColor(.gray)

            ForEach(SettingsManager.managedFederationServers) { server in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { settings.managedFederationEnabled(server) },
                        set: { settings.setManagedFederationEnabled($0, for: server) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(server.name)
                                Text("Default")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.22))
                                    .cornerRadius(6)
                            }
                            Text(server.url)
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(server.description)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
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
            Toggle("Play sound when user joins", isOn: $settings.notifyOnJoin)
            Toggle("Play sound when user leaves", isOn: $settings.notifyOnLeave)
        }

        SettingsSection(title: "Desktop Notifications") {
            Toggle("Enable desktop notifications", isOn: $settings.desktopNotifications)

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
                            authManager.logout()
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
                        appState.currentScreen = .login
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Advanced Settings
    @ViewBuilder
    var advancedSettings: some View {
        SettingsSection(title: "Developer Options") {
            Toggle("Enable debug logging", isOn: .constant(false))
            Toggle("Show connection stats", isOn: .constant(false))
        }

        SettingsSection(title: "Audio Codec") {
            Picker("Codec", selection: .constant("Opus")) {
                Text("Opus (Recommended)").tag("Opus")
                Text("PCM").tag("PCM")
            }
            .pickerStyle(.menu)
        }

        SettingsSection(title: "Network") {
            Text("Local IP: \(appState.localIP)")
                .font(.caption)
                .foregroundColor(.gray)
        }

        SettingsSection(title: "Reset") {
            Button("Reset All Settings") {
                // Reset to defaults
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
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

struct LicensingScreenView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var licensing = LicensingManager.shared

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

            // Main licensing view
            LicensingView()
                .frame(maxWidth: 400)

            // Additional info
            VStack(spacing: 8) {
                Text("License includes:")
                    .font(.headline)
                    .foregroundColor(.white)

                HStack(spacing: 20) {
                    FeatureBadge(icon: "globe", text: "Federation")
                    FeatureBadge(icon: "server.rack", text: "Hosting")
                    FeatureBadge(icon: "person.3", text: "3 Devices")
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
