import SwiftUI
import AVFoundation
import AppKit
import SocketIO
import CoreAudio
import Combine
import UserNotifications

private func formatPendingCountdown(_ totalSeconds: Int) -> String {
    let seconds = max(totalSeconds, 0)
    let minutesPart = seconds / 60
    let secondsPart = seconds % 60
    return String(format: "%02d:%02d", minutesPart, secondsPart)
}

@main
struct VoiceLinkApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var localDiscovery = LocalServerDiscovery.shared
    @StateObject private var licensing = LicensingManager.shared
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
                .onReceive(NotificationCenter.default.publisher(for: .openBugReport)) { _ in
                    appState.showBugReport = true
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

                Button("Search for Servers or Join a Room...") {
                    appState.openJoinRoomPanel()
                }
                .keyboardShortcut("j", modifiers: .command)

                Button(appState.quickJoinCommandTitle) {
                    appState.handleCommandShiftJ()
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])

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

                Button("Escort Me") {
                    NotificationCenter.default.post(name: .openEscortForCurrentRoom, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!appState.hasActiveRoom)

                Button("Server Administration") {
                    NotificationCenter.default.post(name: .openServerAdministration, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command, .option])
                .disabled(!appState.hasActiveRoom || !(AdminServerManager.shared.isAdmin || AdminServerManager.shared.adminRole.canManageRooms))

                Button("Leave Room") {
                    appState.leaveCurrentRoom()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!appState.hasActiveRoom)

                Button("Room Controls...") {
                    NotificationCenter.default.post(name: .openCurrentRoomActions, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                .disabled(!appState.hasActiveRoom)

                Button("File Transfer Details") {
                    NotificationCenter.default.post(name: .openFileTransfers, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .option, .shift])
            }
            CommandMenu("Browse") {
                Menu("Layout") {
                    Button("List View") {
                        NotificationCenter.default.post(name: .roomBrowseSetLayout, object: "list")
                    }
                    .keyboardShortcut("1", modifiers: .command)

                    Button("Grid View") {
                        NotificationCenter.default.post(name: .roomBrowseSetLayout, object: "grid")
                    }
                    .keyboardShortcut("2", modifiers: .command)

                    Button("Column View") {
                        NotificationCenter.default.post(name: .roomBrowseSetLayout, object: "column")
                    }
                    .keyboardShortcut("3", modifiers: .command)
                }

                Menu("Scope") {
                    Button("All Rooms") {
                        NotificationCenter.default.post(name: .roomBrowseSetScope, object: "all")
                    }
                    .keyboardShortcut("4", modifiers: .command)

                    Button("Public Rooms") {
                        NotificationCenter.default.post(name: .roomBrowseSetScope, object: "public")
                    }
                    .keyboardShortcut("5", modifiers: .command)

                    Button("Private Rooms") {
                        NotificationCenter.default.post(name: .roomBrowseSetScope, object: "private")
                    }
                    .keyboardShortcut("6", modifiers: .command)

                    Button("Active Rooms") {
                        NotificationCenter.default.post(name: .roomBrowseSetScope, object: "active")
                    }
                    .keyboardShortcut("7", modifiers: .command)

                    Button("Media Rooms") {
                        NotificationCenter.default.post(name: .roomBrowseSetScope, object: "media")
                    }
                    .keyboardShortcut("8", modifiers: .command)
                }

                Menu("Sort") {
                    Button("Sort Active First") {
                        NotificationCenter.default.post(name: .roomBrowseSetSort, object: "active")
                    }
                    .keyboardShortcut("9", modifiers: .command)

                    Button("Sort by Members") {
                        NotificationCenter.default.post(name: .roomBrowseSetSort, object: "members")
                    }
                    .keyboardShortcut("0", modifiers: .command)
                }
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

                Button(settings.audioRecoveryInProgress ? "Restarting Audio Services..." : "Restart Audio Services") {
                    settings.restartMacOSAudioServices()
                }
                .disabled(settings.audioRecoveryInProgress)

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

                if AdminServerManager.shared.isAdmin || AdminServerManager.shared.adminRole == .admin || AdminServerManager.shared.adminRole == .owner {
                    Divider()
                    Menu("Admin Modes") {
                        Button(settings.adminPresenceModeEnabled ? "Disable Admin Presence Override" : "Enable Admin Presence Override") {
                            settings.adminPresenceModeEnabled.toggle()
                            if settings.adminPresenceModeEnabled {
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

                if authManager.authState == .authenticated {
                    Divider()

                    Button("Server Browser...") {
                        appState.currentScreen = .servers
                    }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .help("Browse linked, owned, and federated servers")

                    Button("Link Servers...") {
                        appState.currentScreen = .servers
                    }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .help("Manage linked, owned, and federated servers")

                    Button("Deploy New Server...") {
                        NotificationCenter.default.post(name: .openDeploymentManager, object: nil)
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .help("Open deployment manager to install and set up a new VoiceLink server")

                    Divider()

                    Button("Logout") {
                        authManager.logout()
                    }
                    .keyboardShortcut("q", modifiers: [.command, .shift])
                }
            }

            CommandMenu("License") {
                Button("View License") {
                    appState.currentScreen = .licensing
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                if licensing.licenseStatus == .licensed {
                    Text("Status: Licensed")
                    Text("Devices: \(licensing.activatedDevices)/\(licensing.maxDevices)")
                } else if licensing.licenseStatus == .pending {
                    Text("Status: Pending (\(formatPendingCountdown(licensing.remainingSeconds)))")
                    if licensing.retryAttempts > 0 {
                        Text("Retry attempts: \(licensing.retryAttempts)")
                    }
                    if let ticket = licensing.supportTicketNumber ?? licensing.supportTicketId {
                        Text("Support ticket: \(ticket)")
                    }
                } else {
                    Text("Status: Not Registered")
                }

                Divider()

                Button("Refresh License") {
                    Task {
                        await licensing.refreshForCurrentUser()
                    }
                }
            }

            CommandMenu("Servers") {
                Button("My Linked Servers...") {
                    appState.currentScreen = .servers
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("View and manage servers you've linked to this device")

                Button("Deploy or Set Up New Server...") {
                    NotificationCenter.default.post(name: .openDeploymentManager, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .option, .shift])
                .help("Open Deployment Manager to deploy the latest server build and finish first-admin setup")

                // Local server discovery - requires license
                if licensing.licenseStatus == .licensed {
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
                    let localURL = DocsManager.shared.resolveLocalDoc(relativePath: "index.html")
                    let remoteURL = DocsManager.shared.webURL(for: "/docs/index.html")
                    if let url = localURL ?? remoteURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .help("Open VoiceLink documentation")
            }
        }
    }
}

extension Notification.Name {
    static let audioDevicesChanged = Notification.Name("audioDevicesChanged")
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
    static let roomActionCreate = Notification.Name("roomActionCreate")
    static let roomActionDelete = Notification.Name("roomActionDelete")
    static let roomActionSwitchServer = Notification.Name("roomActionSwitchServer")
    static let openServerAdministration = Notification.Name("openServerAdministration")
    static let openDeploymentManager = Notification.Name("openDeploymentManager")
    static let openFederationBrowser = Notification.Name("openFederationBrowser")
    static let adminSelectTab = Notification.Name("adminSelectTab")
    static let openCurrentRoomActions = Notification.Name("openCurrentRoomActions")
    static let openEscortForCurrentRoom = Notification.Name("openEscortForCurrentRoom")
    static let roomBrowseSetLayout = Notification.Name("roomBrowseSetLayout")
    static let roomBrowseSetScope = Notification.Name("roomBrowseSetScope")
    static let roomBrowseSetSort = Notification.Name("roomBrowseSetSort")
    static let mainWindowCloseRequested = Notification.Name("mainWindowCloseRequested")
    static let openRoomJukebox = Notification.Name("openRoomJukebox")
    static let openFileTransfers = Notification.Name("openFileTransfers")
    static let openDirectMessage = Notification.Name("openDirectMessage")
    static let openBugReport = Notification.Name("openBugReport")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    static var shared: AppDelegate?
    private let windowController = MainWindowController()
    private weak var mainWindow: NSWindow?
    private var autoReconnectObserverInstalled = false

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

        if SettingsManager.shared.preferLocalServer {
            LocalAPIBootstrap.shared.ensureRunningIfNeeded()
        }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            AppSoundManager.shared.playStartupWelcomeIfNeeded()
        }

        DocsManager.shared.startBackgroundSync(baseURL: ServerManager.shared.baseURL)
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
            if SettingsManager.shared.preferLocalServer {
                serverManager.tryLocalThenMain()
            } else {
                serverManager.tryMainThenLocal()
            }
        }

        // Set up auto-reconnect observer
        setupAutoReconnect()
    }

    func setupAutoReconnect() {
        if autoReconnectObserverInstalled {
            return
        }
        autoReconnectObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: .serverConnectionChanged,
            object: nil,
            queue: nil
        ) { _ in
            let serverManager = ServerManager.shared
            let settings = SettingsManager.shared

            if serverManager.isConnected {
                DocsManager.shared.startBackgroundSync(baseURL: serverManager.baseURL)
            }

            // Auto-reconnect if enabled and disconnected
            if !serverManager.isConnected && settings.reconnectOnDisconnect {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if !serverManager.isConnected {
                        print("[AppDelegate] Auto-reconnecting...")
                        if settings.preferLocalServer {
                            serverManager.tryLocalThenMain()
                        } else {
                            serverManager.tryMainThenLocal()
                        }
                    }
                }
            }
        }
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let descriptor = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
              let urlString = descriptor.value(forKey: "stringValue") as? String,
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
    @Published var publicServerConfig: ServerConfig?
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

    func closeAdminScreen() {
        if hasActiveRoom {
            currentScreen = .voiceChat
            return
        }
        currentScreen = .mainMenu
    }

    func openSettings() {
        currentScreen = .settings
    }

    func closeSettings() {
        if hasActiveRoom {
            currentScreen = .voiceChat
            return
        }
        currentScreen = previousScreen == .settings ? .mainMenu : previousScreen
    }

    var quickJoinCommandTitle: String {
        if currentRoom != nil {
            return "Minimize Current Room"
        }
        if minimizedRoom != nil {
            return "Show Current Room"
        }
        return "Join Focused Room"
    }

    init() {
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
        NotificationCenter.default.addObserver(forName: .urlJoinRoom, object: nil, queue: nil) { [weak self] notification in
            guard let data = notification.object as? [String: Any],
                  let roomId = data["roomId"] as? String else { return }

            let server = data["server"] as? String
            Task { @MainActor in
                self?.handleURLJoinRoom(roomId: roomId, server: server)
            }
        }

        // Handle URL view room
        NotificationCenter.default.addObserver(forName: .urlViewRoom, object: nil, queue: nil) { [weak self] notification in
            guard let data = notification.object as? [String: Any],
                  let roomId = data["roomId"] as? String else { return }

            Task { @MainActor in
                self?.handleURLViewRoom(roomId: roomId)
            }
        }

        // Handle URL connect server
        NotificationCenter.default.addObserver(forName: .urlConnectServer, object: nil, queue: nil) { [weak self] notification in
            guard let data = notification.object as? [String: Any],
                  let serverUrl = data["serverUrl"] as? String else { return }

            Task { @MainActor in
                self?.handleURLConnectServer(serverUrl: serverUrl)
            }
        }

        // Handle URL invite
        NotificationCenter.default.addObserver(forName: .urlUseInvite, object: nil, queue: nil) { [weak self] notification in
            guard let data = notification.object as? [String: Any],
                  let code = data["code"] as? String else { return }

            Task { @MainActor in
                self?.handleURLInvite(code: code)
            }
        }

        // Handle URL open settings
        NotificationCenter.default.addObserver(forName: .urlOpenSettings, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.currentScreen = .settings
            }
        }

        // Handle URL open license
        NotificationCenter.default.addObserver(forName: .urlOpenLicense, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.currentScreen = .licensing
            }
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
            guard let joinName = requireJoinDisplayName() else { return }
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
            guard let joinName = requireJoinDisplayName() else { return }
            pendingJoinRoomId = code
            errorMessage = "Joining room \(code)..."
            serverManager.joinRoom(roomId: code, username: joinName)
        }
    }

    private func initializeLicensing() {
        // Resolve licensing from the signed-in identity first.
        Task { @MainActor in
            if AuthenticationManager.shared.currentUser != nil {
                await licensing.syncEntitlementsFromCurrentUser()
                await licensing.refreshForCurrentUser()
            } else if licensing.licenseKey != nil {
                await licensing.validateLicense()
            } else {
                licensing.licenseStatus = .notRegistered
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
        if SettingsManager.shared.preferLocalServer {
            serverManager.tryLocalThenMain()
        } else {
            serverManager.tryMainThenLocal()
        }
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
                            welcomeMessage: mapped.welcomeMessage,
                            userCount: mapped.userCount,
                            isPrivate: mapped.isPrivate,
                            isLocked: mapped.isLocked,
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
                if let currentRoomId = self?.currentRoom?.id,
                   let refreshedRoom = mappedRooms.first(where: { $0.id == currentRoomId }) {
                    self?.currentRoom = refreshedRoom
                }
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
                    self.currentRoom = Room(
                        id: activeRoomId,
                        name: "Room \(activeRoomId)",
                        description: "",
                        userCount: 1,
                        isPrivate: false,
                        maxUsers: 50
                    )
                }
                self.minimizedRoom = nil
                self.currentScreen = .voiceChat
                self.pendingJoinRoomId = nil
                self.errorMessage = "Joined \(self.currentRoom?.name ?? "room")."
            }
            .store(in: &cancellables)

        // Keep admin capabilities in sync with active server connection.
        serverManager.$isConnected
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshAdminCapabilities()
                }
            }
            .store(in: &cancellables)

        // Listen for room joined notification
        NotificationCenter.default.addObserver(forName: .roomJoined, object: nil, queue: nil) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let roomData = notification.object as? [String: Any] else { return }
                let roomId = roomData["roomId"] as? String ?? roomData["id"] as? String ?? self.pendingJoinRoomId
                guard let roomId else { return }

                let joinedRoom: Room = {
                    if let parsedServerRoom = ServerRoom(from: roomData) {
                        return Room(from: parsedServerRoom)
                    }
                    if let existing = self.rooms.first(where: { $0.id == roomId }) {
                        return existing
                    }
                    let fallbackName = (roomData["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallbackDescription = (roomData["description"] as? String) ?? ""
                    let fallbackWelcome = roomData["welcomeMessage"] as? String
                    let fallbackUsers = (roomData["userCount"] as? Int) ?? 0
                    let fallbackPrivate = (roomData["isPrivate"] as? Bool) ?? false
                    let fallbackLocked = (roomData["isLocked"] as? Bool) ?? false
                    let fallbackMaxUsers = (roomData["maxUsers"] as? Int) ?? 50
                    return Room(
                        id: roomId,
                        name: (fallbackName?.isEmpty == false ? fallbackName! : "Room \(roomId)"),
                        description: fallbackDescription,
                        welcomeMessage: fallbackWelcome,
                        userCount: fallbackUsers,
                        isPrivate: fallbackPrivate,
                        isLocked: fallbackLocked,
                        maxUsers: fallbackMaxUsers
                    )
                }()

                self.currentRoom = joinedRoom
                self.minimizedRoom = nil
                self.currentScreen = .voiceChat
                self.pendingJoinRoomId = nil
                self.errorMessage = "Joined \(joinedRoom.name)."
            }
        }

        // Listen for navigation back to main menu
        NotificationCenter.default.addObserver(forName: .goToMainMenu, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.currentScreen = .mainMenu
            }
        }
    }

    private func setupRoomActionObservers() {
        NotificationCenter.default.addObserver(forName: .roomActionMinimize, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.minimizeCurrentRoom()
            }
        }
        NotificationCenter.default.addObserver(forName: .roomActionRestore, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.restoreMinimizedRoom()
            }
        }
        NotificationCenter.default.addObserver(forName: .roomActionLeave, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.leaveCurrentRoom()
            }
        }
        NotificationCenter.default.addObserver(forName: .roomActionJoin, object: nil, queue: nil) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let room = notification.object as? Room else { return }
                self.setFocusedRoom(room)
                self.joinOrShowRoom(room)
            }
        }
        NotificationCenter.default.addObserver(forName: .roomActionOpenSettings, object: nil, queue: nil) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let room = notification.object as? Room else { return }
                guard self.canManageRoom(room) else {
                    self.errorMessage = "Room settings denied for \(room.name). Your current account is not recognized as owner/admin on this server."
                    return
                }
                self.setFocusedRoom(room)
                self.currentScreen = .admin
            }
        }
        NotificationCenter.default.addObserver(forName: .roomActionCreate, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.currentScreen = .createRoom
            }
        }
        NotificationCenter.default.addObserver(forName: .roomActionDelete, object: nil, queue: nil) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let room = notification.object as? Room else { return }
                guard self.canManageRoom(room) else {
                    self.errorMessage = "Delete denied for \(room.name). Your current account is not recognized as owner/admin on this server."
                    return
                }
                self.deleteRoomFromMenu(room)
            }
        }
        NotificationCenter.default.addObserver(forName: .roomActionSwitchServer, object: nil, queue: nil) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let payload = notification.object as? [String: Any],
                      let room = payload["room"] as? Room,
                      let serverURL = payload["serverURL"] as? String else { return }

                let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedURL.isEmpty else { return }

                let fromName = self.currentRoom?.name ?? self.minimizedRoom?.name ?? room.name
                self.errorMessage = "Leaving \(fromName) and switching servers..."
                AccessibilityManager.shared.announceStatus("Leaving \(fromName) and switching servers.")

                self.serverManager.leaveRoom()
                self.currentRoom = nil
                self.minimizedRoom = nil
                self.serverManager.connectToURL(trimmedURL)

                guard let joinName = self.requireJoinDisplayName() else { return }
                self.pendingJoinRoomId = room.id

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.serverManager.joinRoom(roomId: room.id, username: joinName)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .openServerAdministration, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.currentScreen = .admin
            }
        }
        NotificationCenter.default.addObserver(forName: .openDeploymentManager, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.currentScreen = .admin
                NotificationCenter.default.post(name: .adminSelectTab, object: AdminSettingsView.AdminTab.deployment.rawValue)
            }
        }
        NotificationCenter.default.addObserver(forName: .openFederationBrowser, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.currentScreen = .servers
            }
        }
    }

    private func setupWindowBehaviorObservers() {
        NotificationCenter.default.addObserver(forName: .mainWindowCloseRequested, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
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
    }

    private func setupAdminObservers() {
        // Refresh admin capabilities after Mastodon auth completes.
        NotificationCenter.default.addObserver(forName: .mastodonAccountLoaded, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAdminCapabilities()
            }
        }

        // Refresh when server endpoint changes (switch, disconnect, reconnect).
        NotificationCenter.default.addObserver(forName: .serverConnectionChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAdminCapabilities()
                if self?.serverManager.isConnected == true {
                    await self?.fetchPublicServerConfig()
                } else {
                    self?.publicServerConfig = nil
                }
            }
        }

        NotificationCenter.default.addObserver(forName: .roomConfigurationChanged, object: nil, queue: nil) { [weak self] notification in
            Task { @MainActor in
                guard let self, let updatedRoom = notification.object as? Room else { return }
                self.rooms = self.rooms.map { room in
                    room.id == updatedRoom.id ? self.mergeRoom(current: room, incoming: updatedRoom) : room
                }
                if let currentRoom = self.currentRoom, currentRoom.id == updatedRoom.id {
                    self.currentRoom = self.mergeRoom(current: currentRoom, incoming: updatedRoom)
                }
                if let minimizedRoom = self.minimizedRoom, minimizedRoom.id == updatedRoom.id {
                    self.minimizedRoom = self.mergeRoom(current: minimizedRoom, incoming: updatedRoom)
                }
                if self.focusedRoomId == updatedRoom.id {
                    self.focusedRoomId = updatedRoom.id
                }
            }
        }

        // Email and persisted auth sessions don't emit mastodonAccountLoaded.
        AuthenticationManager.shared.$currentUser
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.serverManager.syncAuthenticatedSession()
                    self?.refreshAdminCapabilities()
                    if self?.serverManager.isConnected == true {
                        await self?.fetchPublicServerConfig()
                    }
                }
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
        let trustedAdminEmail = "datboydommo@layor8.space"
        Task {
            await AdminServerManager.shared.checkAdminStatus(serverURL: serverURL, token: token)
            if let user = AuthenticationManager.shared.currentUser,
               user.email?.lowercased() == trustedAdminEmail {
                AdminServerManager.shared.isAdmin = true
                if AdminServerManager.shared.adminRole == .none {
                    AdminServerManager.shared.adminRole = .owner
                }
            }
            let resolvedRole = AdminServerManager.shared.adminRole.rawValue
            if resolvedRole != "none" {
                AuthenticationManager.shared.updateCurrentUserRole(resolvedRole)
            }
        }
    }

    func refreshRooms() {
        serverManager.getRooms()
        Task { @MainActor in
            await fetchPublicServerConfig()
            await fetchRoomsViaHTTPFallback()
        }
    }

    @MainActor
    private func fetchPublicServerConfig() async {
        let candidates = APIEndpointResolver.mainBaseCandidates(preferred: serverManager.baseURL)
        let decoder = JSONDecoder()

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/config") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 6

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                publicServerConfig = try decoder.decode(ServerConfig.self, from: data)
                return
            } catch {
                continue
            }
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
                return array.compactMap { payload in
                    guard let room = ServerRoom(from: payload) else { return nil }
                    if let host = room.hostServerName?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
                        return room
                    }
                    return ServerRoom(
                        id: room.id,
                        name: room.name,
                        description: room.description,
                        welcomeMessage: room.welcomeMessage,
                        userCount: room.userCount,
                        isPrivate: room.isPrivate,
                        isLocked: room.isLocked,
                        recordingAllowed: room.recordingAllowed,
                        maxUsers: room.maxUsers,
                        createdBy: room.createdBy,
                        createdByRole: room.createdByRole,
                        roomType: room.roomType,
                        createdAt: room.createdAt,
                        uptimeSeconds: room.uptimeSeconds,
                        lastActiveUsername: room.lastActiveUsername,
                        lastActivityAt: room.lastActivityAt,
                        hostServerName: source,
                        hostServerOwner: room.hostServerOwner,
                        lockedBy: room.lockedBy
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

        return SettingsManager.shared.adminPresenceModeEnabled
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

    private func isPlaceholderGuestName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lowered = trimmed.lowercased()
        if lowered == "voicelink user" {
            return true
        }
        return lowered.range(of: #"^user\d{3,}$"#, options: .regularExpression) != nil
    }

    private func requireJoinDisplayName() -> String? {
        if AuthenticationManager.shared.authState == .authenticated,
           AuthenticationManager.shared.currentUser != nil {
            let joinName = preferredDisplayName().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joinName.isEmpty else { return nil }
            username = joinName
            return joinName
        }

        let candidates = [
            UserDefaults.standard.string(forKey: "guestName"),
            username
        ]

        for candidate in candidates {
            let trimmed = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !isPlaceholderGuestName(trimmed) else { continue }
            username = trimmed
            UserDefaults.standard.set(trimmed, forKey: "guestName")
            return trimmed
        }

        currentScreen = .joinRoom
        errorMessage = "Enter a guest display name before joining a room."
        AccessibilityManager.shared.announceStatus("Enter a guest display name before joining a room.")
        return nil
    }

    private func mergeRoom(current: Room, incoming: Room) -> Room {
        Room(
            id: current.id,
            name: incoming.name.isEmpty ? current.name : incoming.name,
            description: incoming.description.isEmpty ? current.description : incoming.description,
            welcomeMessage: (incoming.welcomeMessage?.isEmpty == false ? incoming.welcomeMessage : current.welcomeMessage),
            userCount: max(current.userCount, incoming.userCount),
            isPrivate: incoming.isPrivate,
            isLocked: incoming.isLocked,
            recordingAllowed: incoming.recordingAllowed || current.recordingAllowed,
            maxUsers: max(current.maxUsers, incoming.maxUsers),
            createdBy: incoming.createdBy ?? current.createdBy,
            createdByRole: incoming.createdByRole ?? current.createdByRole,
            roomType: incoming.roomType ?? current.roomType,
            createdAt: incoming.createdAt ?? current.createdAt,
            uptimeSeconds: incoming.uptimeSeconds ?? current.uptimeSeconds,
            lastActiveUsername: incoming.lastActiveUsername ?? current.lastActiveUsername,
            lastActivityAt: incoming.lastActivityAt ?? current.lastActivityAt,
            hostServerName: incoming.hostServerName ?? current.hostServerName,
            hostServerOwner: incoming.hostServerOwner ?? current.hostServerOwner
        )
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
        guard let joinName = requireJoinDisplayName() else { return }
        pendingJoinRoomId = room.id
        errorMessage = "Joining \(room.name)..."
        serverManager.joinRoom(roomId: room.id, username: joinName)
    }

    func openHiddenRoom(roomId: String, roomName: String?) {
        let trimmedName = roomName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hiddenRoom = Room(
            id: roomId,
            name: trimmedName.isEmpty ? "Support Room" : trimmedName,
            description: "Private support session",
            userCount: 0,
            isPrivate: true
        )
        joinOrShowRoom(hiddenRoom)
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
struct Room: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let welcomeMessage: String?
    var userCount: Int
    let isPrivate: Bool
    let isLocked: Bool
    let recordingAllowed: Bool
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
    let lockedBy: String?

    init(
        id: String,
        name: String,
        description: String,
        welcomeMessage: String? = nil,
        userCount: Int,
        isPrivate: Bool,
        isLocked: Bool = false,
        recordingAllowed: Bool = false,
        maxUsers: Int = 50,
        createdBy: String? = nil,
        createdByRole: String? = nil,
        roomType: String? = nil,
        createdAt: Date? = nil,
        uptimeSeconds: Int? = nil,
        lastActiveUsername: String? = nil,
        lastActivityAt: Date? = nil,
        hostServerName: String? = nil,
        hostServerOwner: String? = nil,
        lockedBy: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.welcomeMessage = welcomeMessage
        self.userCount = userCount
        self.isPrivate = isPrivate
        self.isLocked = isLocked
        self.recordingAllowed = recordingAllowed
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
        self.lockedBy = lockedBy
    }

    init(from serverRoom: ServerRoom) {
        self.id = serverRoom.id
        self.name = serverRoom.name
        self.description = serverRoom.description
        self.welcomeMessage = serverRoom.welcomeMessage
        self.userCount = serverRoom.userCount
        self.isPrivate = serverRoom.isPrivate
        self.isLocked = serverRoom.isLocked
        self.recordingAllowed = serverRoom.recordingAllowed
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
        self.lockedBy = serverRoom.lockedBy
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

struct RichMessageText: View {
    let message: String
    var font: Font = .caption
    var color: Color = .secondary
    var lineLimit: Int? = nil
    var alignment: TextAlignment = .leading

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if !trimmedMessage.isEmpty {
            Text(StatusManager.shared.attributedMessage(trimmedMessage))
                .font(font)
                .foregroundColor(color)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
                .multilineTextAlignment(alignment)
        }
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
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var pairingManager = PairingManager.shared
    @State private var roomSortOption: RoomSortOption = .activeFirst
    @State private var roomLayoutOption: RoomLayoutOption = .list
    @State private var roomScopeFilter: RoomScopeFilter = .all
    @State private var selectedServerFilter: String = "All Servers"
    @State private var selectedRoomDetails: Room?
    @State private var selectedRoomActionRoom: Room?
    @State private var showRoomActionMenuSheet = false
    @State private var roomBrowserWidth: CGFloat = 0

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

    var serverDisplayName: String {
        let configured = appState.publicServerConfig?.serverName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty {
            return configured
        }
        if let firstNamedRoom = appState.rooms.first(where: {
            let value = ($0.hostServerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty
        }), let host = firstNamedRoom.hostServerName?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            return host
        }
        let base = appState.serverManager.baseURL ?? ""
        let host = URL(string: base)?.host ?? appState.serverManager.connectedServer
        return host.isEmpty ? "VoiceLink" : host
    }

    var serverStatusSummary: String {
        appState.isConnected ? "Connected to \(serverDisplayName)" : statusText
    }

    var serverWelcomeSummary: String? {
        let serverWelcome = appState.publicServerConfig?.welcomeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let welcome = appState.publicServerConfig?.lobbyWelcomeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let motd = appState.publicServerConfig?.motd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = [serverWelcome, welcome, motd].filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    var canOpenServerAdministration: Bool {
        let currentRole = AuthenticationManager.shared.currentUser?.role?.lowercased()
        return AdminServerManager.shared.isAdmin
            || AdminServerManager.shared.adminRole == .admin
            || AdminServerManager.shared.adminRole == .owner
            || currentRole == "admin"
            || currentRole == "owner"
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
            let matchesServer = selectedServerFilter == "All Servers" || serverLabel(for: room) == selectedServerFilter
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
            return matchesServer && matchesScope
        }
    }

    private func applyBrowseLayout(_ rawValue: String) {
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

    private func applyBrowseScope(_ rawValue: String) {
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

    private func applyBrowseSort(_ rawValue: String) {
        switch rawValue {
        case "active":
            roomSortOption = .activeFirst
        case "members":
            roomSortOption = .mostMembers
        default:
            break
        }
    }

    private var roomGridColumnCount: Int {
        let minimumCardWidth: CGFloat = 320
        let spacing: CGFloat = 12
        let usableWidth = max(roomBrowserWidth, minimumCardWidth)
        let estimated = Int((usableWidth + spacing) / (minimumCardWidth + spacing))
        return max(estimated, 1)
    }

    private func moveFocusedRoom(_ direction: MoveCommandDirection, rooms: [Room]) {
        guard !appState.hasActiveRoom, !rooms.isEmpty else { return }

        let currentIndex = rooms.firstIndex { $0.id == appState.focusedRoomId }
        let baseIndex: Int = {
            if let currentIndex { return currentIndex }
            switch direction {
            case .up:
                return max(rooms.count - 1, 0)
            default:
                return 0
            }
        }()

        let step: Int?
        switch roomLayoutOption {
        case .list, .column:
            switch direction {
            case .up: step = -1
            case .down: step = 1
            default: step = nil
            }
        case .grid:
            switch direction {
            case .left: step = -1
            case .right: step = 1
            case .up: step = -roomGridColumnCount
            case .down: step = roomGridColumnCount
            default: step = nil
            }
        }

        guard let step else { return }
        let nextIndex = min(max(baseIndex + step, 0), rooms.count - 1)
        appState.setFocusedRoom(rooms[nextIndex])
    }

    struct MainWindowServerEntry: Identifiable {
        let id: String
        let name: String
        let url: String
        let description: String
        let sourceLabel: String
        let isCurrent: Bool
    }

    private func normalizedServerURL(_ rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let candidate = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)"
        return candidate.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private var currentServerEntry: MainWindowServerEntry? {
        let base = normalizedServerURL(appState.serverManager.baseURL ?? "")
        guard !base.isEmpty else { return nil }
        return MainWindowServerEntry(
            id: base,
            name: serverDisplayName,
            url: base,
            description: "The server currently powering your room list, chat, licensing sync, and room actions.",
            sourceLabel: "Current",
            isCurrent: true
        )
    }

    private var federationServerEntries: [MainWindowServerEntry] {
        var entries: [MainWindowServerEntry] = []
        var seen = Set<String>()

        func append(url rawURL: String, name: String, description: String, source: String, isCurrent: Bool = false) {
            let normalized = normalizedServerURL(rawURL)
            guard !normalized.isEmpty, !seen.contains(normalized) else { return }
            seen.insert(normalized)
            entries.append(
                MainWindowServerEntry(
                    id: normalized,
                    name: name,
                    url: normalized,
                    description: description,
                    sourceLabel: source,
                    isCurrent: isCurrent
                )
            )
        }

        if let current = currentServerEntry {
            append(url: current.url, name: current.name, description: current.description, source: current.sourceLabel, isCurrent: true)
        }

        for managed in settingsManager.visibleManagedFederationServers {
            append(
                url: managed.url,
                name: managed.name,
                description: managed.description,
                source: "Default",
                isCurrent: normalizedServerURL(managed.url) == normalizedServerURL(appState.serverManager.baseURL ?? "")
            )
        }

        for linked in pairingManager.linkedServers {
            append(
                url: linked.url,
                name: linked.name,
                description: linked.isOnline ? "Linked server ready for room browsing and management." : "Linked server saved in your account.",
                source: "Linked",
                isCurrent: normalizedServerURL(linked.url) == normalizedServerURL(appState.serverManager.baseURL ?? "")
            )
        }

        return entries
    }

    private func connectMainWindowServer(_ entry: MainWindowServerEntry, browseRooms: Bool) {
        let currentBase = normalizedServerURL(appState.serverManager.baseURL ?? "")
        if entry.isCurrent || currentBase == normalizedServerURL(entry.url) {
            if browseRooms {
                appState.currentScreen = .mainMenu
                appState.refreshRooms()
            } else {
                appState.serverManager.disconnect()
                appState.currentRoom = nil
                appState.minimizedRoom = nil
                appState.errorMessage = "Disconnected from \(entry.name)."
            }
            return
        }

        if appState.hasActiveRoom {
            appState.leaveCurrentRoom()
        }
        appState.serverManager.connectToURL(entry.url)
        appState.refreshRooms()
        appState.currentScreen = .mainMenu
        appState.errorMessage = browseRooms ? "Connected to \(entry.name). Browsing rooms..." : "Connected to \(entry.name)."
    }

    private func preferredServerFilterLabel(for entry: MainWindowServerEntry) -> String {
        if availableServerFilters.contains(entry.name) {
            return entry.name
        }
        if let host = URL(string: entry.url)?.host, availableServerFilters.contains(host) {
            return host
        }
        let normalizedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let match = availableServerFilters.first(where: { $0.lowercased() == normalizedName }) {
            return match
        }
        return "All Servers"
    }

    var body: some View {
        let roomsForDisplay = filteredRooms
        let authManager = AuthenticationManager.shared
        HStack(spacing: 0) {
            VStack(spacing: 30) {
                // Header
                VStack(spacing: 10) {
                    Text("VoiceLink")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.top, 40)

            // Error message
            if let error = appState.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal, 40)
            }

                // Room List
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Available Rooms (\(roomsForDisplay.count))")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    Button("Search or Join") {
                        appState.currentScreen = .joinRoom
                    }
                    .buttonStyle(.bordered)

                    Menu {
                        Button("All Servers") {
                            selectedServerFilter = "All Servers"
                        }
                        Divider()
                        ForEach(federationServerEntries) { entry in
                            Button {
                                connectMainWindowServer(entry, browseRooms: true)
                                selectedServerFilter = preferredServerFilterLabel(for: entry)
                            } label: {
                                if entry.isCurrent {
                                    Label(entry.name, systemImage: "checkmark")
                                } else {
                                    Text(entry.name)
                                }
                            }
                        }
                    } label: {
                        Label(selectedServerFilter == "All Servers" ? "Servers" : selectedServerFilter, systemImage: "server.rack")
                    }
                    .accessibilityLabel("Server selector")
                    .accessibilityHint("Choose a server to connect and filter the room list shown here.")
                }

                HStack {
                    if authManager.authState == .authenticated, let user = authManager.currentUser {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName)
                                    .foregroundColor(.white)
                                    .font(.subheadline.weight(.semibold))
                                if let email = user.email, !email.isEmpty {
                                    let accountTypeName: String = {
                                        let provider = (user.authProvider ?? user.authMethod.rawValue).lowercased()
                                        switch provider {
                                        case "local", "voicelink", "email":
                                            return "VoiceLink Account"
                                        case "whmcs":
                                            return "WHMCS Account"
                                        case "mastodon":
                                            return "Mastodon Account"
                                        case "google":
                                            return "Google Account"
                                        case "apple":
                                            return "Apple Account"
                                        case "github":
                                            return "GitHub Account"
                                        default:
                                            return "\(user.authMethod.displayName) Account"
                                        }
                                    }()
                                    let roleName = (user.role?.isEmpty == false ? user.role! : "member")
                                        .replacingOccurrences(of: "_", with: " ")
                                        .capitalized
                                    Text("\(accountTypeName) • \(roleName)")
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                    Text(email)
                                        .foregroundColor(.gray.opacity(0.8))
                                        .font(.caption2)
                                }
                            }

                            if canOpenServerAdministration {
                                Button("Server Administration") {
                                    appState.currentScreen = .admin
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            Button("Logout") {
                                authManager.logout()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        Button("Sign In to VoiceLink") {
                            appState.currentScreen = .login
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(serverStatusSummary)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.75))
                        if let serverWelcomeSummary {
                            RichMessageText(
                                message: serverWelcomeSummary,
                                font: .caption2,
                                color: .white.opacity(0.6),
                                lineLimit: 5,
                                alignment: .trailing
                            )
                                .frame(maxWidth: 360, alignment: .trailing)
                        }
                    }
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
                .frame(maxHeight: 470)
                .focusable()
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                roomBrowserWidth = geometry.size.width
                            }
                            .onChange(of: geometry.size.width) { newValue in
                                roomBrowserWidth = newValue
                            }
                    }
                )
                .onMoveCommand { direction in
                    moveFocusedRoom(direction, rooms: roomsForDisplay)
                }
                .sheet(item: $selectedRoomDetails) { room in
                    RoomDetailsSheet(
                        room: room,
                        roomHasActiveMedia: appState.roomHasActiveMusic[room.id] == true,
                        isActiveRoom: appState.activeRoomId == room.id,
                        onJoin: { appState.joinOrShowRoom(room) },
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
                .sheet(isPresented: $showRoomActionMenuSheet) {
                    if let room = selectedRoomActionRoom {
                        RoomActionMenu(
                            room: room,
                            isInRoom: appState.activeRoomId == room.id,
                            isPresented: $showRoomActionMenuSheet
                        )
                        .presentationDetents([.height(320)])
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openCurrentRoomActions)) { _ in
                    guard appState.currentScreen == .mainMenu || appState.currentScreen == .joinRoom else { return }
                    if let room = appState.focusedRoomForQuickJoin() {
                        selectedRoomActionRoom = room
                        showRoomActionMenuSheet = true
                    }
                }
            }
            .padding(.horizontal, 40)

            // Action Buttons
            HStack(spacing: 20) {
                ActionButton(title: "Create Room", icon: "plus.circle.fill", color: .blue) {
                    appState.currentScreen = .createRoom
                }

                ActionButton(title: "Search or Join", icon: "link.circle.fill", color: .green) {
                    appState.currentScreen = .joinRoom
                }
            }
            .padding(.horizontal, 40)

            // Account Button
            HStack {
                if authManager.authState == .authenticated {
                    EmptyView()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ActionButton(title: "Sign In to VoiceLink", icon: "person.crop.circle.badge.checkmark", color: .blue) {
                            appState.currentScreen = .login
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
            }
            .onReceive(NotificationCenter.default.publisher(for: .roomBrowseSetLayout)) { notification in
                if let value = notification.object as? String {
                    applyBrowseLayout(value)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .roomBrowseSetScope)) { notification in
                if let value = notification.object as? String {
                    applyBrowseScope(value)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .roomBrowseSetSort)) { notification in
                if let value = notification.object as? String {
                    applyBrowseSort(value)
                }
            }

            // Right Sidebar - Connection Health & Servers
            VStack(spacing: 16) {
                Spacer()

                // Settings tip at bottom of sidebar
                HStack(spacing: 10) {
                    Text("Open Settings with Command-Comma")
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
            return "Join"
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

    var lockStatusText: String {
        room.isLocked ? "Locked." : ""
    }

    var roomAccessibilitySummary: String {
        [room.name, displayDescription, "Users \(room.userCount) of \(room.maxUsers).", lockStatusText, mediaStatusText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
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

                    if room.isLocked {
                        Text("Locked")
                            .font(.caption2)
                            .foregroundColor(.orange)
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

        }
        .padding()
        .background(Color.white.opacity(0.1))
        .cornerRadius(12)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onTapGesture(count: 2) { runPrimaryAction() }
        .onHover { hovering in
            if hovering { onFocus() }
        }
        .contextMenu {
            Button("Room Actions...") { onOpenActionMenu() }
            Divider()
            Button("Room Details") { onOpenDetails() }
            if showJoinActionSeparately {
                Button("Join Room") { onJoin() }
            }
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
            Button("Open Room Administration") { onOpenAdmin() }
            Button("Create New Room") { onCreateRoom() }
            Button("Delete This Room", role: .destructive) { onDeleteRoom() }
                .disabled(!isAdmin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(roomAccessibilitySummary)
        .accessibilityHint("Primary button runs \(primaryActionLabel). Use room actions for more options.")
        .accessibilityAction { runPrimaryAction() }
        .accessibilityAction(named: Text(primaryActionLabel)) { runPrimaryAction() }
        .accessibilityAction(named: Text("Preview Room Audio")) {
            if previewAvailable { onPreview() } else { onOpenDetails() }
        }
        .accessibilityAction(named: Text("Share Room Link")) { onShare() }
        .accessibilityAction(named: Text("Room Details")) { onOpenDetails() }
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
                    Button("Join Room") { onJoin() }
                }
                Button("Preview Room Audio") { previewOrExplain() }
                    .disabled(!roomCanPreview)
                    .accessibilityHint(roomCanPreview ? "Preview live room audio." : "Unavailable because room audio preview is currently disabled or there is no active room audio.")
                Button("Share Room Link") { onShare() }
                if isAdmin {
                    Divider()
                    Menu("Manage Room") {
                        Button("Open Room Administration") { onOpenAdmin() }
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
            return "Join"
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
                if room.isLocked {
                    Text("Locked")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
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
        .onTapGesture(count: 2) { runPrimaryAction() }
        .onHover { hovering in
            if hovering { onFocus() }
        }
        .contextMenu {
            Button("Room Actions...") { onOpenActionMenu() }
            Divider()
            Button("Room Details") { onOpenDetails() }
            if showJoinActionSeparately {
                Button("Join Room") { onJoin() }
            }
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
            Button("Open Room Administration") { onOpenAdmin() }
            Button("Create New Room") { onCreateRoom() }
            Button("Delete This Room", role: .destructive) { onDeleteRoom() }
                .disabled(!isAdmin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(roomAccessibilitySummary)
        .accessibilityHint("Primary button runs \(primaryLabel). Use VoiceOver plus Shift plus M for the actions menu.")
        .accessibilityAction { runPrimaryAction() }
        .accessibilityAction(named: Text(primaryLabel)) { runPrimaryAction() }
        .accessibilityAction(named: Text("Preview Room Audio")) {
            if previewAvailable { onPreview() } else { onOpenDetails() }
        }
        .accessibilityAction(named: Text("Share Room Link")) { onShare() }
        .accessibilityAction(named: Text("Room Details")) { onOpenDetails() }
    }
}

struct MainWindowServerCard: View {
    let entry: MainMenuView.MainWindowServerEntry
    let isConnected: Bool
    let onConnectOrDisconnect: () -> Void
    let onBrowseRooms: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text(entry.url)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .textSelection(.enabled)
                    Text(entry.description)
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.9))
                }

                Spacer()

                Text(entry.sourceLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((isConnected ? Color.green : Color.blue).opacity(0.18))
                    .foregroundColor(isConnected ? .green : .blue)
                    .cornerRadius(6)
            }

            HStack(spacing: 8) {
                Button(isConnected ? "Disconnect" : "Connect") {
                    onConnectOrDisconnect()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(isConnected ? "Disconnect from \(entry.name)" : "Connect to \(entry.name)")

                Button("Browse Rooms") {
                    onBrowseRooms()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Browse rooms on \(entry.name)")
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

struct RoomDetailsSheet: View {
    let room: Room
    let roomHasActiveMedia: Bool
    let isActiveRoom: Bool
    let onJoin: () -> Void
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

    private var roomWelcomeMessage: String? {
        let value = room.welcomeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private var roomCreatedLabel: String {
        guard let createdAt = room.createdAt else { return "Not reported yet" }
        return createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var roomAgeLabel: String {
        guard let createdAt = room.createdAt else { return "Not reported yet" }
        return RelativeDateTimeFormatter().localizedString(for: createdAt, relativeTo: Date())
    }

    private var roomUptimeLabel: String {
        guard let uptimeSeconds = room.uptimeSeconds, uptimeSeconds > 0 else { return "Not reported yet" }
        let hours = uptimeSeconds / 3600
        let minutes = (uptimeSeconds % 3600) / 60
        let seconds = uptimeSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private var roomOwnerLabel: String {
        let owner = room.createdBy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return owner.isEmpty ? "Not reported yet" : owner
    }

    private var lastUserLabel: String {
        let lastUser = room.lastActiveUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return lastUser.isEmpty ? "No recent activity" : lastUser
    }

    private var lastActivityLabel: String {
        guard let lastActivityAt = room.lastActivityAt else { return "No activity yet" }
        return lastActivityAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(room.name).font(.title2.weight(.bold))
            if SettingsManager.shared.showRoomDescriptions {
                Text(room.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No description provided." : room.description)
                    .foregroundColor(.secondary)
            }

            if let roomWelcomeMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Room Welcome")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    RichMessageText(message: roomWelcomeMessage, font: .caption, color: .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Room Status: \(isActiveRoom ? "Joined" : "Available")")
                Text("Lock Status: \(room.isLocked ? "Locked" : "Unlocked")")
                if let lockedBy = room.lockedBy, !lockedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Locked By: \(lockedBy)")
                }
                Text("Your Status: \(ServerManager.shared.audioTransmissionStatus)")
                Text("Users: \(room.userCount)/\(room.maxUsers)")
                Text("Visibility: \(room.isPrivate ? "Private" : "Public")")
                Text("Media: \(roomHasActiveMedia ? "Active" : "None")")
                Text("Owner: \(roomOwnerLabel)")
                Text("Created: \(roomCreatedLabel)")
                Text("Room Age: \(roomAgeLabel)")
                Text("Room Uptime: \(roomUptimeLabel)")
                Text("Last User: \(lastUserLabel)")
                Text("Last Activity: \(lastActivityLabel)")
                if let type = room.roomType, !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Room Type: \(type)")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if let hostedFrom = room.hostedFromLine {
                Text(hostedFrom)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button(isActiveRoom ? "Return to Room" : "Join Room") { onJoin(); dismiss() }
                    .buttonStyle(.borderedProminent)
                Button("Preview") {
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
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 220)
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
                TextField("Room name shown in the room list", text: $roomName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)
                    .accessibilityLabel("Room name")
                    .accessibilityHint("Enter the name users will see for this room.")

                TextField("Short room description or topic, optional", text: $roomDescription)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)
                    .accessibilityLabel("Room description")
                    .accessibilityHint("Add an optional summary or topic for this room.")

                Toggle("Private Room", isOn: $isPrivate)
                    .foregroundColor(.white)
                    .frame(width: 350)

                if isPrivate {
                    SecureField("Room password for invited users", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 350)
                        .accessibilityLabel("Room password")
                        .accessibilityHint("Enter the password users must provide to join this private room.")
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
                        TextField("Moderation notes for staff, optional", text: $moderationNotes)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 350)
                            .accessibilityLabel("Moderation notes")
                            .accessibilityHint("Enter optional staff-only notes about moderation for this room.")
                    }
                }
            }

            HStack(spacing: 15) {
                Button("Create") {
                    var metadata: [String: Any] = [
                        "maxUsers": maxUsers,
                        "roomType": roomType,
                        "inviteOnly": inviteOnly,
                        "mediaAutoPlay": enableMediaAutoPlay
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
                        isPrivate: isPrivate,
                        password: isPrivate ? password : nil,
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
    @State private var guestDisplayName = ""

    private var query: String {
        roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAuthenticated: Bool {
        AuthenticationManager.shared.authState == .authenticated
            && AuthenticationManager.shared.currentUser != nil
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
            Text("Search for Servers or Join a Room")
                .font(.largeTitle)
                .foregroundColor(.white)

            Text("Use room ID, room name, or keywords. Search runs against the backend room list across connected public servers.")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)

            TextField("Search by room ID, room name, or keyword", text: $roomCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 520)
                .accessibilityLabel("Room search")
                .accessibilityHint("Type a room ID, room name, or keyword to search for a room to join.")
                .onSubmit {
                    _ = appState.joinRoomByCodeOrName(roomCode)
                }

            if !isAuthenticated {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Guest Display Name")
                        .font(.caption)
                        .foregroundColor(.gray)
                    TextField("Guest display name to use in rooms", text: $guestDisplayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 520)
                        .accessibilityLabel("Guest display name")
                        .accessibilityHint("Enter the name you want other users to see when joining as a guest.")
                        .onChange(of: guestDisplayName) { newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                appState.username = trimmed
                            }
                        }
                }
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
                                Button("Join") {
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
            if !isAuthenticated {
                let preferred = appState.username.trimmingCharacters(in: .whitespacesAndNewlines)
                guestDisplayName = preferred.isEmpty ? appState.preferredDisplayName() : preferred
            }
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
    @ObservedObject private var authManager = AuthenticationManager.shared
    @ObservedObject private var audioControl = UserAudioControlManager.shared
    @State private var isMuted = false
    @State private var isDeafened = false
    @State private var messageText = ""
    @State private var showChat = true
    @State private var showTranscripts = true
    @State private var roomTranscripts: [RoomTranscriptEntry] = []
    @State private var showRoomActionsSheet = false
    @State private var showRoomDetailsSheet = false
    @State private var showEscortSheet = false
    @State private var selectedDirectMessageUserId: String?
    @State private var selectedDirectMessageUserName: String?
    @State private var replyingToMessage: MessagingManager.ChatMessage?
    @State private var selectedChatMessageId: String?
    @State private var pendingEscapeTimestamp: Date?
    @State private var escapeKeyMonitor: Any?
    @State private var pendingRoomLockDuration: TimeInterval?
    @State private var pendingRoomLockActionIsUnlock = false
    @State private var showRoomLockConfirmation = false
    @State private var pendingBackgroundMediaStream: BackgroundStreamConfig?
    @State private var showBackgroundMediaScopeDialog = false
    @State private var showBackgroundMediaRoomPicker = false
    @State private var pendingBackgroundMediaSelectionTitle = "Choose Rooms"
    @State private var pendingBackgroundMediaApplyLabel = "Apply to Selected Rooms"
    @State private var preselectedBackgroundMediaRoomIDs: Set<String> = []

    private var isAuthenticatedUser: Bool {
        authManager.authState == .authenticated && authManager.currentUser != nil
    }

    private var canOpenServerAdministration: Bool {
        let currentRole = authManager.currentUser?.role?.lowercased()
        return adminManager.isAdmin
            || adminManager.adminRole.canManageConfig
            || adminManager.adminRole.canManageServer
            || currentRole == "admin"
            || currentRole == "owner"
    }

    private var canManageBackgroundMedia: Bool {
        guard let room = appState.currentRoom else {
            return adminManager.isAdmin || adminManager.adminRole.canManageConfig || adminManager.adminRole.canManageRooms
        }
        return appState.canManageRoom(room)
    }

    private var canLockCurrentRoom: Bool {
        guard let room = appState.currentRoom else { return roomLockManager.canCurrentUserLock }
        return appState.canManageRoom(room)
    }

    private var availableBackgroundStreams: [BackgroundStreamConfig] {
        guard adminManager.serverConfig?.backgroundStreams?.enabled != false else { return [] }
        let streams = adminManager.serverConfig?.backgroundStreams?.streams ?? []
        return streams
            .filter { stream in
                let url = stream.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stream.url : stream.streamUrl
                return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var configuredBackgroundMediaFadeDuration: TimeInterval {
        let fadeMilliseconds = adminManager.serverConfig?.backgroundStreams?.fadeInDuration ?? 1500
        return max(Double(fadeMilliseconds) / 1000.0, 0.05)
    }

    private var meDisplayName: String {
        appState.preferredDisplayName()
    }

    private var visibleRoomUsers: [RoomUser] {
        let currentUserId = appState.serverManager.currentUserId
        let selfCandidates = Set([
            appState.username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            appState.preferredDisplayName().lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        ])
        return appState.serverManager.currentRoomUsers.filter { user in
            if let currentUserId, user.id == currentUserId || user.odId == currentUserId {
                return false
            }
            return !selfCandidates.contains(user.username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
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
        return "Type a room message..."
    }

    private var canSendMessages: Bool {
        appState.currentRoom != nil || appState.serverManager.activeRoomId != nil
    }

    private func normalizedStreamURL(for stream: BackgroundStreamConfig) -> String {
        let primary = stream.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        return stream.url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func roomNameMatchesPattern(_ roomName: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        let expression = "^\(escaped)$"
        return roomName.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func isStreamAssignedToCurrentRoom(_ stream: BackgroundStreamConfig) -> Bool {
        guard let room = appState.currentRoom else { return false }
        let roomId = room.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomName = room.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitRooms = (stream.rooms ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if explicitRooms.contains(roomId) {
            return true
        }
        return (stream.roomPatterns ?? []).contains { pattern in
            roomNameMatchesPattern(roomName, pattern: pattern)
        }
    }

    private func allAssignableRoomIDs() -> [String] {
        let ids = adminManager.serverRooms.map(\.id).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if ids.isEmpty, let currentRoomId = appState.currentRoom?.id {
            return [currentRoomId]
        }
        return Array(Set(ids)).sorted()
    }

    private func presentBackgroundMediaSelectionOptions(for selectedStream: BackgroundStreamConfig?) {
        guard let roomId = appState.currentRoom?.id else { return }
        pendingBackgroundMediaStream = selectedStream
        preselectedBackgroundMediaRoomIDs = [roomId]
        showBackgroundMediaScopeDialog = true
    }

    private func applyPendingBackgroundMediaSelection(scope: BackgroundMediaAssignmentScope) {
        switch scope {
        case .currentRoom:
            guard let roomId = appState.currentRoom?.id else { return }
            applyBackgroundMediaSelection(pendingBackgroundMediaStream, roomIDs: [roomId])
        case .allRooms:
            applyBackgroundMediaSelection(pendingBackgroundMediaStream, roomIDs: allAssignableRoomIDs())
        case .selectedRooms:
            pendingBackgroundMediaSelectionTitle = pendingBackgroundMediaStream == nil
                ? "Clear Background Media in Rooms"
                : "Choose Rooms for \(pendingBackgroundMediaStream?.name ?? "Background Media")"
            pendingBackgroundMediaApplyLabel = pendingBackgroundMediaStream == nil
                ? "Clear in Selected Rooms"
                : "Apply to Selected Rooms"
            showBackgroundMediaRoomPicker = true
        }
    }

    private func applyBackgroundMediaSelection(_ selectedStream: BackgroundStreamConfig?, roomIDs: [String]) {
        guard canManageBackgroundMedia, let room = appState.currentRoom else { return }
        guard var config = adminManager.serverConfig?.backgroundStreams else { return }

        let normalizedRoomIDs = Array(Set(roomIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard !normalizedRoomIDs.isEmpty else { return }
        config.streams = config.streams.map { stream in
            var updated = stream
            var rooms = (updated.rooms ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !normalizedRoomIDs.contains($0) }
            if let selectedStream, updated.id == selectedStream.id {
                rooms.append(contentsOf: normalizedRoomIDs)
                updated.autoPlay = true
            }
            updated.rooms = rooms.isEmpty ? nil : Array(Set(rooms)).sorted()
            return updated
        }

        Task {
            let success = await adminManager.updateBackgroundStreamsConfig(config)
            guard success else { return }
            await MainActor.run {
                appState.serverManager.setRoomMediaFadeDuration(configuredBackgroundMediaFadeDuration)
                appState.serverManager.stopCurrentRoomMedia()
                if selectedStream != nil {
                    appState.serverManager.refreshRoomMedia(for: room.id)
                }
            }
        }
    }

    private func syncRoomManagementState() {
        guard let room = appState.currentRoom else { return }
        roomLockManager.canCurrentUserLock = appState.canManageRoom(room)
        roomLockManager.isRoomLocked = room.isLocked
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
                canLoadOlderMessages: false,
                currentHistoryStatus: "",
                currentChatMessages: currentChatMessages,
                currentChatPlaceholder: currentChatPlaceholder,
                canSendMessages: canSendMessages,
                isSharing: false,
                messageText: $messageText,
                replyingToMessage: $replyingToMessage,
                selectedMessageId: $selectedChatMessageId,
                onBack: {
                    selectedDirectMessageUserId = nil
                    selectedDirectMessageUserName = nil
                    replyingToMessage = nil
                    selectedChatMessageId = nil
                },
                onLoadOlder: {},
                onSkipToLatest: {},
                onSelectAttachment: {},
                onSendMessage: sendMessage,
                onReplyToMessage: startReply(to:),
                onSendFileToSender: actionForSendingFile(to:),
                onDirectMessageSender: actionForDirectMessage(to:),
                onViewSenderProfile: actionForViewingSenderProfile(for:)
            )
        }
        .frame(minWidth: 420, idealWidth: 520)
        .background(Color.black.opacity(0.2))
    }

    @ViewBuilder
    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live Transcripts")
                    .font(.headline)
                    .foregroundColor(.white)
                    .accessibilityLabel("Live Transcripts")
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(roomTranscripts.count)")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .accessibilityLabel("\(roomTranscripts.count) transcript items")
            }
            .padding()
            .background(Color.black.opacity(0.3))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if roomTranscripts.isEmpty {
                            Text("Live room transcripts will appear here.")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        ForEach(roomTranscripts) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(entry.userName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.white)
                                    if let language = entry.language, !language.isEmpty {
                                        Text(language.uppercased())
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                    Text(entry.timestamp, style: .time)
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                                Text(entry.text)
                                    .font(.callout)
                                    .foregroundColor(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(8)
                            .id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: roomTranscripts.count) { _ in
                    if let last = roomTranscripts.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 180, idealHeight: 220)
        .background(Color.black.opacity(0.18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live transcripts panel")
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
                        if isAuthenticatedUser {
                            Button("Room Actions...") {
                                showRoomActionsSheet = true
                            }
                        }
                        if isAuthenticatedUser && canManageBackgroundMedia {
                            Menu("Room Background Media") {
                                Button("No Background Media") {
                                    presentBackgroundMediaSelectionOptions(for: nil)
                                }

                                if !availableBackgroundStreams.isEmpty {
                                    Divider()
                                    ForEach(availableBackgroundStreams) { stream in
                                        Button {
                                            presentBackgroundMediaSelectionOptions(for: stream)
                                        } label: {
                                            if isStreamAssignedToCurrentRoom(stream) {
                                                Label(stream.name, systemImage: "checkmark")
                                            } else {
                                                Text(stream.name)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Button("Room Details") {
                            showRoomDetailsSheet = true
                        }
                        if isAuthenticatedUser && canLockCurrentRoom {
                            if roomLockManager.isRoomLocked {
                                Button {
                                    requestRoomUnlock()
                                } label: {
                                    Label("Unlock Room", systemImage: "lock.open.fill")
                                }
                            } else {
                                Menu {
                                    ForEach(RoomLockManager.LockDurationPreset.allCases) { preset in
                                        Button(preset.title) {
                                            requestRoomLock(duration: preset.duration)
                                        }
                                    }
                                } label: {
                                    Label("Lock Room", systemImage: "lock.fill")
                                }
                            }
                        }
                        if isAuthenticatedUser, appState.currentRoom != nil {
                            Button("Escort Me") {
                                showEscortSheet = true
                            }
                        }
                        if isAuthenticatedUser, canOpenServerAdministration {
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
                        Label("Room", systemImage: roomLockManager.isRoomLocked ? "lock.fill" : "lock.open")
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding()

                // Users in room
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Members List")
                            .font(.headline)
                            .foregroundColor(.white)
                            .accessibilityLabel("Members List")
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("\(visibleRoomUsers.count + 1)")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .accessibilityLabel("\(visibleRoomUsers.count + 1) members")
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
                                isCurrentUser: true
                            )

                            // Show other users from server
                            ForEach(visibleRoomUsers) { user in
                                UserRow(
                                    userId: user.odId,
                                    username: user.username,
                                    isMuted: user.isMuted,
                                    isDeafened: user.isDeafened,
                                    isSpeaking: user.isSpeaking
                                )
                            }
                        }
                    }
                    .accessibilityLabel("Members list")
                    .accessibilityHint("Shows everyone currently in this room")
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

                    VoiceControlButton(icon: showTranscripts ? "captions.bubble.fill" : "captions.bubble",
                                      label: showTranscripts ? "Hide Transcripts" : "Show Transcripts",
                                      isActive: showTranscripts) {
                        showTranscripts.toggle()
                    }
                }
                .padding(.bottom, 20)

                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Text("Output")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .frame(width: 48, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(audioControl.masterVolume) },
                            set: { audioControl.masterVolume = Float($0) }
                        ), in: 0...2.0)
                        Text("\(Int(audioControl.masterVolume * 100))%")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .frame(width: 42)
                    }

                }
                .padding(.horizontal)
                .padding(.bottom, 12)

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

            if showChat {
                if showTranscripts {
                    VStack(spacing: 0) {
                        chatPanel
                        Divider().overlay(Color.white.opacity(0.08))
                        transcriptPanel
                    }
                } else {
                    chatPanel
                }
            }
        }
        .onAppear {
            // Ensure room audio path is active when chat view is visible.
            appState.serverManager.sendAudioState(isMuted: isMuted, isDeafened: isDeafened)
            refreshRoomAdminCapabilities()
            syncRoomManagementState()
            setupEscapeMonitor()
            if canManageBackgroundMedia {
                Task {
                    await adminManager.fetchServerConfig()
                }
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .openDirectMessage)) { notification in
            guard let info = notification.userInfo else { return }
            guard let userId = info["userId"] as? String else { return }
            selectedDirectMessageUserId = userId
            selectedDirectMessageUserName = info["userName"] as? String ?? "User"
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCurrentRoomActions)) { _ in
            if appState.currentRoom != nil {
                showRoomActionsSheet = true
            }
        }
        .onChange(of: appState.currentRoom?.id) { _ in
            syncRoomManagementState()
        }
        .onChange(of: appState.currentRoom?.isLocked) { _ in
            syncRoomManagementState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openEscortForCurrentRoom)) { _ in
            if appState.currentRoom != nil {
                showEscortSheet = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .roomTranscriptReceived)) { notification in
            guard let info = notification.userInfo else { return }
            let roomId = (info["roomId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let activeRoomId = appState.serverManager.activeRoomId ?? appState.currentRoom?.id ?? ""
            guard !roomId.isEmpty, roomId == activeRoomId else { return }
            let text = (info["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let userName = (info["userName"] as? String ?? "Live Transcript").trimmingCharacters(in: .whitespacesAndNewlines)
            let languageValue = (info["language"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            roomTranscripts.append(
                RoomTranscriptEntry(
                    userId: (info["userId"] as? String ?? ""),
                    userName: userName.isEmpty ? "Live Transcript" : userName,
                    text: text,
                    language: languageValue.isEmpty ? nil : languageValue
                )
            )
            if roomTranscripts.count > 200 {
                roomTranscripts.removeFirst(roomTranscripts.count - 200)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .roomJoined)) { _ in
            roomTranscripts.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .roomLeft)) { _ in
            roomTranscripts.removeAll()
        }
        .alert(
            pendingRoomLockActionIsUnlock ? "Unlock Room?" : "Lock Room?",
            isPresented: $showRoomLockConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button(pendingRoomLockActionIsUnlock ? "Unlock" : "Lock") {
                if pendingRoomLockActionIsUnlock {
                    roomLockManager.unlockRoom()
                } else {
                    roomLockManager.lockRoom(duration: pendingRoomLockDuration)
                }
            }
        } message: {
            if pendingRoomLockActionIsUnlock {
                Text("This will reopen the room immediately. New people can join again, pending access requests can continue, and normal room access resumes right away.")
            } else if let pendingRoomLockDuration {
                Text("This will lock the room for \(formattedLockDuration(pendingRoomLockDuration)). New joins are blocked during that time unless someone has the room secret or a moderator lets them in. People already in the room can keep listening, chatting, and leave normally.")
            } else {
                Text("This will lock the room until it is unlocked manually. New joins are blocked, existing listeners can stay or leave, and anyone who leaves may need approval or the room secret to come back in.")
            }
        }
        .sheet(isPresented: $showRoomActionsSheet) {
            if let room = appState.currentRoom {
                RoomActionMenu(room: room, isInRoom: true, isPresented: $showRoomActionsSheet)
                    .presentationDetents([.height(520)])
            }
        }
        .confirmationDialog(
            pendingBackgroundMediaStream == nil ? "Clear Background Media" : "Apply Background Media",
            isPresented: $showBackgroundMediaScopeDialog,
            titleVisibility: .visible
        ) {
            Button("This Room Only") {
                applyPendingBackgroundMediaSelection(scope: .currentRoom)
            }
            Button("All Rooms") {
                applyPendingBackgroundMediaSelection(scope: .allRooms)
            }
            Button("Choose Rooms...") {
                applyPendingBackgroundMediaSelection(scope: .selectedRooms)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingBackgroundMediaStream == nil
                 ? "Choose where to clear the current background media assignment."
                 : "Choose where to start \(pendingBackgroundMediaStream?.name ?? "the selected stream").")
        }
        .sheet(isPresented: $showBackgroundMediaRoomPicker) {
            BackgroundMediaRoomPickerSheet(
                title: pendingBackgroundMediaSelectionTitle,
                availableRooms: adminManager.serverRooms,
                initiallySelectedRoomIDs: preselectedBackgroundMediaRoomIDs,
                applyLabel: pendingBackgroundMediaApplyLabel
            ) { selectedRoomIDs in
                applyBackgroundMediaSelection(pendingBackgroundMediaStream, roomIDs: Array(selectedRoomIDs))
            }
        }
        .sheet(isPresented: $showEscortSheet) {
            if let room = appState.currentRoom {
                EscortMeView(roomId: room.id) {
                    showEscortSheet = false
                }
            }
        }
        .sheet(isPresented: $showRoomDetailsSheet) {
            if let room = appState.currentRoom {
                RoomDetailsSheet(
                    room: room,
                    roomHasActiveMedia: appState.roomHasActiveMusic[room.id] == true,
                    isActiveRoom: true,
                    onJoin: {},
                    onPreview: {
                        PeekManager.shared.peekIntoRoom(room)
                    }
                )
                .presentationDetents([.height(280)])
            }
        }
    }

    private func refreshRoomAdminCapabilities() {
        guard let serverURL = appState.serverManager.baseURL, !serverURL.isEmpty else { return }
        let token = authManager.currentUser?.accessToken
        Task {
            await adminManager.checkAdminStatus(serverURL: serverURL, token: token)
        }
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }

        guard canSendMessages else {
            print("Cannot send message: No active room session")
            return
        }

        print("Sending message: \(messageText)")
        if let userId = selectedDirectMessageUserId {
            messagingManager.sendDirectMessage(
                to: userId,
                username: selectedDirectMessageUserName ?? "User",
                content: messageText
            )
            messagingManager.markAsRead(userId: userId)
        } else {
            if let replyingToMessage {
                messagingManager.sendReply(to: replyingToMessage.id, content: messageText)
                self.replyingToMessage = nil
            } else {
                messagingManager.sendRoomMessage(messageText)
            }
        }
        AppSoundManager.shared.playSound(.messageSent)
        messageText = ""
    }

    private func openDirectMessage(with user: RoomUser) {
        selectedDirectMessageUserId = user.odId
        selectedDirectMessageUserName = user.username
        replyingToMessage = nil
        selectedChatMessageId = nil
    }

    private func startReply(to message: MessagingManager.ChatMessage) {
        guard selectedDirectMessageUserId == nil else { return }
        replyingToMessage = message
        selectedChatMessageId = message.id
    }

    private func requestRoomLock(duration: TimeInterval?) {
        pendingRoomLockActionIsUnlock = false
        pendingRoomLockDuration = duration
        if SettingsManager.shared.confirmRoomLockChanges {
            showRoomLockConfirmation = true
        } else {
            roomLockManager.lockRoom(duration: duration)
        }
    }

    private func requestRoomUnlock() {
        pendingRoomLockActionIsUnlock = true
        pendingRoomLockDuration = nil
        if SettingsManager.shared.confirmRoomLockChanges {
            showRoomLockConfirmation = true
        } else {
            roomLockManager.unlockRoom()
        }
    }

    private func formattedLockDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        if totalSeconds % 3600 == 0 {
            return "\(totalSeconds / 3600) hour\(totalSeconds / 3600 == 1 ? "" : "s")"
        }
        if totalSeconds % 60 == 0 {
            return "\(totalSeconds / 60) minute\(totalSeconds / 60 == 1 ? "" : "s")"
        }
        return "\(totalSeconds) seconds"
    }

    private func actionForSendingFile(to message: MessagingManager.ChatMessage) -> (() -> Void)? {
        guard message.type != .system else { return nil }
        return nil
    }

    private func actionForDirectMessage(to message: MessagingManager.ChatMessage) -> (() -> Void)? {
        guard message.type != .system else { return nil }
        let senderId = message.senderId
        let senderName = message.senderName
        guard !senderId.isEmpty else { return nil }
        return {
            selectedDirectMessageUserId = senderId
            selectedDirectMessageUserName = senderName
        }
    }

    private func actionForViewingSenderProfile(for message: MessagingManager.ChatMessage) -> (() -> Void)? {
        guard message.type != .system else { return nil }
        let senderId = message.senderId
        let senderName = message.senderName
        guard !senderId.isEmpty else { return nil }
        return {
            NotificationCenter.default.post(
                name: .openDirectMessage,
                object: nil,
                userInfo: ["userId": senderId, "userName": senderName]
            )
        }
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

private struct RoomTranscriptEntry: Identifiable {
    let id = UUID()
    let userId: String
    let userName: String
    let text: String
    let language: String?
    let timestamp = Date()
}

// Chat message row view
struct ChatMessageRow: View {
    let message: MessagingManager.ChatMessage
    var onReply: (() -> Void)? = nil
    var onSendFileToSender: (() -> Void)? = nil
    var onDirectMessageSender: (() -> Void)? = nil
    var onViewSenderProfile: (() -> Void)? = nil
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    @ObservedObject private var settings = SettingsManager.shared

    private var replyLabel: String? {
        guard message.replyToId != nil else { return nil }
        if message.type == .reply {
            return "Reply in thread"
        }
        return "Reply"
    }

    private var messageTextColor: Color {
        message.type == .system ? .gray : .white
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: senderSymbolName)
                .foregroundColor(avatarColor)
                .frame(width: 20, height: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.senderName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(messageTextColor)

                    if settings.showMessageTimestamps {
                        Text(formatTime(message.timestamp))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }

                if let replyLabel {
                    Label(replyLabel, systemImage: "arrowshape.turn.up.left")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                RichMessageText(
                    message: message.content,
                    font: .body,
                    color: messageTextColor,
                    alignment: .leading
                )
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.blue.opacity(0.18) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            }

            if let onReply, message.type != .system {
                Button("Reply in Thread") {
                    onReply()
                }
            }

            if let onSendFileToSender, message.type != .system {
                Button("Send File to Sender...") {
                    onSendFileToSender()
                }
            }

            if let onDirectMessageSender, message.type != .system {
                Button("Direct Message Sender") {
                    onDirectMessageSender()
                }
            }

            if let onViewSenderProfile, message.type != .system {
                Button("View Sender Profile") {
                    onViewSenderProfile()
                }
            }
        }
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

    private var senderSymbolName: String {
        if message.type == .system {
            return "info.circle.fill"
        }
        if isBuiltInVoiceLinkBot {
            return "cpu.fill"
        }
        if isBotMessage {
            return "bubble.left.and.bubble.right.fill"
        }
        return "person.crop.circle.fill"
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var isBotMessage: Bool {
        let loweredId = message.senderId.lowercased()
        let loweredName = message.senderName.lowercased()
        return loweredId.contains("bot")
            || loweredName.contains("bot")
            || loweredName.contains("assistant")
            || loweredName.contains("codex")
    }

    private var isBuiltInVoiceLinkBot: Bool {
        let loweredId = message.senderId.lowercased()
        let loweredName = message.senderName.lowercased()
        return loweredId.hasPrefix("bot:")
            || loweredName == "voicelink bot"
    }
}

struct UserRow: View {
    enum InteractionMode: String, CaseIterable {
        case audio
        case whisper
    }

    let userId: String
    let username: String
    let isMuted: Bool
    let isDeafened: Bool
    let isSpeaking: Bool
    var isCurrentUser: Bool = false

    @State private var showControls = false
    @State private var userVolume: Double = 1.0
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var audioControl = UserAudioControlManager.shared
    @ObservedObject private var monitor = LocalMonitorManager.shared
    @ObservedObject private var serverManager = ServerManager.shared
    @ObservedObject private var adminManager = AdminServerManager.shared
    @ObservedObject private var whisperManager = WhisperModeManager.shared
    @State private var shareInProgress = false
    @State private var transmitChangeInProgress = false
    @State private var interactionMode: InteractionMode = .audio
    @GestureState private var whisperPressing = false

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

    private var isBotUser: Bool {
        if let roomUser = serverManager.currentRoomUsers.first(where: { $0.odId == userId || $0.id == userId }) {
            return roomUser.isBot
        }
        let loweredId = userId.lowercased()
        let loweredName = username.lowercased()
        return loweredId.contains("bot")
            || loweredName.contains("bot")
            || loweredName.contains("assistant")
            || loweredName.contains("codex")
            || loweredName.contains("sophia")
    }

    private var isBuiltInVoiceLinkBot: Bool {
        let loweredId = userId.lowercased()
        let loweredName = username.lowercased()
        return loweredId.hasPrefix("bot:")
            || loweredName == "voicelink bot"
            || loweredName == "voicelink"
    }

    private var displayUsername: String {
        if let roomUser = serverManager.currentRoomUsers.first(where: { $0.odId == userId || $0.id == userId }) {
            return roomUser.displayName
        }
        if isBuiltInVoiceLinkBot {
            return "VoiceLink"
        }
        return username
    }

    private var botHasAudioControls: Bool {
        serverManager.currentRoomUsers.first(where: { $0.odId == userId || $0.id == userId })?.hasAudioControls ?? false
    }

    private var canManageTransmitPermission: Bool {
        !isCurrentUser && (adminManager.isAdmin || adminManager.adminRole.canManageUsers)
    }

    private var roomUserTransmitEnabled: Bool {
        serverManager.currentRoomUsers.first(where: { $0.odId == userId || $0.id == userId })?.transmitEnabled ?? true
    }

    private var canWhisperToUser: Bool {
        !isCurrentUser && !(isBotUser && !botHasAudioControls)
    }

    private var interactionButtonLabel: String {
        if interactionMode == .whisper && canWhisperToUser {
            return showControls ? "Hide Whisper Controls for \(displayUsername)" : "Show Whisper Controls for \(displayUsername)"
        }
        return showControls ? "Hide Audio Controls for \(displayUsername)" : "Show Audio Controls for \(displayUsername)"
    }

    private func prepareWhisperTarget() {
        whisperManager.setWhisperTarget(userId: userId, username: displayUsername)
    }

    private func setInteractionMode(_ mode: InteractionMode) {
        interactionMode = mode
        if mode == .whisper {
            prepareWhisperTarget()
            showControls = true
        } else if whisperManager.whisperTargetUserId == userId {
            whisperManager.clearWhisperTarget()
        }
    }

    private func startWhisperIfNeeded() {
        prepareWhisperTarget()
        if !whisperManager.isWhispering {
            whisperManager.startWhisper()
        }
    }

    private func stopWhisperIfNeeded() {
        if whisperManager.isWhispering {
            whisperManager.stopWhisper()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack {
                // Speaking indicator
                Circle()
                    .fill(isSpeaking ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)

                Text(displayUsername)
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

                if isBotUser && !botHasAudioControls {
                    HStack(spacing: 4) {
                        Text("\(displayUsername) does not have audio controls")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.75))
                    }
                    .accessibilityLabel("\(displayUsername) does not have audio controls")
                    .accessibilityHint("Use actions and context menus to interact with the bot, including sending files for processing.")
                } else {
                    VStack(alignment: .trailing, spacing: 6) {
                        if canWhisperToUser {
                            HStack(spacing: 8) {
                                Menu {
                                    Button("Audio Controls") {
                                        setInteractionMode(.audio)
                                    }

                                    Button("Whisper") {
                                        setInteractionMode(.whisper)
                                    }
                                } label: {
                                    Label(
                                        interactionMode == .whisper ? "Whisper" : "Audio Controls",
                                        systemImage: interactionMode == .whisper ? "mic.badge.plus" : "slider.horizontal.3"
                                    )
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.9))
                                }
                                .menuStyle(.borderlessButton)
                                .accessibilityLabel("Interaction mode for \(displayUsername)")

                                Button(action: {
                                    setInteractionMode(.whisper)
                                }) {
                                    Image(systemName: "mic.circle")
                                        .foregroundColor(.white.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Whisper to \(displayUsername)")
                                .accessibilityHint("Opens whisper controls for this user")
                            }
                        }

                        Button(action: {
                            if interactionMode == .whisper && canWhisperToUser {
                                prepareWhisperTarget()
                            }
                            showControls.toggle()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: showControls ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.white.opacity(0.7))
                                Text(interactionButtonLabel)
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.75))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(interactionButtonLabel)
                        .accessibilityHint(interactionMode == .whisper ? "Shows hold to whisper controls for \(displayUsername)" : "Toggles per-user audio controls for \(displayUsername)")
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .contextMenu {
                if isBotUser && !botHasAudioControls {
                    Button(action: {
                        MessagingManager.shared.sendDirectMessage(
                            to: userId,
                            username: displayUsername,
                            content: "Hi \(displayUsername)"
                        )
                    }) {
                        Label("Message \(displayUsername)", systemImage: "message")
                    }

                    Button(action: {
                        sendFileToUser()
                    }) {
                        Label("Send File to \(displayUsername)", systemImage: "doc")
                    }

                    Button(action: {
                        shareProtectedLinkToUser(keepForever: false)
                    }) {
                        Label("Share Protected Link", systemImage: "link.badge.plus")
                    }

                    Button(action: {
                        shareProtectedLinkToUser(keepForever: true)
                    }) {
                        Label("Share Permanent Link", systemImage: "link.circle")
                    }
                    .disabled(shareInProgress)

                    Divider()

                    Button(action: {
                        print("View profile of \(displayUsername)")
                    }) {
                        Label("View \(displayUsername) Profile", systemImage: "person.circle")
                    }
                } else {
                    Button(action: {
                        setInteractionMode(.whisper)
                    }) {
                        Label("Whisper", systemImage: "mic.badge.plus")
                    }

                    Button(action: {
                        MessagingManager.shared.sendDirectMessage(
                            to: userId,
                            username: displayUsername,
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

                    if canManageTransmitPermission {
                        Button(action: {
                            guard !transmitChangeInProgress else { return }
                            transmitChangeInProgress = true
                            Task {
                                _ = await adminManager.setUserTransmitEnabled(userId, enabled: true)
                                await adminManager.fetchConnectedUsers()
                                await MainActor.run {
                                    transmitChangeInProgress = false
                                }
                            }
                        }) {
                            Label("Enable User Audio Transmission", systemImage: "mic.badge.checkmark")
                        }
                        .disabled(transmitChangeInProgress || roomUserTransmitEnabled)

                        Button(action: {
                            guard !transmitChangeInProgress else { return }
                            transmitChangeInProgress = true
                            Task {
                                _ = await adminManager.setUserTransmitEnabled(userId, enabled: false)
                                await adminManager.fetchConnectedUsers()
                                await MainActor.run {
                                    transmitChangeInProgress = false
                                }
                            }
                        }) {
                            Label("Disable User Audio Transmission", systemImage: "mic.slash.badge.xmark")
                        }
                        .disabled(transmitChangeInProgress || !roomUserTransmitEnabled)

                        Button(action: {
                            guard !transmitChangeInProgress else { return }
                            transmitChangeInProgress = true
                            let nextEnabled = !roomUserTransmitEnabled
                            Task {
                                _ = await adminManager.setUserTransmitEnabled(userId, enabled: nextEnabled)
                                await adminManager.fetchConnectedUsers()
                                await MainActor.run {
                                    transmitChangeInProgress = false
                                }
                            }
                        }) {
                            Label(
                                roomUserTransmitEnabled ? "Disallow Audio Transmit" : "Allow Audio Transmit",
                                systemImage: roomUserTransmitEnabled ? "mic.slash.badge.xmark" : "mic.badge.checkmark"
                            )
                        }
                        .disabled(transmitChangeInProgress)

                        Divider()
                    }

                    Button(action: {
                        // TODO: Implement view profile
                        print("View profile of \(displayUsername)")
                    }) {
                        Label("View \(displayUsername) Profile", systemImage: "person.circle")
                    }
                }
            }

            // Expandable audio controls
            if isBotUser && !botHasAudioControls {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This bot does not have audio controls.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.82))
                    Text("Use the actions or context menu to interact with the bot, send direct messages, or send files for processing.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.04))
            } else if showControls {
                VStack(spacing: 8) {
                    if interactionMode == .whisper && canWhisperToUser {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Whisper to \(displayUsername)")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))

                            Text("Hold to whisper. Release to stop.")
                                .font(.caption2)
                                .foregroundColor(.gray)

                            Button(action: {}) {
                                HStack {
                                    Image(systemName: (whisperManager.isWhispering && whisperManager.whisperTargetUserId == userId) || whisperPressing ? "mic.fill" : "mic")
                                    Text((whisperManager.isWhispering && whisperManager.whisperTargetUserId == userId) || whisperPressing ? "Whispering..." : "Hold to Whisper")
                                }
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(((whisperManager.isWhispering && whisperManager.whisperTargetUserId == userId) || whisperPressing) ? Color.orange.opacity(0.35) : Color.blue.opacity(0.28))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 0)
                                    .updating($whisperPressing) { _, state, _ in
                                        state = true
                                    }
                                    .onChanged { _ in
                                        startWhisperIfNeeded()
                                    }
                                    .onEnded { _ in
                                        stopWhisperIfNeeded()
                                    }
                            )
                            .keyboardShortcut(.space, modifiers: [])
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.01)
                                    .onEnded { _ in
                                        startWhisperIfNeeded()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                            stopWhisperIfNeeded()
                                        }
                                    }
                            )
                            .accessibilityLabel("Hold to whisper to \(displayUsername)")
                            .accessibilityHint("Press and hold to whisper to this user, then release to stop.")

                            Button(action: {
                                setInteractionMode(.audio)
                            }) {
                                Label("Switch to Audio Controls", systemImage: "slider.horizontal.3")
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
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
                                            LocalMonitorManager.shared.setInputGain(settings.effectiveInputVolume)
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
                                    monitor.toggleMonitoring()
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
                            Text("You cannot mute yourself in this list. Use main room mute controls.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.02))
            }
        }
        .cornerRadius(8)
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
                        let smbSummary = link.smb?.uris.first.map { _ in " SMB path available." } ?? ""
                        let body = "Protected link copied to clipboard for \(self.username).\(expiryText)\(smbSummary)"
                        var outgoingLines = ["Secure file link: \(link.url)"]
                        if let webURL = link.webURL, !webURL.isEmpty, webURL != link.url {
                            outgoingLines.append("Web link: \(webURL)")
                        }
                        if let copyPartyURL = link.copyPartyURL, !copyPartyURL.isEmpty, copyPartyURL != link.url {
                            outgoingLines.append("CopyParty link: \(copyPartyURL)")
                        }
                        if let smbURI = link.smb?.uris.first, !smbURI.isEmpty {
                            outgoingLines.append("SMB path: \(smbURI)")
                        }
                        MessagingManager.shared.sendSystemMessage(body)
                        MessagingManager.shared.sendDirectMessage(
                            to: self.username,
                            username: self.username,
                            content: outgoingLines.joined(separator: "\n")
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
    static let internalVolumeBoost: Double = 0.35
    static let maxBoostedVolume: Double = 1.6
    private var isApplyingAudioDeviceSelection = false
    @Published var audioRecoveryInProgress: Bool = false
    @Published var audioRecoveryStatusMessage: String?

    struct ManagedFederationServer: Identifiable, Hashable, Codable {
        let url: String
        let name: String
        let description: String
        var isHidden: Bool = false

        var id: String { url }
    }

    private static let managedFederationServersKey = "managedFederationServers"

    static let defaultManagedFederationServers: [ManagedFederationServer] = [
        ManagedFederationServer(
            url: APIEndpointResolver.canonicalMainBase,
            name: "Main VoiceLink",
            description: "Primary managed VoiceLink federation authority and default production peer."
        ),
        ManagedFederationServer(
            url: APIEndpointResolver.communityNode2Base,
            name: "Community VPS",
            description: "Secondary managed federation peer used for continuity, fallback, and maintenance handoff."
        )
    ]

    @Published var managedFederationServers: [ManagedFederationServer] = []

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
    @Published var preferLocalServer: Bool = false
    @Published var reconnectOnDisconnect: Bool = true
    @Published var connectionTimeout: Double = 30

    // PTT Settings
    @Published var pttEnabled: Bool = false
    @Published var pttKey: String = "Space"
    @Published var simultaneousTransmitWhileWhispering: Bool = false
    @Published var voiceActivatedBotConversations: Bool = true

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
    @Published var showRoomDescriptions: Bool = true
    @Published var showMessageTimestamps: Bool = true
    @Published var confirmRoomLockChanges: Bool = true
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

    var adminPresenceModeEnabled: Bool {
        get { adminGodModeEnabled || adminInvisibleMode }
        set {
            adminGodModeEnabled = newValue
            adminInvisibleMode = newValue
        }
    }

    // Profile Settings
    @Published var userNickname: String = ""
    @Published var userProfileLinks: [String] = []

    // Available devices
    @Published var availableInputDevices: [String] = ["Default"]
    @Published var availableOutputDevices: [String] = ["Default"]
    @Published private(set) var hasDetectedInputDevice: Bool = false
    @Published private(set) var hasDetectedOutputDevice: Bool = false

    var effectiveInputVolume: Double {
        boostedVolume(inputVolume)
    }

    var effectiveOutputVolume: Double {
        boostedVolume(outputVolume)
    }

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
        autoConnect = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true
        preferLocalServer = UserDefaults.standard.object(forKey: "preferLocalServer") as? Bool ?? false
        pttEnabled = UserDefaults.standard.bool(forKey: "pttEnabled")
        simultaneousTransmitWhileWhispering = UserDefaults.standard.object(forKey: "simultaneousTransmitWhileWhispering") as? Bool ?? false
        voiceActivatedBotConversations = UserDefaults.standard.object(forKey: "voiceActivatedBotConversations") as? Bool ?? true
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
        showRoomDescriptions = UserDefaults.standard.object(forKey: "showRoomDescriptions") as? Bool ?? true
        showMessageTimestamps = UserDefaults.standard.object(forKey: "showMessageTimestamps") as? Bool ?? true
        confirmRoomLockChanges = UserDefaults.standard.object(forKey: "confirmRoomLockChanges") as? Bool ?? true
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
        let legacyGodMode = UserDefaults.standard.object(forKey: "adminGodModeEnabled") as? Bool ?? false
        let legacyInvisibleMode = UserDefaults.standard.object(forKey: "adminInvisibleMode") as? Bool ?? false
        let unifiedAdminPresenceMode = UserDefaults.standard.object(forKey: "adminPresenceModeEnabled") as? Bool
        adminPresenceModeEnabled = unifiedAdminPresenceMode ?? (legacyGodMode || legacyInvisibleMode)

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
            preferLocalServer = false
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
            showRoomDescriptions = true
            showMessageTimestamps = true
            confirmRoomLockChanges = true
            simultaneousTransmitWhileWhispering = false
            voiceActivatedBotConversations = true
            allowPreviewWhenMediaActive = true
            previewSoundCuesEnabled = true
            defaultRoomPrimaryAction = .joinOrShow
            adminPresenceModeEnabled = false
            UserDefaults.standard.set(true, forKey: "settingsInitialized")
        }

        loadManagedFederationServers()
    }

    private func boostedVolume(_ sliderValue: Double) -> Double {
        min(max(sliderValue + Self.internalVolumeBoost, 0), Self.maxBoostedVolume)
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
        UserDefaults.standard.set(simultaneousTransmitWhileWhispering, forKey: "simultaneousTransmitWhileWhispering")
        UserDefaults.standard.set(voiceActivatedBotConversations, forKey: "voiceActivatedBotConversations")
        UserDefaults.standard.set(spatialAudioEnabled, forKey: "spatialAudioEnabled")

        // UI settings
        UserDefaults.standard.set(showAudioControlsOnStartup, forKey: "showAudioControlsOnStartup")
        UserDefaults.standard.set(closeButtonBehavior.rawValue, forKey: "closeButtonBehavior")
        UserDefaults.standard.set(openMainWindowOnLaunch, forKey: "openMainWindowOnLaunch")
        UserDefaults.standard.set(confirmBeforeQuit, forKey: "confirmBeforeQuit")
        UserDefaults.standard.set(showRoomDescriptions, forKey: "showRoomDescriptions")
        UserDefaults.standard.set(showMessageTimestamps, forKey: "showMessageTimestamps")
        UserDefaults.standard.set(confirmRoomLockChanges, forKey: "confirmRoomLockChanges")
        UserDefaults.standard.set(allowPreviewWhenMediaActive, forKey: "allowPreviewWhenMediaActive")
        UserDefaults.standard.set(previewSoundCuesEnabled, forKey: "previewSoundCuesEnabled")
        UserDefaults.standard.set(roomPreviewPolicyByRoom, forKey: "roomPreviewPolicyByRoom")
        UserDefaults.standard.set(defaultRoomPrimaryAction.rawValue, forKey: "defaultRoomPrimaryAction")
        UserDefaults.standard.set(adminGodModeEnabled, forKey: "adminGodModeEnabled")
        UserDefaults.standard.set(adminInvisibleMode, forKey: "adminInvisibleMode")
        UserDefaults.standard.set(adminPresenceModeEnabled, forKey: "adminPresenceModeEnabled")

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
        saveManagedFederationServers()

        // Apply selected devices so audio routing follows settings in active sessions.
        applySelectedAudioDevices()
    }

    var visibleManagedFederationServers: [ManagedFederationServer] {
        managedFederationServers.filter { !$0.isHidden }
    }

    func moveManagedFederationServer(_ server: ManagedFederationServer, offset: Int) {
        guard let index = managedFederationServers.firstIndex(where: { $0.id == server.id }) else { return }
        let newIndex = index + offset
        guard managedFederationServers.indices.contains(newIndex) else { return }
        let moved = managedFederationServers.remove(at: index)
        managedFederationServers.insert(moved, at: newIndex)
        saveManagedFederationServers()
    }

    func setManagedFederationServerHidden(_ server: ManagedFederationServer, hidden: Bool) {
        guard let index = managedFederationServers.firstIndex(where: { $0.id == server.id }) else { return }
        managedFederationServers[index].isHidden = hidden
        saveManagedFederationServers()
    }

    private func loadManagedFederationServers() {
        let defaults = Self.defaultManagedFederationServers
        guard
            let data = UserDefaults.standard.data(forKey: Self.managedFederationServersKey),
            let saved = try? JSONDecoder().decode([ManagedFederationServer].self, from: data)
        else {
            managedFederationServers = defaults
            return
        }

        var merged: [ManagedFederationServer] = []
        var seen = Set<String>()

        for savedServer in saved {
            if let match = defaults.first(where: { $0.url == savedServer.url }) {
                merged.append(
                    ManagedFederationServer(
                        url: match.url,
                        name: match.name,
                        description: match.description,
                        isHidden: savedServer.isHidden
                    )
                )
                seen.insert(match.url)
            }
        }

        for fallback in defaults where !seen.contains(fallback.url) {
            merged.append(fallback)
        }

        managedFederationServers = merged
    }

    private func saveManagedFederationServers() {
        if let data = try? JSONEncoder().encode(managedFederationServers) {
            UserDefaults.standard.set(data, forKey: Self.managedFederationServersKey)
        }
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
            let deviceName = coreAudioDeviceName(deviceID: deviceID) ?? ""
            guard !deviceName.isEmpty else { continue }
            guard isDeviceAlive(deviceID) else { continue }

            if hasChannels(deviceID: deviceID, isInput: true) {
                inputDevices.append(deviceName)
            }

            if hasChannels(deviceID: deviceID, isInput: false) {
                outputDevices.append(deviceName)
            }
        }

        let uniqueInput = Array(Set(inputDevices.filter { !$0.isEmpty }))
        let uniqueOutput = Array(Set(outputDevices.filter { !$0.isEmpty }))

        hasDetectedInputDevice = true
        hasDetectedOutputDevice = true
        availableInputDevices = ["Default"] + uniqueInput.filter { $0 != "Default" }.sorted()
        availableOutputDevices = ["Default"] + uniqueOutput.filter { $0 != "Default" }.sorted()

        if !availableInputDevices.contains(inputDevice) {
            inputDevice = "Default"
        }

        if !availableOutputDevices.contains(outputDevice) {
            outputDevice = "Default"
        }

        if availableInputDevices.count <= 1 && availableOutputDevices.count <= 1 {
            audioRecoveryStatusMessage = "No audio devices were detected from macOS CoreAudio."
        } else {
            audioRecoveryStatusMessage = nil
        }
    }

    func restartMacOSAudioServices() {
        guard !audioRecoveryInProgress else { return }
        audioRecoveryInProgress = true
        audioRecoveryStatusMessage = "Restarting macOS audio services..."

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                "do shell script \"killall coreaudiod\" with administrator privileges"
            ]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                let errorText = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines)

                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.audioRecoveryInProgress = false
                    self.detectAudioDevices()

                    if process.terminationStatus == 0 {
                        if self.availableInputDevices.count > 1 || self.availableOutputDevices.count > 1 {
                            self.audioRecoveryStatusMessage = "Audio services restarted and device list refreshed."
                        } else {
                            self.audioRecoveryStatusMessage = "Audio services restarted, but macOS still reports no devices."
                        }
                    } else {
                        self.audioRecoveryStatusMessage = (errorText?.isEmpty == false ? errorText : "Audio service restart did not complete.")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.audioRecoveryInProgress = false
                    self.audioRecoveryStatusMessage = "Failed to restart audio services: \(error.localizedDescription)"
                }
            }
        }
    }

    func applySelectedAudioDevices(notifyChange: Bool = true) {
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
            guard isDeviceAlive(deviceID) else {
                continue
            }
            let isInput = scope == kAudioDevicePropertyScopeInput
            guard hasChannels(deviceID: deviceID, isInput: isInput) else { continue }

            let deviceName = coreAudioDeviceName(deviceID: deviceID) ?? ""
            if deviceName == targetName {
                return deviceID
            }
        }

        return nil
    }

    private func coreAudioDeviceName(deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cfName: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfName) { pointer in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, pointer)
        }
        guard status == noErr else { return nil }
        if let resolved = cfName?.takeUnretainedValue() {
            return resolved as String
        }
        return nil
    }

    private func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr else {
            return false
        }
        return alive != 0
    }

    private func hasChannels(deviceID: AudioDeviceID, isInput: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawBuffer.deallocate() }
        let bufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(bufferList)
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
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
    @State private var isSubmittingDiagnostics = false
    @State private var diagnosticsSubmissionStatus: String?
    @AppStorage("voicelink.advanced.debugLoggingEnabled") private var debugLoggingEnabled = false
    @AppStorage("voicelink.advanced.showConnectionStats") private var showConnectionStats = false
    @AppStorage("voicelink.advanced.audioCodec") private var selectedAudioCodec = "Opus"

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
                    appState.closeSettings()
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
            Toggle("Prefer local server when available", isOn: $settings.preferLocalServer)
                .onChange(of: settings.preferLocalServer) { _ in settings.saveSettings() }
                .accessibilityHint("When enabled, VoiceLink tries a local server before managed or federated servers. Leave off to use remote API and federation first.")
            Toggle("Show room descriptions", isOn: $settings.showRoomDescriptions)
                .onChange(of: settings.showRoomDescriptions) { _ in settings.saveSettings() }
                .accessibilityHint("Shows or hides room description text in room lists, room details, and related room views.")
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
                TextField("Nickname shown to other VoiceLink users", text: $settings.userNickname)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Nickname")
                    .accessibilityHint("Enter the nickname that other users will see for your account in rooms and chat.")
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
                    let accountTypeName: String = {
                        let provider = (user.authProvider ?? user.authMethod.rawValue).lowercased()
                        switch provider {
                        case "local", "voicelink", "email":
                            return "VoiceLink Account"
                        case "whmcs":
                            return "WHMCS Account"
                        case "mastodon":
                            return "Mastodon Account"
                        case "google":
                            return "Google Account"
                        case "apple":
                            return "Apple Account"
                        case "github":
                            return "GitHub Account"
                        default:
                            return "\(user.authMethod.displayName) Account"
                        }
                    }()
                    let roleName = (user.role?.isEmpty == false ? user.role! : "member")
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized
                    Text("\(accountTypeName). Role: \(roleName). Signed in as \(user.displayName) (\(user.email ?? user.username)).")
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
        SettingsSection(title: "Audio Controls") {
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
            .onChange(of: settings.inputVolume) { _ in
                settings.saveSettings()
                LocalMonitorManager.shared.setInputGain(settings.effectiveInputVolume)
            }

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
            .onChange(of: settings.outputVolume) { _ in
                settings.saveSettings()
                SpatialAudioEngine.shared.refreshOutputMix()
            }

            Toggle("Play startup welcome sound", isOn: Binding(
                get: { AppSoundManager.shared.startupIntroEnabled },
                set: { newValue in
                    AppSoundManager.shared.startupIntroEnabled = newValue
                    AppSoundManager.shared.saveSettings()
                }
            ))

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

            HStack(spacing: 12) {
                Button("Refresh Device List") {
                    settings.detectAudioDevices()
                }
                .buttonStyle(.bordered)

                Button(settings.audioRecoveryInProgress ? "Restarting Audio Services..." : "Restart Audio Services") {
                    settings.restartMacOSAudioServices()
                }
                .buttonStyle(.borderedProminent)
                .disabled(settings.audioRecoveryInProgress)
            }

            if let status = settings.audioRecoveryStatusMessage, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Picker("Audio Codec", selection: $selectedAudioCodec) {
                Text("Opus (Recommended)").tag("Opus")
                Text("PCM (.wav)").tag("PCM")
                Text("FLAC").tag("FLAC")
            }
            .pickerStyle(.menu)
        }

        SettingsSection(title: "Audio Details") {
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
                    value: inputStatusText
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
                    value: outputStatusText
                )
                statusRow(
                    label: "Output Channels",
                    value: detectedOutputChannelSummary
                )
            }
            .accessibilityElement(children: .contain)
            Text("These values update to show the currently selected devices, the system defaults VoiceLink is using, and the detected channel layout.")
                .font(.caption)
                .foregroundColor(.gray)
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

    private var inputStatusText: String {
        if settings.inputDevice == "Default" {
            return detectedDefaultInputName == "Not detected" ? "Using system default (not enumerated)" : "Using system default"
        }
        return settings.availableInputDevices.contains(settings.inputDevice) ? "Connected" : "Unavailable"
    }

    private var outputStatusText: String {
        if settings.outputDevice == "Default" {
            return detectedDefaultOutputName == "Not detected" ? "Using system default (not enumerated)" : "Using system default"
        }
        return settings.availableOutputDevices.contains(settings.outputDevice) ? "Connected" : "Unavailable"
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

        guard let name = coreAudioDeviceName(deviceID: deviceID),
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

            if coreAudioDeviceName(deviceID: deviceID) == targetName {
                return deviceID
            }
        }
        return nil
    }

    private func coreAudioDeviceName(deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cfName: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfName) { pointer in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, pointer)
        }
        guard status == noErr else { return nil }
        if let resolved = cfName?.takeUnretainedValue() {
            return resolved as String
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
            Toggle("Show message timestamps", isOn: $settings.showMessageTimestamps)
            Toggle("Confirm before locking or unlocking rooms", isOn: $settings.confirmRoomLockChanges)
        }

        SettingsSection(title: "Desktop Notifications") {
            Toggle("Enable desktop notifications", isOn: $settings.desktopNotifications)

            Button("Test Notification") {
                let center = UNUserNotificationCenter.current()
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    let content = UNMutableNotificationContent()
                    content.title = "VoiceLink"
                    content.body = "Test notification"
                    content.sound = .default
                    let request = UNNotificationRequest(
                        identifier: "voicelink-test-notification",
                        content: content,
                        trigger: nil
                    )
                    center.add(request, withCompletionHandler: nil)
                }
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
                TextField("Folder path for received files", text: $settings.saveReceivedFilesTo)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Save path")
                    .accessibilityHint("Enter the local folder where received files should be saved automatically.")
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

        SettingsSection(title: "Shared Access") {
            let copyPartyBase = CopyPartyManager.shared.config.primaryServer
            let smbHosts = CopyPartyManager.shared.config.smbHostnames.joined(separator: ", ")
            let localSMBHosts = CopyPartyManager.shared.config.localSMBHostnames.joined(separator: ", ")
            let centralSMBHosts = CopyPartyManager.shared.config.centralSMBHostnames.joined(separator: ", ")
            Text("Room files can be shared as clickable web links through CopyParty or mounted storage paths over SMB.")
                .font(.caption)
                .foregroundColor(.gray)

            HStack(alignment: .top) {
                Text("CopyParty")
                    .fontWeight(.semibold)
                Spacer()
                Text(copyPartyBase)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("CopyParty server")
            }

            HStack(alignment: .top) {
                Text("SMB Hosts")
                    .fontWeight(.semibold)
                Spacer()
                Text(smbHosts)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("SMB hostnames")
            }

            HStack(alignment: .top) {
                Text("Local SMB")
                    .fontWeight(.semibold)
                Spacer()
                Text(localSMBHosts.isEmpty ? "Use this install's local SMB host" : localSMBHosts)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Local SMB hostnames")
            }

            HStack(alignment: .top) {
                Text("Local Share")
                    .fontWeight(.semibold)
                Spacer()
                Text(CopyPartyManager.shared.config.localSMBPreferredShare)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Preferred local SMB share")
            }

            HStack(alignment: .top) {
                Text("Central SMB")
                    .fontWeight(.semibold)
                Spacer()
                Text(centralSMBHosts.isEmpty ? "Use the shared backup SMB layer" : centralSMBHosts)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Central SMB hostnames")
            }

            HStack(alignment: .top) {
                Text("Central Share")
                    .fontWeight(.semibold)
                Spacer()
                Text(CopyPartyManager.shared.config.centralSMBPreferredShare)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Preferred central SMB share")
            }

            HStack(alignment: .top) {
                Text("Preferred Share")
                    .fontWeight(.semibold)
                Spacer()
                Text(CopyPartyManager.shared.config.smbPreferredShare)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Preferred SMB share")
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
                                Text("@\(user.username)@\(instance)")
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
            Toggle("Enable debug logging", isOn: $debugLoggingEnabled)
                .accessibilityHint("Turns on additional local diagnostic logging for troubleshooting.")
            Toggle("Show connection stats", isOn: $showConnectionStats)
                .accessibilityHint("Shows extra connection and transport details in the app where supported.")
        }

        SettingsSection(title: "Diagnostics Submission Log") {
            VStack(alignment: .leading, spacing: 10) {
                Button(isSubmittingDiagnostics ? "Submitting Diagnostics..." : "Submit Diagnostics to Server") {
                    submitDiagnosticsFromAdvanced()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmittingDiagnostics)

                if let diagnosticsSubmissionStatus, !diagnosticsSubmissionStatus.isEmpty {
                    Text(diagnosticsSubmissionStatus)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            let submissionEntries = UserDefaults.standard.stringArray(forKey: "voicelink.diagnosticsSubmissionLog") ?? []
            if submissionEntries.isEmpty {
                Text("No diagnostics or bug-report submissions have been logged on this Mac yet.")
                    .font(.caption)
                    .foregroundColor(.gray)
            } else {
                ForEach(Array(submissionEntries.suffix(10).reversed()), id: \.self) { entry in
                    Text(entry)
                        .font(.caption.monospaced())
                        .foregroundColor(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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

    private func submitDiagnosticsFromAdvanced() {
        isSubmittingDiagnostics = true
        diagnosticsSubmissionStatus = nil
        let report = BugReport(
            title: "macOS diagnostics report",
            description: "Manual diagnostics report submitted from macOS Advanced settings.",
            category: "diagnostics",
            severity: "medium",
            anonymous: false,
            submittedBy: NSFullUserName(),
            mastodonHandle: nil,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            platform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        AnnouncementsManager.shared.submitBugReport(report) { result in
            isSubmittingDiagnostics = false
            switch result {
            case .success:
                diagnosticsSubmissionStatus = "Diagnostics sent. VoiceLink shared a support snapshot from this Mac so we can see what went wrong and what the app tried next."
            case .failure(let error):
                diagnosticsSubmissionStatus = "VoiceLink could not send the diagnostics just yet. \(error.localizedDescription) You can keep using the app and try again after the connection settles."
            }
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
