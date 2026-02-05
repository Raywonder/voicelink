import SwiftUI
import AppKit

// MARK: - Local Server Discovery
class LocalServerDiscovery: ObservableObject {
    static let shared = LocalServerDiscovery()

    @Published var localServerFound = false
    @Published var localServerURL: String?
    @Published var localServerName: String?
    @Published var isScanning = false

    private var scanTimer: Timer?

    // Common ports where VoiceLink server might run
    private let scanPorts = [4004, 3010, 8080, 3000]

    init() {
        // Start scanning on init
        startPeriodicScan()
    }

    func startPeriodicScan() {
        // Scan immediately
        scanForLocalServer()

        // Then scan every 30 seconds
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.scanForLocalServer()
        }
    }

    func stopScanning() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    func scanForLocalServer() {
        guard !isScanning else { return }
        isScanning = true

        let group = DispatchGroup()
        var foundServer: (url: String, name: String)?

        for port in scanPorts {
            group.enter()

            let url = "http://localhost:\(port)/api/info"
            guard let requestURL = URL(string: url) else {
                group.leave()
                continue
            }

            var request = URLRequest(url: requestURL)
            request.timeoutInterval = 2

            URLSession.shared.dataTask(with: request) { data, response, error in
                defer { group.leave() }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let serverName = json["name"] as? String else {
                    return
                }

                // Found a server
                foundServer = (url: "http://localhost:\(port)", name: serverName)
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            self?.isScanning = false

            if let server = foundServer {
                self?.localServerFound = true
                self?.localServerURL = server.url
                self?.localServerName = server.name
            } else {
                self?.localServerFound = false
                self?.localServerURL = nil
                self?.localServerName = nil
            }
        }
    }

    func autoPairWithLocalServer(completion: @escaping (Bool) -> Void) {
        guard let url = localServerURL else {
            completion(false)
            return
        }

        // Check if already paired
        if PairingManager.shared.isServerPaired(url: url) {
            // Already paired, just connect
            ServerManager.shared.connectToURL(url)
            completion(true)
            return
        }

        // Try to auto-pair (local servers may allow auto-pair)
        guard let pairURL = URL(string: "\(url)/api/auto-pair") else {
            completion(false)
            return
        }

        var request = URLRequest(url: pairURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "clientId": getClientId(),
            "clientName": Host.current().localizedName ?? "Mac Client",
            "isLocal": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success else {
                    completion(false)
                    return
                }

                // Save as linked server
                let server = LinkedServer(
                    id: json["serverId"] as? String ?? UUID().uuidString,
                    name: self?.localServerName ?? "Local Server",
                    url: url,
                    ownerId: nil,
                    pairedAt: Date(),
                    accessToken: json["accessToken"] as? String,
                    authMethod: .pairingCode,
                    authUserId: nil,
                    authUsername: nil
                )
                PairingManager.shared.addLinkedServer(server)

                // Connect
                ServerManager.shared.connectToURL(url)
                completion(true)
            }
        }.resume()
    }

    private func getClientId() -> String {
        if let clientId = UserDefaults.standard.string(forKey: "clientId") {
            return clientId
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: "clientId")
        return newId
    }
}

// MARK: - Menu Bar View (Client Only)
struct MenuBarView: View {
    @ObservedObject var serverManager = ServerManager.shared
    @ObservedObject var localDiscovery = LocalServerDiscovery.shared
    @ObservedObject var authManager = AuthenticationManager.shared
    @Binding var showMainWindow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Connection Status
            HStack {
                Circle()
                    .fill(serverManager.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(serverManager.isConnected ? "Connected" : "Disconnected")
                    .font(.headline)
            }

            if serverManager.isConnected {
                Text(serverManager.connectedServer)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !serverManager.currentRoomUsers.isEmpty {
                    Text("\(serverManager.currentRoomUsers.count) user(s) in room")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Auth Status
            if let user = authManager.currentUser {
                Divider()
                HStack(spacing: 4) {
                    Image(systemName: user.authMethod.icon)
                        .font(.caption)
                        .foregroundColor(.purple)
                    Text(user.fullHandle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Divider()

            // Quick Connect Options
            Text("Quick Connect")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Federation (Main Node)") {
                serverManager.connectToMainServer()
            }
            .disabled(serverManager.isConnected && serverManager.connectedServer == "Main Server")

            Button("Community Server (vps1.tappedin.fm)") {
                serverManager.connectToCommunityServer()
            }
            .disabled(serverManager.isConnected && serverManager.connectedServer == "Community Server")

            // Local server option (if found)
            if localDiscovery.localServerFound {
                Button("Local Server (\(localDiscovery.localServerName ?? "localhost"))") {
                    if let url = localDiscovery.localServerURL {
                        localDiscovery.autoPairWithLocalServer { success in
                            if !success {
                                // Manual connect if auto-pair fails
                                serverManager.connectToURL(url)
                            }
                        }
                    }
                }
                .disabled(serverManager.isConnected && serverManager.connectedServer.contains("Local"))

                // Manage Devices option for local server - opens in new window
                Button(action: {
                    if let serverURL = localDiscovery.localServerURL {
                        openDeviceManagementWindow(serverURL: serverURL)
                    }
                }) {
                    HStack {
                        Image(systemName: "laptopcomputer.and.iphone")
                        Text("Manage Devices")
                    }
                }
            } else {
                Text("No local server found")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if serverManager.isConnected {
                Button("Disconnect") {
                    serverManager.disconnect()
                }
            }

            Divider()

            // App Controls
            Button("Open VoiceLink") {
                showMainWindow = true
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.contains("VoiceLink") }) {
                    window.makeKeyAndOrderFront(nil)
                } else if let window = NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            .keyboardShortcut("o", modifiers: [.command])

            Divider()

            Button("Quit VoiceLink") {
                serverManager.disconnect()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .padding()
        .frame(width: 220)
    }

    private func openDeviceManagementWindow(serverURL: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manage Linked Devices"
        window.center()
        window.contentView = NSHostingView(rootView: DeviceManagementView(serverURL: serverURL))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Status Bar Controller
class StatusBarController: ObservableObject {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var popover: NSPopover

    @Published var showMainWindow = false

    init() {
        statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "VoiceLink")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hostingController = NSHostingController(
            rootView: MenuBarView(showMainWindow: Binding(
                get: { self.showMainWindow },
                set: { self.showMainWindow = $0 }
            ))
        )
        popover.contentViewController = hostingController
        popover.behavior = .transient

        // Update icon based on connection status
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(connectionStatusChanged),
            name: .serverConnectionChanged,
            object: nil
        )
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc func connectionStatusChanged() {
        updateIcon(isConnected: ServerManager.shared.isConnected)
    }

    func updateIcon(isConnected: Bool) {
        if let button = statusItem.button {
            let symbolName = isConnected ? "waveform.circle.fill" : "waveform.circle"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VoiceLink")
        }
    }
}

// MARK: - Connection Notification
extension Notification.Name {
    static let serverConnectionChanged = Notification.Name("serverConnectionChanged")
}
