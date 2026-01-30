import Foundation
import Network
import SwiftUI

// MARK: - Connection Mode

enum ConnectionMode: String, CaseIterable, Codable {
    case auto = "Auto"
    case openLink = "OpenLink"
    case directIP = "Direct IP"
    case hybrid = "Hybrid"

    var description: String {
        switch self {
        case .auto: return "Automatically detect best method"
        case .openLink: return "Use secure OpenLink tunnel"
        case .directIP: return "Connect directly via IP"
        case .hybrid: return "OpenLink with IP fallback"
        }
    }
}

// MARK: - Server Type

enum ServerType: String, Codable {
    case primary = "primary"
    case fallback = "fallback"
    case community = "community"
    case custom = "custom"
}

// MARK: - Relay Server Model

struct RelayServer: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var url: String
    var type: ServerType
    var region: String
    var features: [String]
    var isOnline: Bool = false
    var latency: Int?
    var version: String?

    init(id: String = UUID().uuidString, name: String, url: String, type: ServerType = .custom, region: String = "Unknown", features: [String] = ["signaling"]) {
        self.id = id
        self.name = name
        self.url = url
        self.type = type
        self.region = region
        self.features = features
    }
}

// MARK: - Paired Server Model (VoiceLink servers)

struct PairedServer: Identifiable, Codable {
    let id: String
    var name: String
    var url: String
    var accessToken: String
    var pairedAt: Date
    var lastSeen: Date?
    var isOnline: Bool = false

    init(id: String = UUID().uuidString, name: String, url: String, accessToken: String = "", pairedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.url = url
        self.accessToken = accessToken
        self.pairedAt = pairedAt
    }
}

// MARK: - Session Info

struct SessionInfo: Codable {
    var sessionId: String
    var isHosting: Bool
    var connectedTo: String?
    var password: String?
    var createdAt: Date
    var expiresAt: Date?
}

// MARK: - Host Settings

struct HostSettings: Codable {
    var shareAudio: Bool = true
    var allowInput: Bool = true
    var allowClipboard: Bool = true
    var allowFiles: Bool = true
    var requirePassword: Bool = false
    var sessionPassword: String = ""
    var autoAcceptTrusted: Bool = true
    var allowRemoteConnections: AllowRemote = .ask

    enum AllowRemote: String, Codable, CaseIterable {
        case always = "Always"
        case never = "Never"
        case ask = "Ask"
    }
}

// MARK: - OpenLink Service

class OpenLinkService: ObservableObject {
    static let shared = OpenLinkService()

    // State
    @Published var isRunning = false
    @Published var connectionMode: ConnectionMode = .auto
    @Published var localIP: String?
    @Published var port: Int = 8765
    @Published var connectedDevices: Int = 0
    @Published var pairedServers: [PairedServer] = []

    // Relay Servers (OpenLink infrastructure)
    @Published var relayServers: [RelayServer] = []
    @Published var selectedRelayServer: RelayServer?
    @Published var isConnectedToRelay: Bool = false

    // Session Management
    @Published var currentSession: SessionInfo?
    @Published var isHosting: Bool = false
    @Published var sessionId: String = ""
    @Published var customSessionId: String = ""

    // Host Settings
    @Published var hostSettings = HostSettings()

    // Settings
    @Published var discoveryEnabled = true
    @Published var allowRemoteControl = true
    @Published var trustedDevicesOnly = false
    @Published var trustedMachines: [String: String] = [:] // id -> name

    // Network
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private var webSocketTasks: [String: URLSessionWebSocketTask] = [:]
    private var relayWebSocket: URLSessionWebSocketTask?
    private var discoveryTimer: Timer?
    private var heartbeatTimer: Timer?

    // Paths
    private let configPath = NSHomeDirectory() + "/.openlink/config.json"
    private let serversPath = NSHomeDirectory() + "/.openlink/servers.json"
    private let domainsPath = NSHomeDirectory() + "/.openlink/domains.json"

