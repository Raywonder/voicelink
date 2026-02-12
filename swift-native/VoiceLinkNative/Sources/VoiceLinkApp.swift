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

                Button("Join by Code") {
                    appState.currentScreen = .joinRoom
                }
                .keyboardShortcut("j", modifiers: .command)

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
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!appState.hasActiveRoom)
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
                    AppSoundManager.shared.playSound(.soundTest)
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

                if AdminServerManager.shared.isAdmin || AdminServerManager.shared.adminRole == .admin || AdminServerManager.shared.adminRole == .owner {
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
    static let mainWindowCloseRequested = Notification.Name("mainWindowCloseRequested")
    static let openRoomJukebox = Notification.Name("openRoomJukebox")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    static var shared: AppDelegate?
    private let windowController = MainWindowController()
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        if SettingsManager.shared.confirmBeforeQuit {
            let alert = NSAlert()
            alert.messageText = "Quit VoiceLink?"
            alert.informativeText = "VoiceLink will fully quit even if you are in a room."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
    private var previousScreen: Screen = .mainMenu

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

    init() {
        detectLocalIP()
        connectToServer()
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
            serverManager.joinRoom(roomId: roomId, username: joinName)
            currentScreen = .voiceChat
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
            serverManager.joinRoom(roomId: code, username: joinName)
            currentScreen = .voiceChat
        }
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
            .assign(to: &$serverStatus)

        // Observe rooms from server
        serverManager.$rooms
            .receive(on: DispatchQueue.main)
            .map { serverRooms in
                serverRooms.map { Room(from: $0) }
            }
            .assign(to: &$rooms)

        // Observe errors
        serverManager.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$errorMessage)

        // Keep admin capabilities in sync with active server connection.
        serverManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAdminCapabilities()
            }
            .store(in: &cancellables)

        // Listen for room joined notification
        NotificationCenter.default.addObserver(forName: .roomJoined, object: nil, queue: .main) { [weak self] notification in
            if let roomData = notification.object as? [String: Any],
               let roomId = roomData["roomId"] as? String ?? roomData["id"] as? String {
                // Find the room and set it as current
                if let room = self?.rooms.first(where: { $0.id == roomId }) {
                    self?.currentRoom = room
                    self?.minimizedRoom = nil
                    self?.currentScreen = .voiceChat
                }
            }
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
    }

    private func setupWindowBehaviorObservers() {
        NotificationCenter.default.addObserver(forName: .mainWindowCloseRequested, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let settings = SettingsManager.shared

            if self.currentScreen != .mainMenu {
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

    private func refreshAdminCapabilities() {
        guard let serverURL = serverManager.baseURL, !serverURL.isEmpty else {
            AdminServerManager.shared.isAdmin = false
            AdminServerManager.shared.adminRole = .none
            return
        }

        let token = AuthenticationManager.shared.currentUser?.accessToken
        Task {
            await AdminServerManager.shared.checkAdminStatus(serverURL: serverURL, token: token)
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
        guard let base = serverManager.baseURL, !base.isEmpty else { return }
        guard let url = APIEndpointResolver.url(base: base, path: "/api/rooms") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            let parsed = array.compactMap { ServerRoom(from: $0) }.map(Room.init(from:))
            if !parsed.isEmpty {
                rooms = parsed
            }
        } catch {
            // Keep socket path as primary; fallback is best-effort.
        }
    }

    func canManageRoom(_ room: Room) -> Bool {
        let role = room.createdByRole?.lowercased() ?? ""
        return SettingsManager.shared.adminGodModeEnabled
            || AdminServerManager.shared.isAdmin
            || AdminServerManager.shared.adminRole.canManageRooms
            || role.contains("admin")
            || role.contains("owner")
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
        serverManager.joinRoom(roomId: room.id, username: joinName)
        currentRoom = room
        currentScreen = .voiceChat
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

    func leaveCurrentRoom() {
        serverManager.leaveRoom()
        currentRoom = nil
        minimizedRoom = nil
        currentScreen = .mainMenu
        errorMessage = nil
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
struct Room: Identifiable {
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
        lastActivityAt: Date? = nil
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
    }
}

// MARK: - Content View
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showJukeboxSheet = false

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
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRoomJukebox)) { _ in
            showJukeboxSheet = true
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

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var localDiscovery: LocalServerDiscovery
    @ObservedObject var healthMonitor = ConnectionHealthMonitor.shared
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var isServerStatusExpanded = SettingsManager.shared.expandServerStatusByDefault
    @State private var roomSortOption: RoomSortOption = .activeFirst
    @State private var roomLayoutOption: RoomLayoutOption = .list
    @State private var selectedRoomDetails: Room?

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
        appState.isConnected ? "Connected (\(appState.serverManager.connectedServer))" : statusText
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

    var body: some View {
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

                DisclosureGroup(
                    isExpanded: $isServerStatusExpanded,
                    content: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 10, height: 10)
                                Text("Connection: \(statusText)")
                                    .foregroundColor(.white.opacity(0.85))
                                Spacer()
                                Text("Local IP: \(appState.localIP)")
                                    .foregroundColor(.white.opacity(0.6))
                                    .font(.caption)
                            }
                        }
                        .padding(.top, 8)
                    },
                    label: {
                        HStack {
                            Text("Server Details")
                                .foregroundColor(.white)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(serverStatusSummary)
                                .foregroundColor(.white.opacity(0.7))
                                .font(.caption)
                        }
                    }
                )
                .padding(.horizontal, 40)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)
                .padding(.horizontal, 40)
                .accessibilityLabel("Server details")
                .accessibilityHint("Expand for connection details and sync mode options. Collapse to save space.")

                HStack {
                    Text("Sync Mode")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.caption)
                    Spacer()
                    Menu {
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
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: SettingsManager.shared.syncMode.icon)
                            Text(SettingsManager.shared.syncMode.displayName)
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                        .foregroundColor(.white.opacity(0.8))
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 40)

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

                HStack {
                    Text("Sort Rooms")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                    Picker("Sort Rooms", selection: $roomSortOption) {
                        ForEach(RoomSortOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Sort rooms")
                    .accessibilityHint("Sort available rooms alphabetically or by activity and member count.")
                }

                HStack {
                    Text("View")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                    Picker("Room view", selection: $roomLayoutOption) {
                        ForEach(RoomLayoutOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Room view layout")
                    .accessibilityHint("Choose list or grid layout for room cards.")
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
                            ForEach(sortedRooms) { room in
                                let canAdminRoom = appState.canManageRoom(room)
                                RoomCard(
                                    room: room,
                                    isActiveRoom: appState.activeRoomId == room.id,
                                    isAdmin: canAdminRoom
                                ) {
                                    appState.joinOrShowRoom(room)
                                } onPreview: {
                                    PeekManager.shared.peekIntoRoom(room)
                                } onShare: {
                                    let roomURL = "https://voicelink.devinecreations.net/client/#/room/\(room.id)"
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
                                }
                            }
                        }
                    } else if roomLayoutOption == .grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                            ForEach(sortedRooms) { room in
                                let canAdminRoom = appState.canManageRoom(room)
                                RoomCard(
                                    room: room,
                                    isActiveRoom: appState.activeRoomId == room.id,
                                    isAdmin: canAdminRoom
                                ) {
                                    appState.joinOrShowRoom(room)
                                } onPreview: {
                                    PeekManager.shared.peekIntoRoom(room)
                                } onShare: {
                                    let roomURL = "https://voicelink.devinecreations.net/client/#/room/\(room.id)"
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

                            ForEach(sortedRooms) { room in
                                let canAdminRoom = appState.canManageRoom(room)
                                RoomColumnRow(
                                    room: room,
                                    isActiveRoom: appState.activeRoomId == room.id,
                                    isAdmin: canAdminRoom
                                ) {
                                    appState.joinOrShowRoom(room)
                                } onPreview: {
                                    PeekManager.shared.peekIntoRoom(room)
                                } onShare: {
                                    let roomURL = "https://voicelink.devinecreations.net/client/#/room/\(room.id)"
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
                        isActiveRoom: appState.activeRoomId == room.id,
                        onJoin: { appState.joinOrShowRoom(room) },
                        onShare: {
                            let roomURL = "https://voicelink.devinecreations.net/client/#/room/\(room.id)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(roomURL, forType: .string)
                            AppSoundManager.shared.playSound(.success)
                        },
                        onPreview: { PeekManager.shared.peekIntoRoom(room) }
                    )
                }
            }
            .padding(.horizontal, 40)

            // Action Buttons
            HStack(spacing: 20) {
                ActionButton(title: "Create Room", icon: "plus.circle.fill", color: .blue) {
                    appState.currentScreen = .createRoom
                }

                ActionButton(title: "Join by Code", icon: "link.circle.fill", color: .green) {
                    appState.currentScreen = .joinRoom
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
                    ActionButton(title: "Login with Mastodon", icon: "person.circle.fill", color: .purple) {
                        appState.currentScreen = .login
                    }
                }
            }
            .padding(.horizontal, 40)

                Spacer()
            }
            .frame(maxWidth: .infinity)

            // Right Sidebar - Connection Health & Servers
            VStack(spacing: 16) {
                Spacer()

                // Settings tip at bottom of sidebar
                Text("Command+Comma for Settings")
                    .font(.caption)
                    .foregroundColor(.gray.opacity(0.6))
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
    let isActiveRoom: Bool
    let isAdmin: Bool
    let onJoin: () -> Void
    var onPreview: () -> Void = {}
    var onShare: () -> Void = {}
    var onOpenAdmin: () -> Void = {}
    var onCreateRoom: () -> Void = {}
    var onDeleteRoom: () -> Void = {}
    var onOpenDetails: () -> Void = {}

    var displayDescription: String {
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

    func runPrimaryAction() {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            onOpenDetails()
        case .joinOrShow:
            onJoin()
        case .preview:
            if room.userCount > 0 { onPreview() } else { onOpenDetails() }
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
                isPrimaryDisabled: settings.defaultRoomPrimaryAction == .preview && room.userCount <= 0,
                onPrimaryAction: { runPrimaryAction() },
                onJoin: onJoin,
                onPreview: onPreview,
                onShare: onShare,
                onOpenDetails: onOpenDetails,
                onOpenAdmin: onOpenAdmin,
                onCreateRoom: onCreateRoom,
                onDeleteRoom: onDeleteRoom,
                roomId: room.id,
                roomHasUsers: room.userCount > 0,
                isAdmin: isAdmin
            )
        }
        .padding()
        .background(Color.white.opacity(0.1))
        .cornerRadius(12)
    }
}

struct RoomActionSplitButton: View {
    let primaryLabel: String
    let isActiveRoom: Bool
    let isPrimaryDisabled: Bool
    let onPrimaryAction: () -> Void
    let onJoin: () -> Void
    let onPreview: () -> Void
    let onShare: () -> Void
    let onOpenDetails: () -> Void
    let onOpenAdmin: () -> Void
    let onCreateRoom: () -> Void
    let onDeleteRoom: () -> Void
    let roomId: String
    let roomHasUsers: Bool
    let isAdmin: Bool

    var body: some View {
            Menu {
                Button("Room Details") { onOpenDetails() }
                Button(isActiveRoom ? "Show Room" : "Join Room") { onJoin() }
                Button("Open Jukebox") {
                    NotificationCenter.default.post(name: .openRoomJukebox, object: nil)
                }
                Button("Preview Room Audio") { onPreview() }.disabled(!roomHasUsers)
                Button("Share Room Link") { onShare() }
            Button("Copy Room ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(roomId, forType: .string)
            }
            Divider()
            Menu("Manage Room") {
                Button("Open Room Administration") { onOpenAdmin() }
                Button("Create New Room") { onCreateRoom() }
                Button("Delete This Room", role: .destructive) { onDeleteRoom() }
                    .disabled(!isAdmin)
            }
        } label: {
            Text("Details")
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background((isActiveRoom ? Color.green : Color.blue).opacity(0.9))
                .foregroundColor(.white)
                .cornerRadius(8)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Room details and actions")
        .accessibilityHint("Opens context menu with details, join, preview, share, and room management.")
    }
}

struct RoomColumnRow: View {
    @ObservedObject private var settings = SettingsManager.shared
    let room: Room
    let isActiveRoom: Bool
    let isAdmin: Bool
    let onJoin: () -> Void
    var onPreview: () -> Void = {}
    var onShare: () -> Void = {}
    var onOpenAdmin: () -> Void = {}
    var onCreateRoom: () -> Void = {}
    var onDeleteRoom: () -> Void = {}
    var onOpenDetails: () -> Void = {}

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

    func runPrimaryAction() {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            onOpenDetails()
        case .joinOrShow:
            onJoin()
        case .preview:
            if room.userCount > 0 { onPreview() } else { onOpenDetails() }
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
                Text(room.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No description provided." : room.description)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .lineLimit(1)
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

            RoomActionSplitButton(
                primaryLabel: primaryLabel,
                isActiveRoom: isActiveRoom,
                isPrimaryDisabled: settings.defaultRoomPrimaryAction == .preview && room.userCount <= 0,
                onPrimaryAction: { runPrimaryAction() },
                onJoin: onJoin,
                onPreview: onPreview,
                onShare: onShare,
                onOpenDetails: onOpenDetails,
                onOpenAdmin: onOpenAdmin,
                onCreateRoom: onCreateRoom,
                onDeleteRoom: onDeleteRoom,
                roomId: room.id,
                roomHasUsers: room.userCount > 0,
                isAdmin: isAdmin
            )
            .frame(width: 170, alignment: .trailing)
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }
}

struct RoomDetailsSheet: View {
    let room: Room
    let isActiveRoom: Bool
    let onJoin: () -> Void
    let onShare: () -> Void
    let onPreview: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(room.name).font(.title2.weight(.bold))
            Text(room.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No description provided." : room.description)
                .foregroundColor(.secondary)

            HStack {
                Text("Users: \(room.userCount)/\(room.maxUsers)")
                Spacer()
                Text(room.isPrivate ? "Private" : "Public")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button(isActiveRoom ? "Return to Room" : "Join Room") { onJoin(); dismiss() }
                    .buttonStyle(.borderedProminent)
                Button("Share") { onShare() }
                    .buttonStyle(.bordered)
                Button("Peek In") { onPreview() }
                    .buttonStyle(.bordered)
                    .disabled(room.userCount <= 0)
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 260)
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
    @State private var roomName = ""
    @State private var roomDescription = ""
    @State private var isPrivate = false
    @State private var password = ""

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

                if isPrivate {
                    SecureField("Room Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 350)
                }
            }

            HStack(spacing: 15) {
                Button("Create") {
                    // Create room via server
                    appState.serverManager.createRoom(
                        name: roomName,
                        description: roomDescription,
                        isPrivate: isPrivate,
                        password: isPrivate ? password : nil
                    )
                    // Go back to main menu - room will appear in list
                    appState.currentScreen = .mainMenu
                }
                .buttonStyle(.borderedProminent)
                .disabled(roomName.isEmpty || !appState.isConnected)

                Button("Cancel") {
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
    }
}

struct JoinRoomView: View {
    @EnvironmentObject var appState: AppState
    @State private var roomCode = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Join Room")
                .font(.largeTitle)
                .foregroundColor(.white)

            TextField("Room Code", text: $roomCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack {
                Button("Join") {
                    // Join room logic
                }
                .buttonStyle(.borderedProminent)

                Button("Back") {
                    appState.currentScreen = .mainMenu
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct VoiceChatView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var messagingManager = MessagingManager.shared
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var isMuted = false
    @State private var isDeafened = false
    @State private var messageText = ""
    @State private var showChat = true

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
                        if let room = appState.currentRoom, appState.canManageRoom(room) {
                            Button("Room Administration") {
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
                                username: "\(meDisplayName) (Me)",
                                isMuted: isMuted,
                                isDeafened: isDeafened,
                                isSpeaking: appState.serverManager.isAudioTransmitting && !isMuted,
                                isCurrentUser: true
                            )

                            // Show other users from server
                            ForEach(visibleRoomUsers) { user in
                                UserRow(
                                    username: user.username,
                                    isMuted: user.isMuted,
                                    isDeafened: user.isDeafened,
                                    isSpeaking: user.isSpeaking
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
                        // Play button click sound
                        AppSoundManager.shared.playSound(.buttonClick)
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
                        // Play button click sound
                        AppSoundManager.shared.playSound(.buttonClick)
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMute)) { _ in
            isMuted.toggle()
            appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
            // Play button click sound
            AppSoundManager.shared.playSound(.buttonClick)
            // Announce state change
            AccessibilityManager.shared.announceAudioStatus(isMuted ? "muted" : "unmuted")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleDeafen)) { _ in
            isDeafened.toggle()
            appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
            // Play button click sound
            AppSoundManager.shared.playSound(.buttonClick)
            // Announce state change
            AccessibilityManager.shared.announceAudioStatus(isDeafened ? "deafened" : "undeafened")
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
        messageText = ""
    }
}

// Chat message row view
struct ChatMessageRow: View {
    let message: MessagingManager.ChatMessage

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
    let username: String
    let isMuted: Bool
    let isDeafened: Bool
    let isSpeaking: Bool
    var isCurrentUser: Bool = false

    @State private var showControls = false
    @State private var userVolume: Double = 1.0
    @State private var isUserMuted = false
    @State private var isSoloed = false
    @ObservedObject private var settings = SettingsManager.shared

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
                    // TODO: Implement direct message
                    print("Send DM to \(username)")
                }) {
                    Label("Send Direct Message", systemImage: "message")
                }

                Button(action: {
                    // TODO: Implement file send
                    print("Send file to \(username)")
                }) {
                    Label("Send File", systemImage: "doc")
                }

                Divider()

                Button(action: {
                    // TODO: Implement view profile
                    print("View profile of \(username)")
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
                                get: { isCurrentUser ? settings.inputVolume : userVolume },
                                set: { newValue in
                                    if isCurrentUser {
                                        settings.inputVolume = newValue
                                        settings.saveSettings()
                                    } else {
                                        userVolume = newValue
                                    }
                                }
                            ),
                            in: 0...1
                        )
                            .frame(maxWidth: .infinity)
                        Text("\(Int((isCurrentUser ? settings.inputVolume : userVolume) * 100))%")
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
                        Button(action: { if !isCurrentUser { isUserMuted.toggle() } }) {
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

                        Button(action: { isSoloed.toggle() }) {
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
                        Text("You cannot mute yourself in this list. Use main room mute controls.")
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

// MARK: - Settings Manager
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    private var isApplyingAudioDeviceSelection = false

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
    @Published var expandServerStatusByDefault: Bool = true
    @Published var showRoomDescriptions: Bool = true
    enum RoomPrimaryAction: String, CaseIterable {
        case openDetails = "openDetails"
        case joinOrShow = "joinOrShow"
        case preview = "preview"
        case share = "share"
    }
    @Published var defaultRoomPrimaryAction: RoomPrimaryAction = .openDetails
    @Published var adminGodModeEnabled: Bool = false
    @Published var adminInvisibleMode: Bool = false

    // Profile Settings
    @Published var userNickname: String = ""
    @Published var userProfileLinks: [String] = []

    // Available devices
    @Published var availableInputDevices: [String] = ["Default"]
    @Published var availableOutputDevices: [String] = ["Default"]

    init() {
        loadSettings()
        detectAudioDevices()
    }

    func loadSettings() {
        if let mode = UserDefaults.standard.string(forKey: "syncMode"),
           let syncMode = SyncMode(rawValue: mode) {
            self.syncMode = syncMode
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
        if let value = UserDefaults.standard.string(forKey: "defaultRoomPrimaryAction"),
           let parsed = RoomPrimaryAction(rawValue: value) {
            defaultRoomPrimaryAction = parsed
        } else {
            defaultRoomPrimaryAction = .openDetails
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
            spatialAudioEnabled = true
            reconnectOnDisconnect = true
            showAudioControlsOnStartup = true
            closeButtonBehavior = .goToMainThenHide
            openMainWindowOnLaunch = true
            confirmBeforeQuit = false
            expandServerStatusByDefault = true
            showRoomDescriptions = true
            defaultRoomPrimaryAction = .openDetails
            adminGodModeEnabled = false
            adminInvisibleMode = false
            UserDefaults.standard.set(true, forKey: "settingsInitialized")
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(syncMode.rawValue, forKey: "syncMode")
        UserDefaults.standard.set(inputDevice, forKey: "inputDevice")
        UserDefaults.standard.set(outputDevice, forKey: "outputDevice")
        UserDefaults.standard.set(inputVolume, forKey: "inputVolume")
        UserDefaults.standard.set(outputVolume, forKey: "outputVolume")
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

        availableInputDevices = ["Default"] + uniqueInput.filter { $0 != "Default" }.sorted()
        availableOutputDevices = ["Default"] + uniqueOutput.filter { $0 != "Default" }.sorted()

        if !availableInputDevices.contains(inputDevice) {
            inputDevice = "Default"
        }

        if !availableOutputDevices.contains(outputDevice) {
            outputDevice = "Default"
        }
    }

    func applySelectedAudioDevices() {
        guard !isApplyingAudioDeviceSelection else { return }
        isApplyingAudioDeviceSelection = true
        defer { isApplyingAudioDeviceSelection = false }

        if inputDevice != "Default",
           let inputId = getDeviceID(named: inputDevice, scope: kAudioDevicePropertyScopeInput) {
            setSystemDefaultDevice(deviceId: inputId, isInput: true)
        }

        if outputDevice != "Default",
           let outputId = getDeviceID(named: outputDevice, scope: kAudioDevicePropertyScopeOutput) {
            setSystemDefaultDevice(deviceId: outputId, isInput: false)
        }
    }

    private func setSystemDefaultDevice(deviceId: AudioDeviceID, isInput: Bool) {
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
        } else {
            print("[Settings] Applied \(isInput ? "input" : "output") device selection: \(deviceId)")
        }
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
        case profile = "Profile"
        case audio = "Audio"
        case sync = "Sync & Filters"
        case fileSharing = "File Sharing"
        case notifications = "Notifications"
        case privacy = "Privacy"
        case mastodon = "Mastodon"
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
                        case .mastodon:
                            mastodonSettings
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
        case .mastodon: return "bubble.left.and.bubble.right"
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
                Text("\(Int(settings.inputVolume * 100))%")
                    .frame(width: 40)
            }
        }

        SettingsSection(title: "Current Device Status") {
            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    label: "Built-In Input Device",
                    value: detectedBuiltinInputName
                )
                statusRow(
                    label: "Selected Input Name",
                    value: settings.inputDevice
                )
                statusRow(
                    label: "Input Status",
                    value: settings.availableInputDevices.contains(settings.inputDevice) ? "Connected" : "Unavailable"
                )

                Divider().background(Color.white.opacity(0.15))

                statusRow(
                    label: "Built-In Output Device",
                    value: detectedBuiltinOutputName
                )
                statusRow(
                    label: "Selected Output Name",
                    value: settings.outputDevice
                )
                statusRow(
                    label: "Output Status",
                    value: settings.availableOutputDevices.contains(settings.outputDevice) ? "Connected" : "Unavailable"
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "Current audio devices. Built in input \(detectedBuiltinInputName). Selected input \(settings.inputDevice). Input status \(settings.availableInputDevices.contains(settings.inputDevice) ? "Connected" : "Unavailable"). Built in output \(detectedBuiltinOutputName). Selected output \(settings.outputDevice). Output status \(settings.availableOutputDevices.contains(settings.outputDevice) ? "Connected" : "Unavailable")."
            )
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
                if isSoundTestPlaying {
                    AppSoundManager.shared.stopSound(.soundTest)
                    isSoundTestPlaying = false
                } else {
                    AppSoundManager.shared.playSound(.soundTest)
                    isSoundTestPlaying = true
                }
            }) {
                Text(isSoundTestPlaying ? "Stop Test" : "Test My Sound")
            }
            .buttonStyle(.bordered)
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

    private var detectedBuiltinInputName: String {
        detectBuiltinDevice(in: settings.availableInputDevices)
    }

    private var detectedBuiltinOutputName: String {
        detectBuiltinDevice(in: settings.availableOutputDevices)
    }

    private func detectBuiltinDevice(in devices: [String]) -> String {
        let preferred = devices.first {
            let d = $0.lowercased()
            return d.contains("built-in") || d.contains("internal")
        }
        return preferred ?? "Not detected"
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
            Toggle("Show private rooms I'm a member of", isOn: .constant(true))
            Toggle("Show federated rooms", isOn: .constant(true))
            Toggle("Show local-only rooms", isOn: .constant(true))
        }
    }

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
