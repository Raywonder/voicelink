import SwiftUI
import AVFoundation
import AppKit
import SocketIO
import CoreAudio
import Combine
import WebKit

@main
struct VoiceLinkApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var localDiscovery = LocalServerDiscovery.shared
    @State private var showJukebox = false

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
                .sheet(isPresented: $showJukebox) {
                    JellyfinView()
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
                Button("New Room") {
                    appState.currentScreen = .createRoom
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Room") {
                if let room = appState.currentRoom {
                    Text("Current Room: \(room.name)")
                    Text("Members: \(appState.serverManager.currentRoomUsers.count + 1)")
                    Divider()
                } else {
                    Text("Current Room: None")
                    Divider()
                }

                Button("Create Room") {
                    appState.currentScreen = .createRoom
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Join by Code") {
                    appState.currentScreen = .joinRoom
                }
                .keyboardShortcut("j", modifiers: .command)

                Divider()

                Button("Open Room View") {
                    appState.currentScreen = .voiceChat
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(appState.currentRoom == nil)

                Button("Open Jukebox...") {
                    showJukebox = true
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Pause Ambient Audio") {
                    JellyfinManager.shared.pauseAmbientForPlayback()
                }

                Button("Resume Ambient Audio") {
                    JellyfinManager.shared.resumeAmbientMusic()
                }

                Button("Stop Ambient Audio") {
                    JellyfinManager.shared.stopAmbientMusic(reason: "user")
                }

                Button("Export Room Snapshot...") {
                    appState.exportRoomSnapshot()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.currentRoom == nil)

                Divider()

                Button("Leave Room") {
                    appState.currentRoom = nil
                    appState.currentScreen = .mainMenu
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState.currentRoom == nil)
            }
            CommandMenu("Audio") {
                Button("Toggle Mute") {
                    NotificationCenter.default.post(name: .toggleMute, object: nil)
                }
                .keyboardShortcut("m", modifiers: .command)

                Button("Toggle Deafen") {
                    NotificationCenter.default.post(name: .toggleDeafen, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
            }

            CommandMenu("Account") {
                let authManager = AuthenticationManager.shared

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

                Button("Set Nickname...") {
                    appState.currentScreen = .settings
                    NotificationCenter.default.post(name: .openProfileSettings, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
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

            CommandMenu("Server") {
                let serverManager = ServerManager.shared
                let settings = SettingsManager.shared

                // Connection status
                if serverManager.isConnected {
                    Label("Connected to \(serverManager.connectedServer)", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Disconnected", systemImage: "xmark.circle")
                }

                Divider()

                // Quick connect options
                Button("Connect to Federation") {
                    serverManager.connectToMainServer()
                    UserDefaults.standard.set("main", forKey: "lastConnectedServer")
                }
                .disabled(serverManager.isConnected && serverManager.connectedServer == "Federation")

                if settings.showLocalServerControls {
                    Button("Connect to Local Server") {
                        serverManager.connectToLocalServer()
                        UserDefaults.standard.set("local", forKey: "lastConnectedServer")
                    }
                    .disabled(serverManager.isConnected && serverManager.connectedServer == "Local Server")
                }

                Divider()

                Button("Disconnect") {
                    serverManager.disconnect()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!serverManager.isConnected)

                Button("Reconnect") {
                    serverManager.tryMainThenLocal()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandMenu("Servers") {
                Button("My Linked Servers...") {
                    appState.currentScreen = .servers
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("View and manage servers you've linked to this device")

                // Local server discovery - requires license
                if SettingsManager.shared.showLocalServerControls && LicensingManager.shared.licenseStatus == .licensed {
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

                if AdminServerManager.shared.isAdmin {
                    Divider()

                    Button("Server Administration...") {
                        appState.currentScreen = .admin
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .help("Manage remote server settings (admin only)")
                    
                    Button("Refresh Admin Overview") {
                        Task {
                            await AdminServerManager.shared.fetchServerStats()
                            await AdminServerManager.shared.fetchServerConfig()
                            await AdminServerManager.shared.fetchSchedulerHealth()
                            appState.currentScreen = .admin
                        }
                    }
                    .help("Refresh server stats, config, and scheduler health")

                    Button("Refresh Connected Users") {
                        Task {
                            await AdminServerManager.shared.fetchConnectedUsers()
                            appState.currentScreen = .admin
                        }
                    }
                    .help("Refresh connected user list in admin UI")

                    Button("Refresh Rooms") {
                        Task {
                            await AdminServerManager.shared.fetchRooms()
                            appState.currentScreen = .admin
                        }
                    }
                    .help("Refresh room list in admin UI")
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
                    if let url = URL(string: "https://voicelink.devinecreations.net/help") {
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
    static let openNotificationInbox = Notification.Name("openNotificationInbox")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    static var shared: AppDelegate?

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

        // Show window on launch (user can close it to stay in menubar)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                window.center()
            }
        }

        // Play randomized intro welcome sound from root sounds folder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            AppSoundManager.shared.playRandomStartupIntro()
        }
        // Retry once in case resources or audio are still initializing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            AppSoundManager.shared.playRandomStartupIntro()
        }

        // Ensure updater-triggered quit fully terminates the app.
        NotificationCenter.default.addObserver(
            forName: .shouldQuitForUpdate,
            object: nil,
            queue: .main
        ) { _ in
            NSApp.terminate(nil)
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
        // Keep tray behavior when user closes the window.
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Disconnect from server on quit
        ServerManager.shared.disconnect()
        LocalServerDiscovery.shared.stopScanning()
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title.contains("VoiceLink") || $0.contentView != nil }) {
            window.makeKeyAndOrderFront(nil)
            window.center()
        } else {
            // If no window exists, open a new one
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func hideMainWindow() {
        for window in NSApp.windows {
            window.close()
        }
    }
}

// MARK: - App State
class AppState: ObservableObject {
    @Published var currentScreen: Screen = .mainMenu
    @Published var isConnected: Bool = false
    @Published var currentRoom: Room? {
        didSet {
            if let room = currentRoom {
                UserDefaults.standard.set(room.roomId, forKey: "lastJoinedRoomId")
                UserDefaults.standard.set(room.name, forKey: "lastJoinedRoomName")
            }
            NotificationCenter.default.post(
                name: .activeRoomChanged,
                object: nil,
                userInfo: ["roomId": currentRoom?.roomId as Any]
            )
        }
    }
    @Published var rooms: [Room] = []
    @Published var localIP: String = "Detecting..."
    @Published var serverStatus: ServerStatus = .offline
    @Published var username: String = "User\(Int.random(in: 1000...9999))"
    @Published var errorMessage: String?
    @Published var showAnnouncements: Bool = false
    @Published var showBugReport: Bool = false

    let serverManager = ServerManager.shared
    let licensing = LicensingManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var roomRefreshCancellable: AnyCancellable?
    private var hasTriedAutoJoinLastRoom = false
    private var lastNotifiedUpdateVersion: String?
    private let lastJoinedRoomIdKey = "lastJoinedRoomId"
    private let lastJoinedRoomNameKey = "lastJoinedRoomName"

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

    init() {
        detectLocalIP()
        connectToServer()
        setupServerObservers()
        startAutomaticRoomRefresh()
        initializeLicensing()
        setupURLObservers()
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

        // Join the room by ID
        serverManager.joinRoom(roomId: roomId, username: username)
        currentScreen = .voiceChat
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
        serverManager.joinRoom(roomId: code, username: username)
        currentScreen = .voiceChat
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
            .sink { [weak self] connected in
                guard let self = self else { return }
                self.isConnected = connected
                if connected {
                    self.serverManager.getRooms()
                    self.tryAutoJoinLastRoom()
                }
            }
            .store(in: &cancellables)

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
            .sink { [weak self] updatedRooms in
                guard let self = self else { return }
                self.rooms = self.deduplicateRooms(updatedRooms)
                self.tryAutoJoinLastRoom()
            }
            .store(in: &cancellables)

        // Observe errors
        serverManager.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$errorMessage)

        // Listen for room joined notification
        NotificationCenter.default.addObserver(forName: .roomJoined, object: nil, queue: .main) { [weak self] notification in
            if let roomData = notification.object as? [String: Any],
               let roomId = roomData["roomId"] as? String ?? roomData["id"] as? String {
                // Find the room and set it as current
                if let room = self?.rooms.first(where: { $0.roomId == roomId }) {
                    self?.currentRoom = room
                    self?.currentScreen = .voiceChat
                    UserDefaults.standard.set(room.roomId, forKey: self?.lastJoinedRoomIdKey ?? "lastJoinedRoomId")
                    UserDefaults.standard.set(room.name, forKey: self?.lastJoinedRoomNameKey ?? "lastJoinedRoomName")
                    self?.pushActionNotification(
                        title: "Joined Room",
                        message: "You joined \(room.name)"
                    )
                } else if let self = self {
                    UserDefaults.standard.set(roomId, forKey: self.lastJoinedRoomIdKey)
                    let fallbackName = roomData["name"] as? String ?? "your room"
                    UserDefaults.standard.set(fallbackName, forKey: self.lastJoinedRoomNameKey)
                    self.pushActionNotification(
                        title: "Joined Room",
                        message: "You joined \(fallbackName)"
                    )
                }
            }
        }

        // Listen for navigation back to main menu
        NotificationCenter.default.addObserver(forName: .goToMainMenu, object: nil, queue: .main) { [weak self] _ in
            self?.currentScreen = .mainMenu
        }

        // Keep visible/join username aligned to Mastodon account when available.
        AuthenticationManager.shared.$currentUser
            .receive(on: DispatchQueue.main)
            .sink { [weak self] user in
                guard let self = self else { return }
                guard SettingsManager.shared.userNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                if let user {
                    let preferred = user.username.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !preferred.isEmpty {
                        self.username = preferred
                    } else {
                        let display = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !display.isEmpty {
                            self.username = display
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // Listen for update availability and optionally push a desktop notification.
        NotificationCenter.default.addObserver(forName: .updateAvailable, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            guard SettingsManager.shared.desktopNotifications else { return }
            guard SettingsManager.shared.notifyOnUpdateAvailable else { return }

            let version = (notification.object as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !version.isEmpty else { return }
            guard self.lastNotifiedUpdateVersion != version else { return }
            self.lastNotifiedUpdateVersion = version

            self.pushActionNotification(
                title: "There's a download available!",
                message: "Version \(version) is ready. Check for updates to download and make sure you're up to date."
            )
        }
    }

    private func tryAutoJoinLastRoom() {
        guard !hasTriedAutoJoinLastRoom else { return }
        guard isConnected else { return }
        guard SettingsManager.shared.autoJoinLastRoomOnLaunch else { return }
        guard currentRoom == nil else { return }

        let roomId = UserDefaults.standard.string(forKey: lastJoinedRoomIdKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !roomId.isEmpty else {
            hasTriedAutoJoinLastRoom = true
            return
        }

        hasTriedAutoJoinLastRoom = true

        if let room = rooms.first(where: { $0.roomId == roomId || $0.id == roomId }) {
            let joinName = SettingsManager.shared.userNickname.isEmpty ? username : SettingsManager.shared.userNickname
            serverManager.joinRoom(roomId: room.roomId, username: joinName)
            currentScreen = .voiceChat
            pushActionNotification(title: "Rejoining Room", message: "Rejoining \(room.name)")
            return
        }

        // Local fallback if the room list has not populated yet or room is currently hidden.
        let joinName = SettingsManager.shared.userNickname.isEmpty ? username : SettingsManager.shared.userNickname
        serverManager.joinRoom(roomId: roomId, username: joinName)
        currentScreen = .voiceChat
        let lastRoomName = UserDefaults.standard.string(forKey: lastJoinedRoomNameKey) ?? "last room"
        pushActionNotification(title: "Rejoining Room", message: "Rejoining \(lastRoomName)")
    }

    private func pushActionNotification(title: String, message: String) {
        guard SettingsManager.shared.desktopNotifications else { return }
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func deduplicateRooms(_ rooms: [Room]) -> [Room] {
        func normalized(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }

        var byKey: [String: Room] = [:]
        var orderedKeys: [String] = []

        for room in rooms {
            let primaryId = normalized(room.roomId)
            let fallbackId = normalized(room.id)
            let name = normalized(room.name)
            let desc = normalized(room.description)
            let server = normalized(room.serverURL.isEmpty ? room.serverName : room.serverURL)

            // Signature fallback handles duplicate logical rooms with mismatched IDs.
            let signature = "\(name)|\(desc)|\(server)|\(room.maxUsers)|\(room.isPrivate)"
            let key = !signature.hasPrefix("||") ? signature : (!primaryId.isEmpty ? primaryId : fallbackId)

            guard !key.isEmpty else { continue }
            if let existing = byKey[key] {
                // Keep the richer row when duplicates arrive.
                if room.userCount > existing.userCount || (existing.description.isEmpty && !room.description.isEmpty) {
                    byKey[key] = room
                }
            } else {
                byKey[key] = room
                orderedKeys.append(key)
            }
        }

        return orderedKeys.compactMap { byKey[$0] }
    }

    func refreshRooms() {
        serverManager.getRooms()
    }

    private func startAutomaticRoomRefresh() {
        roomRefreshCancellable = Timer.publish(every: 12, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard self.isConnected else { return }
                self.serverManager.getRooms()
            }
    }

    func exportRoomSnapshot() {
        guard let room = currentRoom else {
            pushActionNotification(title: "Room Snapshot", message: "Join a room first to export a snapshot.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "VoiceLink-Room-\(room.name.replacingOccurrences(of: " ", with: "_"))-Snapshot.json"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "room": [
                "id": room.roomId,
                "name": room.name,
                "description": room.description,
                "isPrivate": room.isPrivate,
                "userCount": room.userCount,
                "maxUsers": room.maxUsers,
                "serverURL": room.serverURL,
                "serverName": room.serverName
            ],
            "activeUsers": serverManager.currentRoomUsers.map { user in
                [
                    "id": user.id,
                    "username": user.username,
                    "isMuted": user.isMuted,
                    "isDeafened": user.isDeafened,
                    "isSpeaking": user.isSpeaking
                ]
            },
            "localUser": username
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
            pushActionNotification(title: "Room Snapshot Exported", message: "Saved \(destination.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            errorMessage = "Failed to export room snapshot: \(error.localizedDescription)"
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
    let roomId: String
    let name: String
    let description: String
    var userCount: Int
    let isPrivate: Bool
    let maxUsers: Int
    let serverURL: String
    let serverName: String

    init(id: String, roomId: String, name: String, description: String, userCount: Int, isPrivate: Bool, maxUsers: Int = 50, serverURL: String = "", serverName: String = "") {
        self.id = id
        self.roomId = roomId
        self.name = name
        self.description = description
        self.userCount = userCount
        self.isPrivate = isPrivate
        self.maxUsers = maxUsers
        self.serverURL = serverURL
        self.serverName = serverName
    }

    init(from serverRoom: ServerRoom) {
        self.id = serverRoom.id
        self.roomId = serverRoom.id
        self.name = serverRoom.name
        self.description = serverRoom.description
        self.userCount = serverRoom.userCount
        self.isPrivate = serverRoom.isPrivate
        self.maxUsers = serverRoom.maxUsers
        self.serverURL = ""
        self.serverName = ""
    }
}

// MARK: - Content View
struct ContentView: View {
    @EnvironmentObject var appState: AppState

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
    }
}

// MARK: - Main Menu View
struct MainMenuView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var localDiscovery: LocalServerDiscovery
    @ObservedObject var healthMonitor = ConnectionHealthMonitor.shared
    @State private var roomViewMode: RoomViewMode = .list
    @State private var roomSortMode: RoomSortMode = .mostUsers
    @State private var selectedRoomForDetails: Room?

    enum RoomViewMode: String, CaseIterable, Identifiable {
        case list = "List"
        case grid = "Grid"
        case column = "Column"
        case table = "Table"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .list: return "list.bullet"
            case .grid: return "square.grid.2x2"
            case .column: return "rectangle.split.3x1"
            case .table: return "tablecells"
            }
        }
    }

    enum RoomSortMode: String, CaseIterable, Identifiable {
        case mostUsers = "Most Users"
        case leastUsers = "Least Users"
        case nameAZ = "Name A-Z"
        case nameZA = "Name Z-A"

        var id: String { rawValue }
    }

    var displayedRooms: [Room] {
        // AppState already deduplicates mixed server responses.
        let uniqueRooms = appState.rooms

        switch roomSortMode {
        case .mostUsers:
            return uniqueRooms.sorted { lhs, rhs in
                if lhs.userCount == rhs.userCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.userCount > rhs.userCount
            }
        case .leastUsers:
            return uniqueRooms.sorted { lhs, rhs in
                if lhs.userCount == rhs.userCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.userCount < rhs.userCount
            }
        case .nameAZ:
            return uniqueRooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameZA:
            return uniqueRooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
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

    var body: some View {
        HStack(spacing: 0) {
            // Main Content
            VStack(spacing: 30) {
                // Header
                VStack(spacing: 10) {
                    Text("VoiceLink")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)

                    Text("Advanced P2P Voice Chat with 3D Audio")
                        .font(.title3)
                        .foregroundColor(.gray)
                }
                .padding(.top, 40)

                // Server Status Bar
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text("Server: \(statusText)")
                        .foregroundColor(.white.opacity(0.8))

                    if appState.isConnected {
                        Text("(\(appState.serverManager.connectedServer))")
                            .foregroundColor(.white.opacity(0.6))
                            .font(.caption)
                    }

                    // Sync Mode Filter
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

                    Spacer()

                    Text("Local IP: \(appState.localIP)")
                        .foregroundColor(.white.opacity(0.6))
                        .font(.caption)
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
                HStack {
                    Text("Available Rooms")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    Picker("View", selection: $roomViewMode) {
                        ForEach(RoomViewMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 150)

                    Picker("Sort", selection: $roomSortMode) {
                        ForEach(RoomSortMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                }

                ScrollView {
                    if roomViewMode == .list {
                        LazyVStack(spacing: 12) {
                            ForEach(displayedRooms) { room in
                                RoomCard(room: room) {
                                    // Join room via server
                                    appState.serverManager.joinRoom(
                                        roomId: room.roomId,
                                        username: appState.username
                                    )
                                    appState.currentRoom = room
                                    appState.currentScreen = .voiceChat
                                } onDetails: {
                                    selectedRoomForDetails = room
                                }
                            }
                        }
                    } else if roomViewMode == .grid {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(displayedRooms) { room in
                                RoomCard(room: room) {
                                    appState.serverManager.joinRoom(
                                        roomId: room.roomId,
                                        username: appState.username
                                    )
                                    appState.currentRoom = room
                                    appState.currentScreen = .voiceChat
                                } onDetails: {
                                    selectedRoomForDetails = room
                                }
                            }
                        }
                    } else if roomViewMode == .table {
                        Table(displayedRooms) {
                            TableColumn("Room") { room in
                                Text(room.name)
                                    .foregroundColor(.white)
                            }
                            TableColumn("Users") { room in
                                Text("\(room.userCount)")
                                    .foregroundColor(.white.opacity(0.9))
                            }
                            TableColumn("Type") { room in
                                Text(room.isPrivate ? "Private" : "Public")
                                    .foregroundColor(room.isPrivate ? .yellow : .green)
                            }
                            TableColumn("Server") { room in
                                Text(room.serverName.isEmpty ? "Main" : room.serverName)
                                    .foregroundColor(.blue.opacity(0.9))
                            }
                            TableColumn("Join") { room in
                                Button("Join") {
                                    appState.serverManager.joinRoom(
                                        roomId: room.roomId,
                                        username: appState.username
                                    )
                                    appState.currentRoom = room
                                    appState.currentScreen = .voiceChat
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                        .frame(minHeight: 220)
                    } else {
                        let leftColumn = Array(displayedRooms.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element })
                        let rightColumn = Array(displayedRooms.enumerated().filter { $0.offset % 2 != 0 }.map { $0.element })

                        HStack(alignment: .top, spacing: 12) {
                            LazyVStack(spacing: 12) {
                                ForEach(leftColumn) { room in
                                    RoomCard(room: room) {
                                        appState.serverManager.joinRoom(
                                            roomId: room.roomId,
                                            username: appState.username
                                        )
                                        appState.currentRoom = room
                                        appState.currentScreen = .voiceChat
                                    } onDetails: {
                                        selectedRoomForDetails = room
                                    }
                                }
                            }
                            LazyVStack(spacing: 12) {
                                ForEach(rightColumn) { room in
                                    RoomCard(room: room) {
                                        appState.serverManager.joinRoom(
                                            roomId: room.roomId,
                                            username: appState.username
                                        )
                                        appState.currentRoom = room
                                        appState.currentScreen = .voiceChat
                                    } onDetails: {
                                        selectedRoomForDetails = room
                                    }
                                }
                            }
                        }
                    }

                        if displayedRooms.isEmpty && appState.isConnected {
                            Text("No rooms available. Create one!")
                                .foregroundColor(.gray)
                                .padding()
                        } else if displayedRooms.isEmpty && !appState.isConnected {
                            Text("Connect to server to see rooms")
                                .foregroundColor(.gray)
                                .padding()
                        }
                }
                .frame(maxHeight: 300)
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
                                    Text("You are logged in as @\(user.username) on instance host \(instance)")
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                        .lineLimit(2)
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
                // Connection Health Panel
                ConnectionHealthView()
                    .frame(maxWidth: 280)

                // Servers Button - navigate to servers screen instead of sheet
                Button(action: { appState.currentScreen = .servers }) {
                    HStack {
                        Image(systemName: "server.rack")
                        Text("My Servers")
                        Spacer()
                        Text("\(PairingManager.shared.linkedServers.count)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.3))
                            .cornerRadius(10)
                    }
                    .padding()
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .accessibilityLabel("My Servers. \(PairingManager.shared.linkedServers.count) servers linked.")
                .accessibilityHint("Opens server management for linked and owned servers")

                Spacer()

                // Settings tip at bottom of sidebar
                Text("Use Command Comma to open settings.")
                    .font(.caption)
                    .foregroundColor(.gray.opacity(0.6))
                    .padding(.bottom, 8)
            }
            .frame(width: 280)
            .padding()
            .background(Color.black.opacity(0.2))
        }
        .sheet(item: $selectedRoomForDetails) { room in
            RoomDetailsSheet(room: room)
        }
    }
}

// MARK: - Room Card
struct RoomCard: View {
    let room: Room
    let onJoin: () -> Void
    let onDetails: () -> Void

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

                    if !room.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("• \(room.description)")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                }

                if !room.serverName.isEmpty {
                    Text(room.serverName)
                        .font(.caption2)
                        .foregroundColor(.blue.opacity(0.9))
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                Text("\(room.userCount)")
            }
            .foregroundColor(.white.opacity(0.6))
            .font(.caption)

            Button("Join") {
                onJoin()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding()
        .background(Color.white.opacity(0.1))
        .cornerRadius(12)
        .contextMenu {
            Button {
                onJoin()
            } label: {
                Label("Join Room", systemImage: "arrow.right.circle")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(room.roomId, forType: .string)
            } label: {
                Label("Copy Room Code", systemImage: "doc.on.doc")
            }

            Button {
                let url = "voicelink://join/\(room.roomId)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Label("Copy Join Link", systemImage: "link")
            }

            Button {
                onDetails()
            } label: {
                Label("Room Details", systemImage: "info.circle")
            }
        }
    }
}

struct RoomDetailsSheet: View {
    let room: Room
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(room.name)
                .font(.title2)
                .fontWeight(.bold)
            Text("Room Code: \(room.roomId)")
                .font(.callout)
            if !room.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(room.description)
                    .font(.body)
            }
            Text("Users: \(room.userCount)/\(room.maxUsers)")
                .font(.callout)
            Text("Type: \(room.isPrivate ? "Private" : "Public")")
                .font(.callout)
            if !room.serverName.isEmpty {
                Text("Server: \(room.serverName)")
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
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
                    let code = roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !code.isEmpty else { return }
                    appState.serverManager.joinRoom(roomId: code, username: appState.username)
                    if let matched = appState.rooms.first(where: { $0.roomId == code || $0.id == code }) {
                        appState.currentRoom = matched
                    } else {
                        appState.currentRoom = Room(
                            id: code,
                            roomId: code,
                            name: "Room \(code)",
                            description: "Joined by code",
                            userCount: 0,
                            isPrivate: false
                        )
                    }
                    appState.currentScreen = .voiceChat
                }
                .buttonStyle(.borderedProminent)
                .disabled(roomCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !appState.isConnected)

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
    @State private var isMuted = false
    @State private var isDeafened = false
    @State private var messageText = ""
    @State private var showChat = true

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
                    }
                    Spacer()

                    Button("Leave") {
                        let roomName = appState.currentRoom?.name ?? "room"
                        appState.serverManager.leaveRoom()
                        appState.currentRoom = nil
                        appState.currentScreen = .mainMenu
                        if SettingsManager.shared.desktopNotifications {
                            let notification = NSUserNotification()
                            notification.title = "Left Room"
                            notification.informativeText = "You left \(roomName)"
                            NSUserNotificationCenter.default.deliver(notification)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding()

                // Users in room
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Users in Room")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(appState.serverManager.currentRoomUsers.count + 1)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            // Show yourself
                            UserRow(
                                username: appState.username + " (You)",
                                serverName: appState.serverManager.connectedServer.isEmpty ? "Current" : appState.serverManager.connectedServer,
                                isMuted: isMuted,
                                isDeafened: isDeafened,
                                isSpeaking: false
                            )

                            // Show other users from server
                            ForEach(appState.serverManager.currentRoomUsers) { user in
                                UserRow(
                                    username: user.username,
                                    serverName: user.serverName,
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
                                      label: isDeafened ? "Undeafen Output" : "Deafen Output",
                                      isActive: !isDeafened) {
                        isDeafened.toggle()
                        appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
                        // Play button click sound
                        AppSoundManager.shared.playSound(.buttonClick)
                        // Announce state change
                        AccessibilityManager.shared.announceAudioStatus(isDeafened ? "deafened" : "undeafened")
                    }
                    .accessibilityLabel(isDeafened ? "Undeafen Output" : "Deafen Output")
                    .accessibilityHint("Toggle audio output. Currently \(isDeafened ? "deafened - you cannot hear others" : "undeafened - you can hear others")")

                    VoiceControlButton(icon: showChat ? "bubble.left.fill" : "bubble.left",
                                      label: showChat ? "Hide Chat" : "Show Chat",
                                      isActive: showChat) {
                        showChat.toggle()
                    }

                    VoiceControlButton(icon: "tray.full",
                                      label: "Inbox",
                                      isActive: false) {
                        appState.currentScreen = .settings
                        NotificationCenter.default.post(name: .openNotificationInbox, object: nil)
                    }
                }
                .padding(.bottom, 20)

                // Keyboard shortcuts hint
                HStack(spacing: 15) {
                    Text("⌘M Mute Microphone")
                    Text("⌘D Deafen Output")
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
    let serverName: String?
    let isMuted: Bool
    let isDeafened: Bool
    let isSpeaking: Bool

    @State private var showControls = false
    @State private var userVolume: Double = 1.0
    @State private var isUserMuted = false
    @State private var isSoloed = false

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack {
                // Speaking indicator
                Circle()
                    .fill(isSpeaking ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(username)
                        .foregroundColor(.white)
                    if let serverName = serverName, !serverName.isEmpty {
                        Text(serverName)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                Spacer()

                if isMuted {
                    Image(systemName: "mic.slash.fill")
                        .foregroundColor(.red)
                }
                if isDeafened {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundColor(.red)
                }

                // Expand/collapse button
                Button(action: { showControls.toggle() }) {
                    Image(systemName: showControls ? "chevron.up" : "chevron.down")
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
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
                        Slider(value: $userVolume, in: 0...1)
                            .frame(maxWidth: .infinity)
                        Text("\(Int(userVolume * 100))%")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 35)
                    }

                    // Mute and Solo buttons
                    HStack(spacing: 12) {
                        Button(action: { isUserMuted.toggle() }) {
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

                        Button(action: { isSoloed.toggle() }) {
                            HStack {
                                Image(systemName: isSoloed ? "star.fill" : "star")
                                Text(isSoloed ? "Unsolo" : "Solo")
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSoloed ? Color.yellow.opacity(0.3) : Color.gray.opacity(0.2))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
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
    @Published var autoJoinLastRoomOnLaunch: Bool = false
    @Published var connectionTimeout: Double = 30

    // PTT Settings
    @Published var pttEnabled: Bool = false
    @Published var pttKey: String = "Space"

    // Notifications
    @Published var soundNotifications: Bool = true
    @Published var desktopNotifications: Bool = true
    @Published var notifyOnJoin: Bool = true
    @Published var notifyOnLeave: Bool = true
    @Published var notifyOnUpdateAvailable: Bool = true

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
    @Published var showLocalServerControls: Bool = false

    // Profile Settings
    @Published var userNickname: String = ""

    // Available devices
    @Published var availableInputDevices: [String] = ["Default"]
    @Published var availableOutputDevices: [String] = ["Default"]

    init() {
        loadSettings()
        detectAudioDevices()
    }

    private func boolSetting(_ key: String, default defaultValue: Bool) -> Bool {
        if let value = UserDefaults.standard.object(forKey: key) as? Bool {
            return value
        }
        return defaultValue
    }

    func loadSettings() {
        if let mode = UserDefaults.standard.string(forKey: "syncMode"),
           let syncMode = SyncMode(rawValue: mode) {
            self.syncMode = syncMode
        }

        inputVolume = UserDefaults.standard.double(forKey: "inputVolume")
        if inputVolume == 0 { inputVolume = 0.8 }

        outputVolume = UserDefaults.standard.double(forKey: "outputVolume")
        if outputVolume == 0 { outputVolume = 0.8 }

        noiseSuppression = boolSetting("noiseSuppression", default: true)
        echoCancellation = boolSetting("echoCancellation", default: true)
        autoGainControl = boolSetting("autoGainControl", default: true)
        autoConnect = boolSetting("autoConnect", default: true)
        preferLocalServer = boolSetting("preferLocalServer", default: true)
        reconnectOnDisconnect = boolSetting("reconnectOnDisconnect", default: true)
        autoJoinLastRoomOnLaunch = boolSetting("autoJoinLastRoomOnLaunch", default: false)
        pttEnabled = boolSetting("pttEnabled", default: false)
        spatialAudioEnabled = boolSetting("spatialAudioEnabled", default: true)
        soundNotifications = boolSetting("soundNotifications", default: true)
        desktopNotifications = boolSetting("desktopNotifications", default: true)
        notifyOnJoin = boolSetting("notifyOnJoin", default: true)
        notifyOnLeave = boolSetting("notifyOnLeave", default: true)
        notifyOnUpdateAvailable = boolSetting("notifyOnUpdateAvailable", default: true)
        allowDirectMessages = boolSetting("allowDirectMessages", default: true)

        // UI settings
        showAudioControlsOnStartup = UserDefaults.standard.object(forKey: "showAudioControlsOnStartup") as? Bool ?? true
        showLocalServerControls = boolSetting("showLocalServerControls", default: false)

        // Profile settings
        userNickname = UserDefaults.standard.string(forKey: "userNickname") ?? ""

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
            notifyOnUpdateAvailable = true
            showOnlineStatus = true
            allowDirectMessages = true
            spatialAudioEnabled = true
            reconnectOnDisconnect = true
            showAudioControlsOnStartup = true
            showLocalServerControls = false
            autoJoinLastRoomOnLaunch = false
            UserDefaults.standard.set(true, forKey: "settingsInitialized")
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(syncMode.rawValue, forKey: "syncMode")
        UserDefaults.standard.set(inputVolume, forKey: "inputVolume")
        UserDefaults.standard.set(outputVolume, forKey: "outputVolume")
        UserDefaults.standard.set(noiseSuppression, forKey: "noiseSuppression")
        UserDefaults.standard.set(echoCancellation, forKey: "echoCancellation")
        UserDefaults.standard.set(autoGainControl, forKey: "autoGainControl")
        UserDefaults.standard.set(autoConnect, forKey: "autoConnect")
        UserDefaults.standard.set(preferLocalServer, forKey: "preferLocalServer")
        UserDefaults.standard.set(reconnectOnDisconnect, forKey: "reconnectOnDisconnect")
        UserDefaults.standard.set(autoJoinLastRoomOnLaunch, forKey: "autoJoinLastRoomOnLaunch")
        UserDefaults.standard.set(pttEnabled, forKey: "pttEnabled")
        UserDefaults.standard.set(spatialAudioEnabled, forKey: "spatialAudioEnabled")
        UserDefaults.standard.set(soundNotifications, forKey: "soundNotifications")
        UserDefaults.standard.set(desktopNotifications, forKey: "desktopNotifications")
        UserDefaults.standard.set(notifyOnJoin, forKey: "notifyOnJoin")
        UserDefaults.standard.set(notifyOnLeave, forKey: "notifyOnLeave")
        UserDefaults.standard.set(notifyOnUpdateAvailable, forKey: "notifyOnUpdateAvailable")
        UserDefaults.standard.set(allowDirectMessages, forKey: "allowDirectMessages")

        // UI settings
        UserDefaults.standard.set(showAudioControlsOnStartup, forKey: "showAudioControlsOnStartup")
        UserDefaults.standard.set(showLocalServerControls, forKey: "showLocalServerControls")

        // Profile settings
        UserDefaults.standard.set(userNickname, forKey: "userNickname")

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

        availableInputDevices = Array(Set(inputDevices)).sorted()
        availableOutputDevices = Array(Set(outputDevices)).sorted()
    }
}

// MARK: - Pushover Settings Manager
@MainActor
class PushoverSettingsManager: ObservableObject {
    static let shared = PushoverSettingsManager()

    @Published var enabled: Bool = false
    @Published var appToken: String = ""
    @Published var userKey: String = ""
    @Published var device: String = ""
    @Published var sound: String = ""
    @Published var titlePrefix: String = "VoiceLink"
    @Published var minDeferredSeconds: Int = 15
    @Published var maxDeferredSeconds: Int = 120
    @Published var triggerRoomCreated: Bool = false
    @Published var triggerRoomJoined: Bool = false
    @Published var triggerRoomAnnouncement: Bool = true
    @Published var triggerIncomingWebhook: Bool = true
    @Published var triggerAdminNotice: Bool = true
    @Published var pendingActivationUntil: String?
    @Published var customTitle: String = ""
    @Published var customMessage: String = ""
    @Published var customURL: String = ""
    @Published var customURLTitle: String = ""
    @Published var incomingNotifications: [IncomingPushoverNotification] = []
    @Published var isLoading: Bool = false
    @Published var isSaving: Bool = false
    @Published var isSending: Bool = false
    @Published var statusMessage: String?

    private init() {}

    private func apiBase() -> String {
        ServerManager.shared.baseURL ?? ServerManager.mainServer
    }

    func loadStatus() {
        guard !isLoading else { return }
        isLoading = true
        statusMessage = nil

        guard let url = URL(string: "\(apiBase())/api/notifications/pushover/status") else {
            isLoading = false
            statusMessage = "Pushover status URL is invalid."
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false

                if let error {
                    self.statusMessage = "Failed to load Pushover: \(error.localizedDescription)"
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool,
                      success,
                      let config = json["config"] as? [String: Any] else {
                    self.statusMessage = "Failed to load Pushover configuration."
                    return
                }

                self.enabled = config["enabled"] as? Bool ?? false
                self.appToken = config["appToken"] as? String ?? ""
                self.userKey = config["userKey"] as? String ?? ""
                self.device = config["device"] as? String ?? ""
                self.sound = config["sound"] as? String ?? ""
                self.titlePrefix = (config["titlePrefix"] as? String) ?? "VoiceLink"
                self.minDeferredSeconds = config["minDeferredSeconds"] as? Int ?? 15
                self.maxDeferredSeconds = config["maxDeferredSeconds"] as? Int ?? 120
                if let triggerEvents = config["triggerEvents"] as? [String: Any] {
                    self.triggerRoomCreated = triggerEvents["roomCreated"] as? Bool ?? false
                    self.triggerRoomJoined = triggerEvents["roomJoined"] as? Bool ?? false
                    self.triggerRoomAnnouncement = triggerEvents["roomAnnouncement"] as? Bool ?? true
                    self.triggerIncomingWebhook = triggerEvents["incomingWebhook"] as? Bool ?? true
                    self.triggerAdminNotice = triggerEvents["adminNotice"] as? Bool ?? true
                }
                self.pendingActivationUntil = config["pendingActivationUntil"] as? String
                self.statusMessage = "Loaded Pushover configuration."
            }
        }.resume()
    }

    func saveConfig() {
        guard !isSaving else { return }
        isSaving = true
        statusMessage = nil

        guard let url = URL(string: "\(apiBase())/api/notifications/pushover/config") else {
            isSaving = false
            statusMessage = "Pushover config URL is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "enabled": enabled,
            "appToken": appToken.trimmingCharacters(in: .whitespacesAndNewlines),
            "userKey": userKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "device": device.trimmingCharacters(in: .whitespacesAndNewlines),
            "sound": sound.trimmingCharacters(in: .whitespacesAndNewlines),
            "titlePrefix": titlePrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            "minDeferredSeconds": max(1, minDeferredSeconds),
            "maxDeferredSeconds": max(max(1, minDeferredSeconds), maxDeferredSeconds),
            "triggerEvents": [
                "roomCreated": triggerRoomCreated,
                "roomJoined": triggerRoomJoined,
                "roomAnnouncement": triggerRoomAnnouncement,
                "incomingWebhook": triggerIncomingWebhook,
                "adminNotice": triggerAdminNotice
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isSaving = false

                if let error {
                    self.statusMessage = "Failed to save Pushover: \(error.localizedDescription)"
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool else {
                    self.statusMessage = "Failed to save Pushover configuration."
                    return
                }

                if success {
                    self.statusMessage = "Pushover settings saved."
                    if let config = json["config"] as? [String: Any] {
                        self.pendingActivationUntil = config["pendingActivationUntil"] as? String
                    }
                } else {
                    self.statusMessage = (json["error"] as? String) ?? "Pushover save failed."
                }
            }
        }.resume()
    }

    func testNotification() {
        guard let url = URL(string: "\(apiBase())/api/notifications/pushover/test") else {
            statusMessage = "Pushover test URL is invalid."
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": "\(titlePrefix.isEmpty ? "VoiceLink" : titlePrefix) Test",
            "message": "Pushover test from VoiceLink macOS app."
        ])

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.statusMessage = "Pushover test failed: \(error.localizedDescription)"
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool else {
                    self.statusMessage = "Pushover test failed."
                    return
                }

                self.statusMessage = success ? "Pushover test sent." : ((json["error"] as? String) ?? "Pushover test failed.")
            }
        }.resume()
    }

    func sendCustomNotification() {
        guard !isSending else { return }
        isSending = true
        statusMessage = nil

        guard let url = URL(string: "\(apiBase())/api/notifications/pushover/send") else {
            isSending = false
            statusMessage = "Custom send URL is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let title = customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(titlePrefix.isEmpty ? "VoiceLink" : titlePrefix) Event"
            : customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = customMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "VoiceLink notification"
            : customMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": title,
            "message": message,
            "url": customURL.trimmingCharacters(in: .whitespacesAndNewlines),
            "urlTitle": customURLTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        ])

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isSending = false

                if let error {
                    self.statusMessage = "Custom send failed: \(error.localizedDescription)"
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool else {
                    self.statusMessage = "Custom send failed."
                    return
                }
                self.statusMessage = success ? "Custom Pushover notification sent." : ((json["error"] as? String) ?? "Custom send failed.")
                if success {
                    self.loadIncoming()
                }
            }
        }.resume()
    }

    func loadIncoming() {
        guard let url = URL(string: "\(apiBase())/api/notifications/incoming?limit=25") else {
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["notifications"] as? [[String: Any]] else {
                    return
                }

                self.incomingNotifications = items.map { item in
                    let payload = item["payload"] as? [String: Any]
                    let htmlFromPayload = payload?["html"] as? String
                    let linkURL = (payload?["url"] as? String) ?? ""
                    let linkTitle = (payload?["urlTitle"] as? String) ?? ""
                    let rawMessage = (item["message"] as? String) ?? ""
                    let htmlBody = htmlFromPayload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? (htmlFromPayload ?? "")
                        : Self.defaultHTMLBody(title: (item["title"] as? String) ?? "Notification", message: rawMessage, linkURL: linkURL, linkTitle: linkTitle)
                    return IncomingPushoverNotification(
                        id: String(describing: item["id"] ?? UUID().uuidString),
                        source: (item["source"] as? String) ?? "unknown",
                        title: (item["title"] as? String) ?? "Notification",
                        message: rawMessage,
                        level: (item["level"] as? String) ?? "info",
                        htmlBody: htmlBody,
                        linkURL: linkURL,
                        linkTitle: linkTitle,
                        createdAt: (item["createdAt"] as? String) ?? ((item["timestamp"] as? String) ?? "")
                    )
                }
            }
        }.resume()
    }

    func updateIncomingNotification(id: String, title: String, message: String, htmlBody: String, linkURL: String, linkTitle: String, completion: ((Bool, String?) -> Void)? = nil) {
        guard let url = URL(string: "\(apiBase())/api/notifications/incoming/\(id)") else {
            completion?(false, "Invalid update URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": title,
            "message": message,
            "payload": [
                "html": htmlBody,
                "url": linkURL,
                "urlTitle": linkTitle
            ]
        ])
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                if let error {
                    completion?(false, error.localizedDescription)
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool else {
                    completion?(false, "Update failed")
                    return
                }
                if success {
                    self?.loadIncoming()
                    completion?(true, nil)
                } else {
                    completion?(false, (json["error"] as? String) ?? "Update failed")
                }
            }
        }.resume()
    }

    func deleteIncomingNotification(id: String, completion: ((Bool, String?) -> Void)? = nil) {
        guard let url = URL(string: "\(apiBase())/api/notifications/incoming/\(id)") else {
            completion?(false, "Invalid delete URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                if let error {
                    completion?(false, error.localizedDescription)
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool else {
                    completion?(false, "Delete failed")
                    return
                }
                if success {
                    self?.incomingNotifications.removeAll { $0.id == id }
                    completion?(true, nil)
                } else {
                    completion?(false, (json["error"] as? String) ?? "Delete failed")
                }
            }
        }.resume()
    }

    private static func defaultHTMLBody(title: String, message: String, linkURL: String, linkTitle: String) -> String {
        let escapedTitle = escapeHTML(title)
        let escapedMessage = escapeHTML(message).replacingOccurrences(of: "\n", with: "<br/>")
        let escapedLinkURL = escapeHTML(linkURL)
        let escapedLinkTitle = escapeHTML(linkTitle.isEmpty ? linkURL : linkTitle)
        let linkLine = linkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "<p><a href=\"\(escapedLinkURL)\">\(escapedLinkTitle)</a></p>"
        return """
        <html><body style="font-family: -apple-system; padding: 14px;">
        <h3>\(escapedTitle)</h3>
        <p>\(escapedMessage)</p>
        \(linkLine)
        </body></html>
        """
    }

    private static func escapeHTML(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

struct IncomingPushoverNotification: Identifiable {
    let id: String
    let source: String
    let title: String
    let message: String
    let level: String
    let htmlBody: String
    let linkURL: String
    let linkTitle: String
    let createdAt: String
}

extension Notification.Name {
    static let syncModeChanged = Notification.Name("syncModeChanged")
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var serverProfiles = ServerProfilesManager.shared
    @StateObject private var pushover = PushoverSettingsManager.shared
    @State private var selectedTab: SettingsTab = .audio
    @State private var isSoundTestPlaying = false
    @State private var isExportingData = false
    @State private var dataExportStatus: String?
    @State private var newServerName: String = ""
    @State private var newServerURL: String = ""
    @State private var serverProfileError: String?
    @State private var didLoadPushover = false
    @State private var selectedInboxNotificationId: String?
    @State private var inboxEditorTitle: String = ""
    @State private var inboxEditorMessage: String = ""
    @State private var inboxEditorHTML: String = ""
    @State private var inboxEditorLinkURL: String = ""
    @State private var inboxEditorLinkTitle: String = ""
    @State private var inboxEditorStatus: String?

    enum SettingsTab: String, CaseIterable {
        case profile = "Profile & Authentication"
        case audio = "Audio"
        case sync = "Sync & Filters"
        case fileSharing = "File Sharing"
        case notifications = "Notifications"
        case notificationInbox = "Notification Inbox"
        case privacy = "Privacy"
        case advanced = "Advanced"
    }

    private var exportButtonLabel: String {
        isExportingData ? "Exporting..." : "Export My Data"
    }

    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases.filter { tab in
            if tab == .notificationInbox && !AdminServerManager.shared.isAdmin {
                return false
            }
            return true
        }
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
                .accessibilityLabel("Back to main menu")
                .accessibilityHint("Saves settings and returns to the main screen")
                .help("Saves settings and returns to the main screen")

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
                    ForEach(visibleTabs, id: \.self) { tab in
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
                        .accessibilityLabel("\(tab.rawValue) settings")
                        .accessibilityHint("Opens the \(tab.rawValue) settings panel")
                        .help("Opens the \(tab.rawValue) settings panel")
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
                        case .notificationInbox:
                            notificationInboxSettings
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
        .onReceive(NotificationCenter.default.publisher(for: .openNotificationInbox)) { _ in
            selectedTab = .notificationInbox
            if AdminServerManager.shared.isAdmin {
                pushover.loadIncoming()
            }
        }
    }

    func iconForTab(_ tab: SettingsTab) -> String {
        switch tab {
        case .profile: return "person.circle"
        case .audio: return "speaker.wave.2"
        case .sync: return "arrow.triangle.2.circlepath"
        case .fileSharing: return "folder.badge.person.crop"
        case .notifications: return "bell"
        case .notificationInbox: return "tray.full"
        case .privacy: return "lock.shield"
        case .advanced: return "gear"
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
                    .accessibilityLabel("Nickname")
                    .accessibilityHint("Sets the display name other users hear and see in rooms")
                    .help("Sets the display name other users hear and see in rooms")
                Text("This nickname will be displayed to other users in voice rooms")
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
            .accessibilityHint("Choose the microphone used for voice chat input")
            .help("Choose the microphone used for voice chat input")

            HStack {
                Text("Input Volume")
                Slider(value: $settings.inputVolume, in: 0...1)
                    .accessibilityLabel("Input volume")
                    .accessibilityHint("Adjusts microphone level before sending audio")
                    .help("Adjusts microphone level before sending audio")
                Text("\(Int(settings.inputVolume * 100))%")
                    .frame(width: 40)
            }
        }

        SettingsSection(title: "Output Device") {
            Picker("Speakers/Headphones", selection: $settings.outputDevice) {
                ForEach(settings.availableOutputDevices, id: \.self) { device in
                    Text(device).tag(device)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("Choose the playback device for room audio")
            .help("Choose the playback device for room audio")

            HStack {
                Text("Output Volume")
                Slider(value: $settings.outputVolume, in: 0...1)
                    .accessibilityLabel("Output volume")
                    .accessibilityHint("Adjusts speaker or headphone playback level")
                    .help("Adjusts speaker or headphone playback level")
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
            .accessibilityLabel(isSoundTestPlaying ? "Stop sound test" : "Test my sound")
            .accessibilityHint("Plays or stops the your-sound-test audio file")
            .help("Plays or stops the your-sound-test audio file")
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
                .accessibilityHint("When enabled, audio control panel opens by default")
                .help("When enabled, audio control panel opens by default")
        }

        SettingsSection(title: "Startup & Rejoin") {
            Toggle("Auto-Join Last Room on Launch", isOn: $settings.autoJoinLastRoomOnLaunch)
                .onChange(of: settings.autoJoinLastRoomOnLaunch) { _ in
                    settings.saveSettings()
                }
                .accessibilityHint("On app launch, rejoins your most recent room using server data with local fallback")
                .help("On app launch, rejoins your most recent room using server data with local fallback")
        }

        SettingsSection(title: "Push-to-Talk") {
            Toggle("Enable PTT Mode", isOn: $settings.pttEnabled)
                .accessibilityHint("When enabled, hold your push-to-talk key to transmit")
                .help("When enabled, hold your push-to-talk key to transmit")
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
                    .accessibilityHint("Changes your push-to-talk key binding")
                    .help("Changes your push-to-talk key binding")
                }
            }
        }
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
        let isAdmin = AdminServerManager.shared.isAdmin

        SettingsSection(title: "Sound Notifications") {
            Toggle("Enable sound notifications", isOn: $settings.soundNotifications)
                .onChange(of: settings.soundNotifications) { _ in
                    settings.saveSettings()
                }
                .accessibilityHint("Plays UI sounds for room and chat events")
                .help("Plays UI sounds for room and chat events")
            Toggle("Play sound when user joins", isOn: $settings.notifyOnJoin)
                .onChange(of: settings.notifyOnJoin) { _ in
                    settings.saveSettings()
                }
                .accessibilityHint("Plays a sound when someone enters your room")
                .help("Plays a sound when someone enters your room")
            Toggle("Play sound when user leaves", isOn: $settings.notifyOnLeave)
                .onChange(of: settings.notifyOnLeave) { _ in
                    settings.saveSettings()
                }
                .accessibilityHint("Plays a sound when someone leaves your room")
                .help("Plays a sound when someone leaves your room")
        }

        SettingsSection(title: "Desktop Notifications") {
            Toggle("Enable desktop notifications", isOn: $settings.desktopNotifications)
                .onChange(of: settings.desktopNotifications) { _ in
                    settings.saveSettings()
                }
                .accessibilityHint("Shows macOS notifications for important actions")
                .help("Shows macOS notifications for important actions")

            Toggle("Notify when updates are available", isOn: $settings.notifyOnUpdateAvailable)
                .onChange(of: settings.notifyOnUpdateAvailable) { _ in
                    settings.saveSettings()
                }
                .accessibilityHint("Shows a desktop notification when a new VoiceLink update is detected")
                .help("Shows a desktop notification when a new VoiceLink update is detected")

            Button("Test Notification") {
                let notification = NSUserNotification()
                notification.title = "VoiceLink"
                notification.informativeText = "Test notification"
                NSUserNotificationCenter.default.deliver(notification)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Shows a sample desktop notification")
            .help("Shows a sample desktop notification")
        }

        if isAdmin {
            SettingsSection(title: "Pushover (Admin Only)") {
                Toggle("Enable Pushover", isOn: $pushover.enabled)
                    .accessibilityHint("Enable sending VoiceLink notifications through Pushover")
                    .help("Enable sending VoiceLink notifications through Pushover")

                TextField("App Token", text: $pushover.appToken)
                    .textFieldStyle(.roundedBorder)
                TextField("User Key", text: $pushover.userKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Device (optional)", text: $pushover.device)
                    .textFieldStyle(.roundedBorder)
                TextField("Sound (optional)", text: $pushover.sound)
                    .textFieldStyle(.roundedBorder)
                TextField("Title Prefix", text: $pushover.titlePrefix)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("Min Delay")
                    Stepper(value: $pushover.minDeferredSeconds, in: 1...600) {
                        Text("\(pushover.minDeferredSeconds) sec")
                    }
                    Spacer()
                    Text("Max Delay")
                    Stepper(value: $pushover.maxDeferredSeconds, in: 1...3600) {
                        Text("\(pushover.maxDeferredSeconds) sec")
                    }
                }

                Divider()
                Text("Auto-Send Event Triggers")
                    .font(.subheadline)
                Toggle("Room Created", isOn: $pushover.triggerRoomCreated)
                Toggle("Room Joined", isOn: $pushover.triggerRoomJoined)
                Toggle("Room Announcement", isOn: $pushover.triggerRoomAnnouncement)
                Toggle("Incoming Webhook", isOn: $pushover.triggerIncomingWebhook)
                Toggle("Admin Notices", isOn: $pushover.triggerAdminNotice)

                HStack {
                    Button("Load") {
                        pushover.loadStatus()
                        pushover.loadIncoming()
                    }
                    .buttonStyle(.bordered)
                    .disabled(pushover.isLoading || pushover.isSaving)

                    Button(pushover.isSaving ? "Saving..." : "Save Pushover Keys") {
                        pushover.saveConfig()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pushover.isLoading || pushover.isSaving)

                    Button("Send Test") {
                        pushover.testNotification()
                    }
                    .buttonStyle(.bordered)
                    .disabled(pushover.isLoading || pushover.isSaving)
                }

                Divider()
                Text("Send Custom Notification")
                    .font(.subheadline)
                TextField("Title", text: $pushover.customTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("Message", text: $pushover.customMessage)
                    .textFieldStyle(.roundedBorder)
                TextField("Link URL (optional)", text: $pushover.customURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Link Label (optional)", text: $pushover.customURLTitle)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button(pushover.isSending ? "Sending..." : "Send Custom") {
                        pushover.sendCustomNotification()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pushover.isLoading || pushover.isSaving || pushover.isSending)

                    Button("Refresh Incoming") {
                        pushover.loadIncoming()
                    }
                    .buttonStyle(.bordered)
                }

                if !pushover.incomingNotifications.isEmpty {
                    Divider()
                    Text("Recent Incoming")
                        .font(.subheadline)
                    ForEach(pushover.incomingNotifications.prefix(10)) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.caption.bold())
                            Text(item.message)
                                .font(.caption)
                            if !item.createdAt.isEmpty {
                                Text(item.createdAt)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(6)
                    }
                }

                if let pending = pushover.pendingActivationUntil, !pending.isEmpty {
                    Text("Pending activation until \(pending)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                if let status = pushover.statusMessage, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .onAppear {
                guard !didLoadPushover else { return }
                didLoadPushover = true
                pushover.loadStatus()
                pushover.loadIncoming()
            }
        }
    }

    // MARK: - Notification Inbox
    @ViewBuilder
    var notificationInboxSettings: some View {
        let isAdmin = AdminServerManager.shared.isAdmin
        let messageManager = MessagingManager.shared
        let roomMessages = messageManager.messages
        let directMessages = Array(messageManager.directMessages.values.joined())
        let combinedMessages = Array((roomMessages + directMessages).sorted { $0.timestamp > $1.timestamp }.prefix(100))

        SettingsSection(title: "User Messages Inbox") {
            if combinedMessages.isEmpty {
                Text("No user messages yet.")
                    .font(.caption)
                    .foregroundColor(.gray)
            } else {
                ForEach(combinedMessages.prefix(20)) { msg in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(msg.senderName) • \(msg.type.rawValue.capitalized)")
                            .font(.caption.bold())
                        Text(msg.content)
                            .font(.caption)
                        Text(msg.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
            }
        }

        if isAdmin {
            SettingsSection(title: "Pushover/System Inbox (Admin)") {
                HStack {
                    Button("Refresh") {
                        pushover.loadIncoming()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Text("\(pushover.incomingNotifications.count) items")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                if pushover.incomingNotifications.isEmpty {
                    Text("No incoming notifications.")
                        .font(.caption)
                        .foregroundColor(.gray)
                } else {
                    Picker("Select Notification", selection: Binding(
                        get: { selectedInboxNotificationId ?? "" },
                        set: { newValue in
                            selectedInboxNotificationId = newValue.isEmpty ? nil : newValue
                            loadSelectedInboxNotification()
                        }
                    )) {
                        Text("Choose notification").tag("")
                        ForEach(pushover.incomingNotifications) { item in
                            Text("\(item.title) • \(item.createdAt)").tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)

                    if selectedInboxNotificationId != nil {
                        TextField("Title", text: $inboxEditorTitle)
                            .textFieldStyle(.roundedBorder)
                        TextField("Message", text: $inboxEditorMessage)
                            .textFieldStyle(.roundedBorder)
                        TextField("Link URL", text: $inboxEditorLinkURL)
                            .textFieldStyle(.roundedBorder)
                        TextField("Link Label", text: $inboxEditorLinkTitle)
                            .textFieldStyle(.roundedBorder)

                        Text("HTML Body")
                            .font(.caption)
                            .foregroundColor(.gray)
                        TextEditor(text: $inboxEditorHTML)
                            .frame(minHeight: 120)
                            .padding(6)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(8)

                        Text("Preview")
                            .font(.caption)
                            .foregroundColor(.gray)
                        HTMLContentView(html: inboxEditorHTML)
                            .frame(minHeight: 160)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(8)

                        HStack {
                            Button("Save Changes") {
                                guard let id = selectedInboxNotificationId else { return }
                                pushover.updateIncomingNotification(
                                    id: id,
                                    title: inboxEditorTitle,
                                    message: inboxEditorMessage,
                                    htmlBody: inboxEditorHTML,
                                    linkURL: inboxEditorLinkURL,
                                    linkTitle: inboxEditorLinkTitle
                                ) { success, error in
                                    inboxEditorStatus = success ? "Notification updated." : (error ?? "Update failed.")
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button(role: .destructive) {
                                guard let id = selectedInboxNotificationId else { return }
                                pushover.deleteIncomingNotification(id: id) { success, error in
                                    inboxEditorStatus = success ? "Notification removed." : (error ?? "Delete failed.")
                                    if success {
                                        selectedInboxNotificationId = nil
                                        inboxEditorTitle = ""
                                        inboxEditorMessage = ""
                                        inboxEditorHTML = ""
                                        inboxEditorLinkURL = ""
                                        inboxEditorLinkTitle = ""
                                    }
                                }
                            } label: {
                                Text("Remove")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let status = inboxEditorStatus, !status.isEmpty {
                            Text(status)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .onAppear {
                pushover.loadIncoming()
                if selectedInboxNotificationId == nil {
                    selectedInboxNotificationId = pushover.incomingNotifications.first?.id
                    loadSelectedInboxNotification()
                }
            }
        } else {
            SettingsSection(title: "Pushover/System Inbox") {
                Text("Admin access is required to view and manage system notification inbox.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }

    private func loadSelectedInboxNotification() {
        guard let id = selectedInboxNotificationId,
              let selected = pushover.incomingNotifications.first(where: { $0.id == id }) else { return }
        inboxEditorTitle = selected.title
        inboxEditorMessage = selected.message
        inboxEditorHTML = selected.htmlBody
        inboxEditorLinkURL = selected.linkURL
        inboxEditorLinkTitle = selected.linkTitle
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

            Button(exportButtonLabel) {
                exportMyDataArchive()
            }
            .disabled(isExportingData)
            .buttonStyle(.bordered)

            if let status = dataExportStatus {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }

    private func exportMyDataArchive() {
        guard !isExportingData else { return }
        isExportingData = true
        dataExportStatus = nil

        let serverBase = appState.serverManager.baseURL ?? ServerManager.mainServer
        guard let url = URL(string: "\(serverBase)/api/export/my-data") else {
            isExportingData = false
            dataExportStatus = "Export failed: invalid server URL"
            return
        }

        let authUser = AuthenticationManager.shared.currentUser
        let fallbackUserId = appState.username
        let payload: [String: Any] = [
            "userId": authUser?.id ?? fallbackUserId,
            "username": authUser?.username ?? appState.username,
            "includeMessages": true,
            "includeRooms": true,
            "useCopyParty": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                self.isExportingData = false
            }

            if let error = error {
                DispatchQueue.main.async {
                    self.dataExportStatus = "Export failed: \(error.localizedDescription)"
                }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.dataExportStatus = "Export failed: invalid response"
                }
                return
            }

            let success = (json["success"] as? Bool) ?? false
            guard success else {
                let message = json["error"] as? String ?? "unknown error"
                DispatchQueue.main.async {
                    self.dataExportStatus = "Export failed: \(message)"
                }
                return
            }

            var exportURL: String?
            if let copyParty = json["copyParty"] as? [String: Any],
               let uploaded = copyParty["uploaded"] as? Bool,
               uploaded,
               let urlString = copyParty["url"] as? String {
                exportURL = urlString
            } else if let archive = json["archive"] as? [String: Any],
                      let relativePath = archive["downloadUrl"] as? String,
                      let localUrl = URL(string: relativePath, relativeTo: URL(string: serverBase)) {
                exportURL = localUrl.absoluteString
            }

            let statusMessage = exportURL != nil
                ? "Data export ready. Opened download link."
                : "Data export completed on server."

            DispatchQueue.main.async {
                self.dataExportStatus = statusMessage

                let notification = NSUserNotification()
                notification.title = "VoiceLink Data Export"
                notification.informativeText = statusMessage
                NSUserNotificationCenter.default.deliver(notification)

                if let urlString = exportURL, let downloadURL = URL(string: urlString) {
                    NSWorkspace.shared.open(downloadURL)
                }
            }
        }.resume()
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
                                Text("You are logged in as @\(user.username) on instance host \(instance)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .lineLimit(2)
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
        SettingsSection(title: "Menu Visibility") {
            Toggle("Show Local Server controls in menus", isOn: $settings.showLocalServerControls)
                .onChange(of: settings.showLocalServerControls) { _ in
                    settings.saveSettings()
                }
                .accessibilityHint("When enabled, local server connect and discovery options appear in menus")
                .help("When enabled, local server connect and discovery options appear in menus")
            Text("Hidden by default to keep menus focused on federation and hosted servers.")
                .font(.caption)
                .foregroundColor(.gray)
        }

        SettingsSection(title: "Servers Manager") {
            Toggle("Enable multi-server directory mode", isOn: $serverProfiles.multiServerDirectoryEnabled)
                .accessibilityHint("Lets you save multiple server endpoints and quickly connect between them")
                .help("Lets you save multiple server endpoints and quickly connect between them")

            VStack(alignment: .leading, spacing: 8) {
                TextField("Server name", text: $newServerName)
                    .textFieldStyle(.roundedBorder)
                TextField("Server URL (https://...)", text: $newServerURL)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Add Server Profile") {
                        let added = serverProfiles.addProfile(name: newServerName, url: newServerURL)
                        if added {
                            newServerName = ""
                            newServerURL = ""
                            serverProfileError = nil
                        } else {
                            serverProfileError = "Could not add server. Check name/URL or duplicate entry."
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if let error = serverProfileError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            if serverProfiles.profiles.isEmpty {
                Text("No saved server profiles yet.")
                    .font(.caption)
                    .foregroundColor(.gray)
            } else {
                ForEach(serverProfiles.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .fontWeight(.semibold)
                            Text(profile.url)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("Enabled", isOn: Binding(
                            get: { profile.isEnabled },
                            set: { serverProfiles.updateEnabled(profile, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)

                        Button("Connect") {
                            appState.serverManager.connectToURL(profile.url)
                            UserDefaults.standard.set(profile.url, forKey: "lastConnectedServer")
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            serverProfiles.removeProfile(profile)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
            }
        }

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

struct HTMLContentView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(html, baseURL: nil)
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
