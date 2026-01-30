import SwiftUI
import AVFoundation
import AppKit
import SocketIO
import CoreAudio

@main
struct VoiceLinkApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var localDiscovery = LocalServerDiscovery.shared

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
                Button("Create Room") {
                    appState.currentScreen = .createRoom
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Join by Code") {
                    appState.currentScreen = .joinRoom
                }
                .keyboardShortcut("j", modifiers: .command)

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
                        Text("Logged in as: \(user.displayName)")
                        if let instance = user.mastodonInstance {
                            Text("Instance: \(instance)")
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

            CommandMenu("Connect") {
                // Connection targets
                Button("Federation (Main Node)") {
                    appState.connectToMainServer()
                }
                .help("Connect to the main VoiceLink public server")
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Local Server") {
                    if let url = localDiscovery.localServerURL {
                        localDiscovery.autoPairWithLocalServer { _ in }
                    } else {
                        appState.connectToLocalServer()
                    }
                }
                .help("Connect to a local VoiceLink server")
                .keyboardShortcut("2", modifiers: [.command, .option])

                Button("Auto-Connect (Remote First)") {
                    appState.connectToServer()
                }
                .help("Try remote server first, fallback to local")
                .keyboardShortcut("0", modifiers: [.command, .option])

                Divider()

                if localDiscovery.localServerFound {
                    Text("Local server found: \(localDiscovery.localServerName ?? "localhost")")
                } else {
                    Text("No local server detected")
                        .foregroundColor(.secondary)
                }

                Button("Scan for Local Servers") {
                    localDiscovery.scanForLocalServer()
                }
                .disabled(localDiscovery.isScanning)

                Divider()

                // Remote Server Controls
                if ServerManager.shared.isConnected {
                    Button("Disconnect") {
                        ServerManager.shared.disconnect()
                    }
                    .help("Disconnect from current server")
                }

                if AdminServerManager.shared.isAdmin {
                    Divider()

                    Text("Remote Server Control")
                        .font(.caption)

                    Button("Start Remote Server") {
                        RemoteServerControl.shared.startRemoteServer()
                    }
                    .help("Start the remote server via OpenLink, webserver, or direct connection")

                    Button("Stop Remote Server") {
                        RemoteServerControl.shared.stopRemoteServer()
                    }
                    .help("Stop the remote server gracefully")

                    Button("Restart Remote Server") {
                        RemoteServerControl.shared.restartRemoteServer()
                    }
                    .help("Restart the remote server")
                }
            }

            CommandMenu("Servers") {
                Button("My Linked Servers...") {
                    appState.currentScreen = .servers
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("View and manage servers you've linked to this device")

                Divider()

                Button("Discover Local Servers") {
                    localDiscovery.scanForLocalServer()
                }
                .help("Scan local network for VoiceLink servers")
                .disabled(localDiscovery.isScanning)

                if AdminServerManager.shared.isAdmin {
                    Divider()

                    Button("Server Administration...") {
                        appState.currentScreen = .admin
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .help("Manage remote server settings (admin only)")
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

                Button("Check for Updates...") {
                    AutoUpdater.shared.checkForUpdates()
                }
                .help("Check for available updates")

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

        // Show window on launch (user can close it to stay in menubar)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                window.center()
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
    @Published var currentRoom: Room?
    @Published var rooms: [Room] = []
    @Published var localIP: String = "Detecting..."
    @Published var serverStatus: ServerStatus = .offline
    @Published var username: String = "User\(Int.random(in: 1000...9999))"
    @Published var errorMessage: String?
    @Published var showAnnouncements: Bool = false
    @Published var showBugReport: Bool = false

    let serverManager = ServerManager.shared
    let licensing = LicensingManager.shared

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

        // Listen for room joined notification
        NotificationCenter.default.addObserver(forName: .roomJoined, object: nil, queue: .main) { [weak self] notification in
            if let roomData = notification.object as? [String: Any],
               let roomId = roomData["roomId"] as? String ?? roomData["id"] as? String {
                // Find the room and set it as current
                if let room = self?.rooms.first(where: { $0.id == roomId }) {
                    self?.currentRoom = room
                    self?.currentScreen = .voiceChat
                }
            }
        }

        // Listen for navigation back to main menu
        NotificationCenter.default.addObserver(forName: .goToMainMenu, object: nil, queue: .main) { [weak self] _ in
            self?.currentScreen = .mainMenu
        }
    }

    func refreshRooms() {
        serverManager.getRooms()
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

    init(id: String, name: String, description: String, userCount: Int, isPrivate: Bool, maxUsers: Int = 50) {
        self.id = id
        self.name = name
        self.description = description
        self.userCount = userCount
        self.isPrivate = isPrivate
        self.maxUsers = maxUsers
    }

    init(from serverRoom: ServerRoom) {
        self.id = serverRoom.id
        self.name = serverRoom.name
        self.description = serverRoom.description
        self.userCount = serverRoom.userCount
        self.isPrivate = serverRoom.isPrivate
        self.maxUsers = serverRoom.maxUsers
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

                        Divider()

                        Menu("Connection") {
                            Button("Main Server") {
                                appState.connectToMainServer()
                            }
                            Button("Local Server") {
                                appState.connectToLocalServer()
                            }
                            Button("Auto (Local then Main)") {
                                appState.connectToServer()
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

                    Button(action: { appState.refreshRooms() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.isConnected)

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
                Text("Available Rooms")
                    .font(.headline)
                    .foregroundColor(.white)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(appState.rooms) { room in
                            RoomCard(room: room) {
                                // Join room via server
                                appState.serverManager.joinRoom(
                                    roomId: room.id,
                                    username: appState.username
                                )
                                appState.currentRoom = room
                                appState.currentScreen = .voiceChat
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
                // Connection Health Panel
                ConnectionHealthView()
                    .frame(maxWidth: 280)

                // Local Server Discovery Status
                HStack {
                    Circle()
                        .fill(localDiscovery.localServerFound ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text("Local Server")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    if localDiscovery.isScanning {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else {
                        Text(localDiscovery.localServerFound ? (localDiscovery.localServerName ?? "Found") : "Not Found")
                            .font(.caption2)
                            .foregroundColor(localDiscovery.localServerFound ? .green : .gray)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05))
                .cornerRadius(8)
                .onTapGesture {
                    if localDiscovery.localServerFound, let url = localDiscovery.localServerURL {
                        localDiscovery.autoPairWithLocalServer { _ in }
                    } else {
                        localDiscovery.scanForLocalServer()
                    }
                }
                .accessibilityLabel("Local server \(localDiscovery.localServerFound ? "found" : "not found"). Tap to \(localDiscovery.localServerFound ? "connect" : "scan").")

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
                Text("Cmd+, for Settings")
                    .font(.caption)
                    .foregroundColor(.gray.opacity(0.6))
                    .padding(.bottom, 8)
            }
            .frame(width: 280)
            .padding()
            .background(Color.black.opacity(0.2))
        }
    }
}

// MARK: - Room Card
struct RoomCard: View {
    let room: Room
    let onJoin: () -> Void

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

                Text(room.description)
                    .font(.caption)
                    .foregroundColor(.gray)
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
    @State private var isMuted = false
    @State private var isDeafened = false

    var body: some View {
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

                // Keyboard shortcut hints
                HStack(spacing: 15) {
                    Text("Cmd+M Mute")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("Cmd+D Deafen")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Button("Leave") {
                    appState.serverManager.leaveRoom()
                    appState.currentRoom = nil
                    appState.currentScreen = .mainMenu
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding()

            // Users in room
            VStack(alignment: .leading, spacing: 10) {
                Text("Users in Room")
                    .font(.headline)
                    .foregroundColor(.white)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Show yourself
                        UserRow(username: appState.username + " (You)", isMuted: isMuted, isDeafened: isDeafened, isSpeaking: false)

                        // Show other users from server
                        ForEach(appState.serverManager.currentRoomUsers) { user in
                            UserRow(username: user.username, isMuted: user.isMuted, isDeafened: user.isDeafened, isSpeaking: user.isSpeaking)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            .padding(.horizontal)

            Spacer()

            // Voice Controls
            HStack(spacing: 30) {
                VoiceControlButton(icon: isMuted ? "mic.slash.fill" : "mic.fill",
                                  label: isMuted ? "Unmute (Cmd+M)" : "Mute (Cmd+M)",
                                  isActive: !isMuted) {
                    isMuted.toggle()
                    appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
                }

                VoiceControlButton(icon: isDeafened ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                  label: isDeafened ? "Undeafen (Cmd+D)" : "Deafen (Cmd+D)",
                                  isActive: !isDeafened) {
                    isDeafened.toggle()
                    appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
                }
            }
            .padding(.bottom, 40)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMute)) { _ in
            isMuted.toggle()
            appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleDeafen)) { _ in
            isDeafened.toggle()
            appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
        }
    }
}

struct UserRow: View {
    let username: String
    let isMuted: Bool
    let isDeafened: Bool
    let isSpeaking: Bool

    var body: some View {
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
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
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

    // 3D Audio
    @Published var spatialAudioEnabled: Bool = true
    @Published var headTrackingEnabled: Bool = false

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
        UserDefaults.standard.set(pttEnabled, forKey: "pttEnabled")
        UserDefaults.standard.set(spatialAudioEnabled, forKey: "spatialAudioEnabled")
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

extension Notification.Name {
    static let syncModeChanged = Notification.Name("syncModeChanged")
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = SettingsManager.shared
    @State private var selectedTab: SettingsTab = .audio

    enum SettingsTab: String, CaseIterable {
        case audio = "Audio"
        case connection = "Connection"
        case sync = "Sync & Filters"
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
                        case .audio:
                            audioSettings
                        case .connection:
                            connectionSettings
                        case .sync:
                            syncSettings
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
    }

    func iconForTab(_ tab: SettingsTab) -> String {
        switch tab {
        case .audio: return "speaker.wave.2"
        case .connection: return "wifi"
        case .sync: return "arrow.triangle.2.circlepath"
        case .notifications: return "bell"
        case .privacy: return "lock.shield"
        case .advanced: return "gear"
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

            HStack {
                Text("Input Volume")
                Slider(value: $settings.inputVolume, in: 0...1)
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

            HStack {
                Text("Output Volume")
                Slider(value: $settings.outputVolume, in: 0...1)
                Text("\(Int(settings.outputVolume * 100))%")
                    .frame(width: 40)
            }
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

    // MARK: - Connection Settings
    @ViewBuilder
    var connectionSettings: some View {
        SettingsSection(title: "Auto-Connect") {
            Toggle("Connect automatically on launch", isOn: $settings.autoConnect)
            Toggle("Prefer local server when available", isOn: $settings.preferLocalServer)
            Toggle("Reconnect on disconnect", isOn: $settings.reconnectOnDisconnect)
        }

        SettingsSection(title: "Connection Timeout") {
            HStack {
                Text("Timeout:")
                Slider(value: $settings.connectionTimeout, in: 5...60, step: 5)
                Text("\(Int(settings.connectionTimeout))s")
                    .frame(width: 40)
            }
        }

        SettingsSection(title: "Server Status") {
            HStack {
                Circle()
                    .fill(appState.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(appState.isConnected ? "Connected" : "Disconnected")
                    .foregroundColor(appState.isConnected ? .green : .red)
                Spacer()
                if appState.isConnected {
                    Text(appState.serverManager.connectedServer)
                        .foregroundColor(.gray)
                }
            }

            HStack {
                Button("Reconnect") {
                    appState.connectToServer()
                }
                .buttonStyle(.bordered)

                Button("Disconnect") {
                    appState.serverManager.disconnect()
                }
                .buttonStyle(.bordered)
                .disabled(!appState.isConnected)
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