    // Default relay servers
    private let defaultRelayServers: [RelayServer] = [
        RelayServer(id: "local", name: "Local Server", url: "ws://localhost:8765", type: .primary, region: "Local", features: ["signaling"]),
        RelayServer(id: "raywonderis", name: "OpenLink", url: "wss://openlink.raywonderis.me", type: .primary, region: "US", features: ["signaling", "relay", "turn"]),
        RelayServer(id: "tappedin", name: "TappedIn", url: "wss://openlink.tappedin.fm", type: .fallback, region: "US", features: ["signaling", "relay", "turn"]),
        RelayServer(id: "devinenet", name: "Devine (.net)", url: "wss://openlink.devinecreations.net", type: .fallback, region: "US", features: ["signaling", "relay", "turn"]),
        RelayServer(id: "devinecom", name: "Devine Creations", url: "wss://openlink.devine-creations.com", type: .fallback, region: "US", features: ["signaling", "relay", "turn"]),
        RelayServer(id: "walterharper", name: "Walter Harper", url: "wss://openlink.walterharper.com", type: .fallback, region: "US", features: ["signaling", "relay", "turn"]),
        RelayServer(id: "tetoee", name: "Tetoee Howard", url: "wss://openlink.tetoeehoward.com", type: .fallback, region: "US", features: ["signaling", "relay", "turn"])
    ]

    init() {
        loadConfiguration()
        loadServers()
        initializeRelayServers()
    }

    // MARK: - Initialization

    private func initializeRelayServers() {
        relayServers = defaultRelayServers
        // Add any saved custom servers
        let savedCustom = UserDefaults.standard.data(forKey: "customRelayServers")
        if let data = savedCustom,
           let custom = try? JSONDecoder().decode([RelayServer].self, from: data) {
            relayServers.append(contentsOf: custom)
        }
    }

    // MARK: - Service Control

    func start() {
        guard !isRunning else { return }

        // Start local server for incoming connections
        startListener()

        // Start discovery if enabled
        if discoveryEnabled {
            startDiscovery()
        }

        // Connect to relay servers
        checkRelayServers()

        // Connect to paired VoiceLink servers
        for server in pairedServers {
            connectToServer(server)
        }

        isRunning = true
        detectLocalIP()

        // Start heartbeat
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }

