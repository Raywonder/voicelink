import SwiftUI
import AppKit

// MARK: - Server Mode Manager
class ServerModeManager: ObservableObject {
    static let shared = ServerModeManager()

    @Published var isServerRunning = false
    @Published var serverStatus: String = "Stopped"
    @Published var connectedClients: Int = 0
    @Published var serverPort: Int = 4004

    private var serverProcess: Process?
    private var outputPipe: Pipe?

    // Path to bundled Node.js server or standalone server
    var serverScriptPath: String {
        // First check for bundled server in app resources
        if let bundledPath = Bundle.main.path(forResource: "standalone", ofType: "js", inDirectory: "server") {
            return bundledPath
        }
        // Fallback to development path
        return "/Volumes/Rayray/dev/apps/voicelink-local/server/standalone.js"
    }

    func startServer() {
        guard !isServerRunning else { return }

        // Kill any existing processes on the port first
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/bin/bash")
        killTask.arguments = ["-c", "lsof -ti:\(serverPort) | xargs kill -9 2>/dev/null || true"]
        try? killTask.run()
        killTask.waitUntilExit()

        // Wait a moment
        Thread.sleep(forTimeInterval: 0.5)

        serverProcess = Process()

        // Find node executable
        let nodePaths = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
        var nodePath = "/usr/local/bin/node"
        for path in nodePaths {
            if FileManager.default.fileExists(atPath: path) {
                nodePath = path
                break
            }
        }

        serverProcess?.executableURL = URL(fileURLWithPath: nodePath)
        serverProcess?.arguments = [serverScriptPath]
        serverProcess?.currentDirectoryURL = URL(fileURLWithPath: "/Volumes/Rayray/dev/apps/voicelink-local")
        serverProcess?.environment = ProcessInfo.processInfo.environment.merging([
            "PORT": String(serverPort),
            "NODE_ENV": "development"
        ]) { _, new in new }

        outputPipe = Pipe()
        serverProcess?.standardOutput = outputPipe
        serverProcess?.standardError = outputPipe

        outputPipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                print("[Server] \(output)")
                // Parse output for client count, etc.
                if output.contains("running on") {
                    DispatchQueue.main.async {
                        self?.serverStatus = "Running on port \(self?.serverPort ?? 4004)"
                    }
                }
            }
        }

        serverProcess?.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isServerRunning = false
                self?.serverStatus = "Stopped"
            }
        }

        do {
            try serverProcess?.run()
            DispatchQueue.main.async {
                self.isServerRunning = true
                self.serverStatus = "Starting..."
            }
            print("Server started with PID: \(serverProcess?.processIdentifier ?? 0)")
        } catch {
            print("Failed to start server: \(error)")
            DispatchQueue.main.async {
                self.serverStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
        outputPipe = nil
        DispatchQueue.main.async {
            self.isServerRunning = false
            self.serverStatus = "Stopped"
        }
    }

    func restartServer() {
        stopServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.startServer()
        }
    }
}

// MARK: - Menu Bar View
struct MenuBarView: View {
    @ObservedObject var serverManager = ServerModeManager.shared
    @ObservedObject var deviceManager = ServerDeviceManager.shared
    @Binding var showMainWindow: Bool
    @State private var showDeviceManagement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Server Status
            HStack {
                Circle()
                    .fill(serverManager.isServerRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(serverManager.isServerRunning ? "Server Running" : "Server Stopped")
                    .font(.headline)
            }

            if serverManager.isServerRunning {
                Text("Port: \(serverManager.serverPort)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Clients: \(serverManager.connectedClients)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Linked devices count
                HStack {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.caption)
                    Text("\(deviceManager.linkedDevices.count) linked device(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Server Controls
            if serverManager.isServerRunning {
                Button("Stop Server") {
                    serverManager.stopServer()
                }

                Button("Restart Server") {
                    serverManager.restartServer()
                }

                Button("Manage Devices...") {
                    showDeviceManagement = true
                }
            } else {
                Button("Start Server") {
                    serverManager.startServer()
                }
            }

            Divider()

            // App Controls
            Button("Open VoiceLink Window") {
                showMainWindow = true
                NSApp.activate(ignoringOtherApps: true)
                // Show or create window
                if let window = NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                    window.center()
                }
            }

            Divider()

            Button("Quit VoiceLink") {
                serverManager.stopServer()
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 220)
        .sheet(isPresented: $showDeviceManagement) {
            DeviceManagementView()
        }
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
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "VoiceLink")
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
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func updateIcon(isConnected: Bool) {
        if let button = statusItem.button {
            let symbolName = isConnected ? "waveform.circle.fill" : "waveform.circle"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VoiceLink")
        }
    }
}

// MARK: - App Mode Enum
enum AppMode: String, CaseIterable {
    case client = "Client Only"
    case server = "Server Only"
    case both = "Client + Server"

    var description: String {
        switch self {
        case .client: return "Connect to servers, no local hosting"
        case .server: return "Host server only, no UI (menubar)"
        case .both: return "Full app with local server"
        }
    }
}

// MARK: - Server Device Manager
class ServerDeviceManager: ObservableObject {
    static let shared = ServerDeviceManager()

    @Published var linkedDevices: [ServerLinkedDevice] = []

    init() {
        loadLinkedDevices()
    }

    func addDevice(_ device: ServerLinkedDevice) {
        if !linkedDevices.contains(where: { $0.clientId == device.clientId }) {
            linkedDevices.append(device)
            saveLinkedDevices()
        }
    }

    func updateLastSeen(clientId: String) {
        if let index = linkedDevices.firstIndex(where: { $0.clientId == clientId }) {
            linkedDevices[index].lastSeen = Date()
            saveLinkedDevices()
        }
    }

    func revokeDevice(_ device: ServerLinkedDevice, completion: @escaping (Bool) -> Void) {
        // Mark as revoked locally
        if let index = linkedDevices.firstIndex(where: { $0.id == device.id }) {
            linkedDevices[index].isRevoked = true
            saveLinkedDevices()
        }

        // Send revocation via WebSocket to connected clients
        ServerManager.shared.sendRevocation(clientId: device.clientId) { success in
            if success {
                // Remove from list after successful revocation
                self.linkedDevices.removeAll { $0.id == device.id }
                self.saveLinkedDevices()
            }
            completion(success)
        }
    }

    func revokeAllDevices(completion: @escaping (Bool) -> Void) {
        let group = DispatchGroup()
        var allSuccess = true

        for device in linkedDevices {
            group.enter()
            revokeDevice(device) { success in
                if !success { allSuccess = false }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(allSuccess)
        }
    }

    private func loadLinkedDevices() {
        if let data = UserDefaults.standard.data(forKey: "serverLinkedDevices"),
           let devices = try? JSONDecoder().decode([ServerLinkedDevice].self, from: data) {
            linkedDevices = devices
        }
    }

    private func saveLinkedDevices() {
        if let data = try? JSONEncoder().encode(linkedDevices) {
            UserDefaults.standard.set(data, forKey: "serverLinkedDevices")
        }
    }
}

// MARK: - Server Linked Device Model
struct ServerLinkedDevice: Codable, Identifiable {
    let id: String
    let clientId: String
    let deviceName: String
    let authMethod: AuthMethod
    let authUsername: String?
    let linkedAt: Date
    var lastSeen: Date
    var isRevoked: Bool = false

    var statusText: String {
        if isRevoked {
            return "Revoked"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last seen \(formatter.localizedString(for: lastSeen, relativeTo: Date()))"
    }

    var isOnline: Bool {
        // Consider online if seen in last 5 minutes
        Date().timeIntervalSince(lastSeen) < 300
    }
}

// MARK: - Device Management View
struct DeviceManagementView: View {
    @ObservedObject private var deviceManager = ServerDeviceManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var showRevokeAllAlert = false
    @State private var deviceToRevoke: ServerLinkedDevice?
    @State private var isRevoking = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Linked Devices")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                if !deviceManager.linkedDevices.isEmpty {
                    Button("Revoke All") {
                        showRevokeAllAlert = true
                    }
                    .foregroundColor(.red)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()

            Divider()

            if deviceManager.linkedDevices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("No linked devices")
                        .foregroundColor(.gray)
                    Text("Devices that pair with your server will appear here")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(deviceManager.linkedDevices) { device in
                            ServerDeviceCard(device: device) {
                                deviceToRevoke = device
                            }
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(deviceManager.linkedDevices.count) device(s) linked")
                    .font(.caption)
                    .foregroundColor(.gray)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .alert("Revoke Device?", isPresented: .init(
            get: { deviceToRevoke != nil },
            set: { if !$0 { deviceToRevoke = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                deviceToRevoke = nil
            }
            Button("Revoke", role: .destructive) {
                if let device = deviceToRevoke {
                    revokeDevice(device)
                }
            }
        } message: {
            if let device = deviceToRevoke {
                Text("This will disconnect \(device.deviceName) and remove their access. They will need to re-pair to connect again.")
            }
        }
        .alert("Revoke All Devices?", isPresented: $showRevokeAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Revoke All", role: .destructive) {
                revokeAllDevices()
            }
        } message: {
            Text("This will disconnect all \(deviceManager.linkedDevices.count) device(s) and remove their access.")
        }
    }

    private func revokeDevice(_ device: ServerLinkedDevice) {
        isRevoking = true
        deviceManager.revokeDevice(device) { success in
            isRevoking = false
            deviceToRevoke = nil
        }
    }

    private func revokeAllDevices() {
        isRevoking = true
        deviceManager.revokeAllDevices { success in
            isRevoking = false
        }
    }
}

// MARK: - Server Device Card
struct ServerDeviceCard: View {
    let device: ServerLinkedDevice
    let onRevoke: () -> Void

    var body: some View {
        HStack {
            // Status indicator
            Circle()
                .fill(device.isOnline ? Color.green : Color.gray)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.deviceName)
                        .font(.headline)
                        .foregroundColor(.primary)

                    // Auth method badge
                    HStack(spacing: 2) {
                        Image(systemName: device.authMethod.icon)
                            .font(.caption2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(authMethodColor.opacity(0.2))
                    .foregroundColor(authMethodColor)
                    .cornerRadius(4)
                }

                if let username = device.authUsername {
                    Text(username)
                        .font(.caption)
                        .foregroundColor(.blue)
                }

                HStack(spacing: 8) {
                    Text(device.statusText)
                        .font(.caption2)
                        .foregroundColor(device.isOnline ? .green : .gray)

                    Text("Linked \(device.linkedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            Button(action: onRevoke) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Revoke access for this device")
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }

    var authMethodColor: Color {
        switch device.authMethod {
        case .pairingCode: return .gray
        case .mastodon: return .purple
        case .email: return .blue
        }
    }
}