        NotificationCenter.default.post(name: .openLinkServiceStarted, object: nil)
    }

    func stop() {
        guard isRunning else { return }

        // Stop listener
        listener?.cancel()
        listener = nil

        // Close all connections
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()

        // Close WebSocket connections
        for (_, task) in webSocketTasks {
            task.cancel(with: .normalClosure, reason: nil)
        }
        webSocketTasks.removeAll()

        // Disconnect from relay
        disconnectFromRelay()

        // Stop timers
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        isRunning = false
        connectedDevices = 0
        isConnectedToRelay = false

        NotificationCenter.default.post(name: .openLinkServiceStopped, object: nil)
    }

    // MARK: - Relay Server Management

    func checkRelayServers() {
        for (index, server) in relayServers.enumerated() {
            checkServerHealth(server) { [weak self] isOnline, latency, version in
                DispatchQueue.main.async {
                    self?.relayServers[index].isOnline = isOnline
                    self?.relayServers[index].latency = latency
                    self?.relayServers[index].version = version
                }
            }
        }
    }

    private func checkServerHealth(_ server: RelayServer, completion: @escaping (Bool, Int?, String?) -> Void) {
        // Convert ws:// to http:// for health check
        var healthUrl = server.url
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")

        // Try v1 health endpoint first, then v2
        let v1Url = healthUrl + "/health"
        let v2Url = healthUrl + "/api/v2/health"

        tryHealthCheck(url: v1Url, startTime: Date()) { success, latency, version in
            if success {
                completion(true, latency, version)
            } else {
                // Fallback to v2 API
                self.tryHealthCheck(url: v2Url, startTime: Date()) { success2, latency2, version2 in
                    completion(success2, latency2, version2)
                }
            }
        }
    }

    private func tryHealthCheck(url: String, startTime: Date, completion: @escaping (Bool, Int?, String?) -> Void) {
        guard let healthUrl = URL(string: url) else {
            completion(false, nil, nil)
            return
        }

        var request = URLRequest(url: healthUrl)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { data, response, error in
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data else {
                completion(false, nil, nil)
                return
            }

            // Parse health response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let version = json["version"] as? String
                completion(true, latency, version)
            } else {
                completion(true, latency, nil)
            }
        }.resume()
    }

    func connectToRelayServer(_ server: RelayServer) {
        disconnectFromRelay()

        guard let url = URL(string: server.url) else { return }

        var request = URLRequest(url: url)
        request.setValue("OpenLink-Swift/2.0", forHTTPHeaderField: "User-Agent")

        relayWebSocket = URLSession.shared.webSocketTask(with: request)
        relayWebSocket?.resume()

        selectedRelayServer = server
        isConnectedToRelay = true

        // Start receiving messages
        receiveRelayMessages()

        // Send handshake
        sendRelayMessage([
            "type": "handshake",
            "clientType": "swift-native",
            "clientVersion": "2.0.0",
            "platform": "macOS",
            "deviceId": getClientId(),
            "deviceName": Host.current().localizedName ?? "Unknown Mac"
        ])

        print("OpenLink: Connected to relay server \(server.name)")
    }

    func disconnectFromRelay() {
        relayWebSocket?.cancel(with: .normalClosure, reason: nil)
        relayWebSocket = nil
        isConnectedToRelay = false
        selectedRelayServer = nil
    }

    private func receiveRelayMessages() {
        relayWebSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self?.handleRelayMessage(data)
                    }
                case .data(let data):
                    self?.handleRelayMessage(data)
                @unknown default:
                    break
                }
                // Continue receiving
                self?.receiveRelayMessages()

            case .failure(let error):
                print("OpenLink: Relay connection error: \(error)")
                DispatchQueue.main.async {
                    self?.isConnectedToRelay = false
                }
            }
        }
    }

    private func handleRelayMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            switch type {
            case "welcome":
                if let clientId = json["clientId"] as? String {
                    print("OpenLink: Welcomed by relay with clientId: \(clientId)")
                }

            case "session-created":
                if let sessionId = json["sessionId"] as? String {
                    self?.sessionId = sessionId
                    self?.isHosting = true
                    self?.currentSession = SessionInfo(
                        sessionId: sessionId,
                        isHosting: true,
                        connectedTo: nil,
                        password: self?.hostSettings.sessionPassword,
                        createdAt: Date(),
                        expiresAt: nil
                    )
                    print("OpenLink: Session created: \(sessionId)")
                }

            case "client-joined":
                self?.connectedDevices += 1
                if let clientName = json["clientName"] as? String {
                    print("OpenLink: Client joined: \(clientName)")
                }

            case "client-left":
                self?.connectedDevices = max(0, (self?.connectedDevices ?? 1) - 1)

            case "settings-sync":
                // Receive settings from server
                if let settings = json["settings"] as? [String: Any] {
                    self?.applySettingsFromServer(settings)
                }

            case "remote-command":
                if let command = json["command"] as? String {
                    self?.handleRemoteCommand(command, parameters: json)
                }

            case "error":
                if let errorMsg = json["message"] as? String {
                    print("OpenLink: Relay error: \(errorMsg)")
                }

            default:
                print("OpenLink: Unknown message type: \(type)")
            }
        }
    }

    private func sendRelayMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let string = String(data: data, encoding: .utf8) else {
            return
        }

        relayWebSocket?.send(.string(string)) { error in
            if let error = error {
                print("OpenLink: Failed to send relay message: \(error)")
            }
        }
    }

    private func sendHeartbeat() {
        if isConnectedToRelay {
            sendRelayMessage([
                "type": "heartbeat",
                "timestamp": Date().timeIntervalSince1970
            ])
        }
    }

    // MARK: - Session Management

    func startHosting(withSessionId: String? = nil) {
        let sid = withSessionId ?? generateSessionId()

        sendRelayMessage([
            "type": "host-session",
            "sessionId": sid,
            "password": hostSettings.requirePassword ? hostSettings.sessionPassword : nil,
            "settings": [
                "shareAudio": hostSettings.shareAudio,
                "allowInput": hostSettings.allowInput,
                "allowClipboard": hostSettings.allowClipboard,
                "allowFiles": hostSettings.allowFiles
            ]
        ])
    }

    func stopHosting() {
        sendRelayMessage([
            "type": "stop-hosting",
            "sessionId": sessionId
        ])

        isHosting = false
        currentSession = nil
        sessionId = ""
        connectedDevices = 0
    }

    func connectToSession(_ targetSessionId: String, password: String? = nil) {
        sendRelayMessage([
            "type": "join-session",
            "sessionId": targetSessionId,
            "password": password,
            "clientId": getClientId(),
            "clientName": Host.current().localizedName ?? "Unknown"
        ])
    }

    private func generateSessionId() -> String {
        if !customSessionId.isEmpty {
            return customSessionId
        }

        // Generate 6-character alphanumeric session ID
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).map { _ in chars.randomElement()! })
    }

    // MARK: - Settings Sync

    func syncSettingsToServer(_ server: PairedServer) {
        let settings: [String: Any] = [
            "connectionMode": connectionMode.rawValue,
            "discoveryEnabled": discoveryEnabled,
            "allowRemoteControl": allowRemoteControl,
            "trustedDevicesOnly": trustedDevicesOnly,
            "hostSettings": [
                "shareAudio": hostSettings.shareAudio,
                "allowInput": hostSettings.allowInput,
                "allowClipboard": hostSettings.allowClipboard,
                "allowFiles": hostSettings.allowFiles,
                "requirePassword": hostSettings.requirePassword,
                "autoAcceptTrusted": hostSettings.autoAcceptTrusted,
                "allowRemoteConnections": hostSettings.allowRemoteConnections.rawValue
            ]
        ]

        // Send via WebSocket if connected
        if let task = webSocketTasks[server.id] {
            if let data = try? JSONSerialization.data(withJSONObject: [
                "type": "settings-update",
                "settings": settings
            ]),
               let string = String(data: data, encoding: .utf8) {
                task.send(.string(string)) { _ in }
            }
        }
    }

    private func applySettingsFromServer(_ settings: [String: Any]) {
        if let mode = settings["connectionMode"] as? String,
           let connMode = ConnectionMode(rawValue: mode) {
            connectionMode = connMode
        }

        if let discovery = settings["discoveryEnabled"] as? Bool {
            discoveryEnabled = discovery
        }

        if let remote = settings["allowRemoteControl"] as? Bool {
            allowRemoteControl = remote
        }

        if let trusted = settings["trustedDevicesOnly"] as? Bool {
            trustedDevicesOnly = trusted
        }

        if let host = settings["hostSettings"] as? [String: Any] {
            if let shareAudio = host["shareAudio"] as? Bool {
                hostSettings.shareAudio = shareAudio
            }
            if let allowInput = host["allowInput"] as? Bool {
                hostSettings.allowInput = allowInput
            }
            if let allowClipboard = host["allowClipboard"] as? Bool {
                hostSettings.allowClipboard = allowClipboard
            }
            if let allowFiles = host["allowFiles"] as? Bool {
                hostSettings.allowFiles = allowFiles
            }
        }

        saveConfiguration()
    }

    // MARK: - Remote Commands

    private func handleRemoteCommand(_ command: String, parameters: [String: Any]) {
        guard allowRemoteControl else {
            print("OpenLink: Remote control disabled, ignoring command: \(command)")
            return
        }

        switch command {
        case "get_status":
            sendRelayMessage([
                "type": "command-response",
                "command": command,
                "result": [
                    "isRunning": isRunning,
                    "isHosting": isHosting,
                    "sessionId": sessionId,
                    "connectedDevices": connectedDevices,
                    "mode": connectionMode.rawValue
                ]
            ])

        case "start_hosting":
            startHosting()

        case "stop_hosting":
            stopHosting()

        case "update_settings":
            if let settings = parameters["settings"] as? [String: Any] {
                applySettingsFromServer(settings)
            }

        default:
            print("OpenLink: Unknown remote command: \(command)")
        }
    }

    // MARK: - Network Listener

    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("OpenLink listener ready on port \(self?.port ?? 0)")
                case .failed(let error):
                    print("OpenLink listener failed: \(error)")
                    self?.isRunning = false
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener?.start(queue: .main)

        } catch {
            print("Failed to start OpenLink listener: \(error)")
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = UUID().uuidString

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.connectedDevices += 1
                self?.connections[connectionId] = connection
                self?.receiveData(from: connection, id: connectionId)
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: connectionId)
                self?.connectedDevices = max(0, (self?.connectedDevices ?? 1) - 1)
            default:
                break
            }
        }

        connection.start(queue: .main)
    }

    private func receiveData(from connection: NWConnection, id: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handleIncomingData(data, from: id)
            }

            if !isComplete && error == nil {
                self?.receiveData(from: connection, id: id)
            }
        }
    }

    private func handleIncomingData(_ data: Data, from connectionId: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "ping":
            sendResponse(["type": "pong", "timestamp": Date().timeIntervalSince1970], to: connectionId)
        case "connect":
            handleConnectRequest(json, from: connectionId)
        case "disconnect":
            handleDisconnect(connectionId)
        default:
            break
        }
    }

    private func sendResponse(_ response: [String: Any], to connectionId: String) {
        guard let connection = connections[connectionId],
              let data = try? JSONSerialization.data(withJSONObject: response) else {
            return
        }

        connection.send(content: data, completion: .idempotent)
    }

    private func handleConnectRequest(_ json: [String: Any], from connectionId: String) {
        if let deviceId = json["deviceId"] as? String,
           let deviceName = json["deviceName"] as? String {
            print("Device connected: \(deviceName) (\(deviceId))")
            sendResponse(["success": true, "connected": true], to: connectionId)
        }
    }

    private func handleDisconnect(_ connectionId: String) {
        connections[connectionId]?.cancel()
        connections.removeValue(forKey: connectionId)
        connectedDevices = max(0, connectedDevices - 1)
    }

    // MARK: - VoiceLink Server Connection

    func connectToServer(_ server: PairedServer) {
        switch connectionMode {
        case .auto:
            autoConnectToServer(server)
        case .openLink:
            connectViaOpenLink(server)
        case .directIP:
            connectViaDirectIP(server)
        case .hybrid:
            connectViaOpenLink(server)
        }
    }

    private func autoConnectToServer(_ server: PairedServer) {
        if isLocalServer(server) {
            connectViaDirectIP(server)
        } else {
            connectViaOpenLink(server)
        }
    }

    private func isLocalServer(_ server: PairedServer) -> Bool {
        guard let url = URL(string: server.url),
              let host = url.host else {
            return false
        }

        return host.hasPrefix("192.168.") ||
               host.hasPrefix("10.") ||
               host.hasPrefix("172.16.") ||
               host == "localhost" ||
               host == "127.0.0.1"
    }

    private func connectViaOpenLink(_ server: PairedServer) {
        let wsURL = server.url
            .replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")

        guard let url = URL(string: "\(wsURL)/openlink/connect") else {
            return
        }

        var request = URLRequest(url: url)
        request.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: request)
        webSocketTasks[server.id] = task

        task.resume()

        receiveWebSocketMessages(serverId: server.id)

        let handshake: [String: Any] = [
            "type": "handshake",
            "clientId": getClientId(),
            "clientName": Host.current().localizedName ?? "Unknown"
        ]

        if let data = try? JSONSerialization.data(withJSONObject: handshake),
           let string = String(data: data, encoding: .utf8) {
            task.send(.string(string)) { _ in }
        }

        updateServerOnlineStatus(serverId: server.id, isOnline: true)
    }

    private func connectViaDirectIP(_ server: PairedServer) {
        guard let url = URL(string: server.url),
              let host = url.host else {
            return
        }

        let port = url.port ?? 3000

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: .tcp
        )

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.updateServerOnlineStatus(serverId: server.id, isOnline: true)
            case .failed, .cancelled:
                self?.updateServerOnlineStatus(serverId: server.id, isOnline: false)
                if self?.connectionMode == .hybrid {
                    self?.connectViaOpenLink(server)
                }
            default:
                break
            }
        }

        connections[server.id] = connection
        connection.start(queue: .main)
    }

    private func receiveWebSocketMessages(serverId: String) {
        guard let task = webSocketTasks[serverId] else { return }

        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self?.handleWebSocketMessage(data, serverId: serverId)
                    }
                case .data(let data):
                    self?.handleWebSocketMessage(data, serverId: serverId)
                @unknown default:
                    break
                }
                self?.receiveWebSocketMessages(serverId: serverId)

            case .failure:
                self?.updateServerOnlineStatus(serverId: serverId, isOnline: false)
                self?.webSocketTasks.removeValue(forKey: serverId)
            }
        }
    }

    private func handleWebSocketMessage(_ data: Data, serverId: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "settings-sync":
            if let settings = json["settings"] as? [String: Any] {
                applySettingsFromServer(settings)
            }
        case "ping":
            sendWebSocketResponse(["type": "pong"], serverId: serverId)
        default:
            break
        }
    }

    private func sendWebSocketResponse(_ response: [String: Any], serverId: String) {
        guard let task = webSocketTasks[serverId],
              let data = try? JSONSerialization.data(withJSONObject: response),
              let string = String(data: data, encoding: .utf8) else {
            return
        }

        task.send(.string(string)) { _ in }
    }

    func testConnection(_ server: PairedServer) {
        guard let url = URL(string: "\(server.url)/api/health") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
            let isOnline = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                self?.updateServerOnlineStatus(serverId: server.id, isOnline: isOnline)
            }
        }.resume()
    }

    // MARK: - Server Management

    func pairWithCode(_ code: String) {
        guard code.count == 6 else { return }

        let newServer = PairedServer(
            name: "VoiceLink Server",
            url: "http://localhost:3000",
            accessToken: UUID().uuidString
        )

        addServer(newServer)
    }

    func addServerManually(url: String) {
        let newServer = PairedServer(
            name: "Manual Server",
            url: url,
            accessToken: UUID().uuidString
        )

        addServer(newServer)
    }

    private func addServer(_ server: PairedServer) {
        pairedServers.append(server)
        saveServers()

        if isRunning {
            connectToServer(server)
        }
    }

    func removeServer(_ server: PairedServer) {
        webSocketTasks[server.id]?.cancel(with: .normalClosure, reason: nil)
        webSocketTasks.removeValue(forKey: server.id)
        connections[server.id]?.cancel()
        connections.removeValue(forKey: server.id)

        pairedServers.removeAll { $0.id == server.id }
        saveServers()
    }

    private func updateServerOnlineStatus(serverId: String, isOnline: Bool) {
        if let index = pairedServers.firstIndex(where: { $0.id == serverId }) {
            pairedServers[index].isOnline = isOnline
            pairedServers[index].lastSeen = isOnline ? Date() : pairedServers[index].lastSeen
        }
    }

    // MARK: - Custom Relay Server

    func addCustomRelayServer(name: String, url: String) {
        let server = RelayServer(name: name, url: url, type: .custom)
        relayServers.append(server)

        // Save custom servers
        let customServers = relayServers.filter { $0.type == .custom }
        if let data = try? JSONEncoder().encode(customServers) {
            UserDefaults.standard.set(data, forKey: "customRelayServers")
        }
    }

    func removeRelayServer(_ server: RelayServer) {
        guard server.type == .custom else { return } // Can only remove custom servers
        relayServers.removeAll { $0.id == server.id }

        let customServers = relayServers.filter { $0.type == .custom }
        if let data = try? JSONEncoder().encode(customServers) {
            UserDefaults.standard.set(data, forKey: "customRelayServers")
        }
    }

    // MARK: - Discovery

    private func startDiscovery() {
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.discoverLocalDevices()
        }
        discoverLocalDevices()
    }

    private func discoverLocalDevices() {
        for server in pairedServers {
            testConnection(server)
        }
        checkRelayServers()
    }

    private func detectLocalIP() {
        var address: String?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
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

        DispatchQueue.main.async {
            self.localIP = address
        }
    }

    // MARK: - Persistence

    private func loadConfiguration() {
        // Create directory if needed
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(OpenLinkConfig.self, from: data) else {
            return
        }

        connectionMode = ConnectionMode(rawValue: config.connectionMode) ?? .auto
        port = config.serverPort
        discoveryEnabled = config.discoveryEnabled
        allowRemoteControl = config.allowRemoteControl
        trustedDevicesOnly = config.trustedDevicesOnly
        customSessionId = config.customSessionId
        hostSettings = config.hostSettings
    }

    private func saveConfiguration() {
        let config = OpenLinkConfig(
            connectionMode: connectionMode.rawValue,
            serverPort: port,
            discoveryEnabled: discoveryEnabled,
            allowRemoteControl: allowRemoteControl,
            trustedDevicesOnly: trustedDevicesOnly,
            customSessionId: customSessionId,
            hostSettings: hostSettings
        )

        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    private func loadServers() {
        guard let data = FileManager.default.contents(atPath: serversPath),
              let servers = try? JSONDecoder().decode([PairedServer].self, from: data) else {
            return
        }

        pairedServers = servers
    }

    private func saveServers() {
        let dir = (serversPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard let data = try? JSONEncoder().encode(pairedServers) else { return }
        try? data.write(to: URL(fileURLWithPath: serversPath))
    }

    private func getClientId() -> String {
        if let id = UserDefaults.standard.string(forKey: "openLinkClientId") {
            return id
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: "openLinkClientId")
        return newId
    }
}

// MARK: - Config Model

struct OpenLinkConfig: Codable {
    var connectionMode: String = "Auto"
    var serverPort: Int = 8765
    var discoveryEnabled: Bool = true
    var allowRemoteControl: Bool = true
    var trustedDevicesOnly: Bool = false
    var customSessionId: String = ""
    var hostSettings: HostSettings = HostSettings()
}

// MARK: - URL Shortener Models

struct ShortLink: Identifiable, Codable {
    let id: String
    var shortCode: String
    var originalUrl: String
    var domain: ShortDomain
    var clicks: Int = 0
    var createdAt: Date
    var expiresAt: Date?
    var password: String?
    var isEnabled: Bool = true

    var shortUrl: String {
        return "https://\(domain.rawValue)/\(shortCode)"
    }
}

enum ShortDomain: String, Codable, CaseIterable {
    case raywonderis = "raywonderis.me"
    case devinecreations = "devinecreations.net"
    case tappedin = "tappedin.fm"
    case walterharper = "walterharper.com"
    case devineCreationsCom = "devine-creations.com"

    var displayName: String {
        switch self {
        case .raywonderis: return "RayWonderIs"
        case .devinecreations: return "Devine Creations (.net)"
        case .tappedin: return "TappedIn"
        case .walterharper: return "Walter Harper"
        case .devineCreationsCom: return "Devine Creations (.com)"
        }
    }
}

struct ShortLinkResponse: Codable {
    let id: String
    let shortCode: String
    let shortUrl: String?
    let originalUrl: String?
}

struct ShortLinkStats: Codable {
    let shortCode: String
    let clicks: Int
    let uniqueVisitors: Int?
    let lastClickAt: Date?
    let createdAt: Date?
    let referrers: [String: Int]?
    let countries: [String: Int]?
    let browsers: [String: Int]?
}

// MARK: - URL Shortener Extension

extension OpenLinkService {
    func createShortLink(
        originalUrl: String,
        customCode: String? = nil,
        domain: ShortDomain = .raywonderis,
        password: String? = nil,
        expiresIn: TimeInterval? = nil,
        completion: @escaping (Result<ShortLink, Error>) -> Void
    ) {
        let apiUrl = "https://openlink.\(domain.rawValue)/api/links"

        guard let url = URL(string: apiUrl) else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var body: [String: Any] = ["url": originalUrl, "domain": domain.rawValue]
        if let code = customCode, !code.isEmpty { body["customCode"] = code }
        if let pass = password { body["password"] = pass }
        if let expires = expiresIn { body["expiresAt"] = Date().addingTimeInterval(expires).timeIntervalSince1970 }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
                // Try v2 API
                self?.createShortLinkV2(originalUrl: originalUrl, customCode: customCode, domain: domain, password: password, expiresIn: expiresIn, completion: completion)
                return
            }

            guard let data = data else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }

            do {
                let result = try JSONDecoder().decode(ShortLinkResponse.self, from: data)
                let link = ShortLink(id: result.id, shortCode: result.shortCode, originalUrl: originalUrl, domain: domain, clicks: 0, createdAt: Date(), expiresAt: expiresIn.map { Date().addingTimeInterval($0) }, password: password)
                DispatchQueue.main.async { completion(.success(link)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    private func createShortLinkV2(originalUrl: String, customCode: String?, domain: ShortDomain, password: String?, expiresIn: TimeInterval?, completion: @escaping (Result<ShortLink, Error>) -> Void) {
        let apiUrl = "https://openlink.\(domain.rawValue)/api/v2/links"
        guard let url = URL(string: apiUrl) else { completion(.failure(URLError(.badURL))); return }

        var body: [String: Any] = ["url": originalUrl, "domain": domain.rawValue]
        if let code = customCode, !code.isEmpty { body["customCode"] = code }
        if let pass = password { body["password"] = pass }
        if let expires = expiresIn { body["expiresAt"] = Date().addingTimeInterval(expires).timeIntervalSince1970 }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard let data = data else { DispatchQueue.main.async { completion(.failure(URLError(.badServerResponse))) }; return }

            do {
                let result = try JSONDecoder().decode(ShortLinkResponse.self, from: data)
                let link = ShortLink(id: result.id, shortCode: result.shortCode, originalUrl: originalUrl, domain: domain, clicks: 0, createdAt: Date(), expiresAt: expiresIn.map { Date().addingTimeInterval($0) }, password: password)
                DispatchQueue.main.async { completion(.success(link)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    func getShortLinkStats(shortCode: String, domain: ShortDomain = .raywonderis, completion: @escaping (Result<ShortLinkStats, Error>) -> Void) {
        let apiUrl = "https://openlink.\(domain.rawValue)/api/links/\(shortCode)/stats"
        guard let url = URL(string: apiUrl) else { completion(.failure(URLError(.badURL))); return }

        var request = URLRequest(url: url)
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
                self?.getShortLinkStatsV2(shortCode: shortCode, domain: domain, completion: completion)
                return
            }
            guard let data = data else { completion(.failure(URLError(.badServerResponse))); return }
            do {
                let stats = try JSONDecoder().decode(ShortLinkStats.self, from: data)
                DispatchQueue.main.async { completion(.success(stats)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }.resume()
    }

    private func getShortLinkStatsV2(shortCode: String, domain: ShortDomain, completion: @escaping (Result<ShortLinkStats, Error>) -> Void) {
        let apiUrl = "https://openlink.\(domain.rawValue)/api/v2/links/\(shortCode)/stats"
        guard let url = URL(string: apiUrl) else { completion(.failure(URLError(.badURL))); return }

        var request = URLRequest(url: url)
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard let data = data else { DispatchQueue.main.async { completion(.failure(URLError(.badServerResponse))) }; return }
            do {
                let stats = try JSONDecoder().decode(ShortLinkStats.self, from: data)
                DispatchQueue.main.async { completion(.success(stats)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }.resume()
    }

    func deleteShortLink(shortCode: String, domain: ShortDomain = .raywonderis, completion: @escaping (Bool) -> Void) {
        let apiUrl = "https://openlink.\(domain.rawValue)/api/links/\(shortCode)"
        guard let url = URL(string: apiUrl) else { completion(false); return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let success = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(success) }
        }.resume()
    }

    func getShareableSessionUrl() -> String? {
        guard !sessionId.isEmpty, let server = selectedRelayServer else { return nil }
        let domain = server.url.replacingOccurrences(of: "wss://", with: "").replacingOccurrences(of: "ws://", with: "")
        return "openlink://\(domain)/\(sessionId)"
    }

    func parseOpenLinkUrl(_ urlString: String) -> (server: String, sessionId: String)? {
        guard urlString.hasPrefix("openlink://") else { return nil }
        let cleanUrl = urlString.replacingOccurrences(of: "openlink://", with: "https://")
        guard let url = URL(string: cleanUrl), let host = url.host else { return nil }
        let sessionId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !sessionId.isEmpty else { return nil }
        return (server: host, sessionId: sessionId)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openLinkServiceStarted = Notification.Name("openLinkServiceStarted")
    static let openLinkServiceStopped = Notification.Name("openLinkServiceStopped")
    static let openLinkDeviceConnected = Notification.Name("openLinkDeviceConnected")
    static let openLinkDeviceDisconnected = Notification.Name("openLinkDeviceDisconnected")
    static let openLinkSessionCreated = Notification.Name("openLinkSessionCreated")
    static let openLinkSessionEnded = Notification.Name("openLinkSessionEnded")
    static let openLinkShortLinkCreated = Notification.Name("openLinkShortLinkCreated")
}
