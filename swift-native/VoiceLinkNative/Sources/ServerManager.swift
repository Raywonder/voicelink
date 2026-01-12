import Foundation
import SocketIO

class ServerManager: ObservableObject {
    static let shared = ServerManager()

    private var manager: SocketManager?
    private var socket: SocketIOClient?

    @Published var isConnected = false
    @Published var serverStatus: String = "Disconnected"
    @Published var rooms: [ServerRoom] = []
    @Published var currentRoomUsers: [RoomUser] = []
    @Published var errorMessage: String?
    @Published var connectedServer: String = ""

    // Server options
    static let mainServer = "https://voicelink.devinecreations.net"
    static let localServer = "http://localhost:4004"

    private var currentServerURL: String = ""
    private var useMainServer: Bool = true

    init() {
        // Default to main server
        self.currentServerURL = ServerManager.mainServer
    }

    func connect(toMain: Bool = true) {
        // Disconnect existing connection
        socket?.disconnect()

        // Choose server
        currentServerURL = toMain ? ServerManager.mainServer : ServerManager.localServer
        useMainServer = toMain

        guard let url = URL(string: currentServerURL) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid server URL"
            }
            return
        }

        print("Connecting to server: \(currentServerURL)")

        manager = SocketManager(socketURL: url, config: [
            .log(true),
            .compress,
            .forceWebsockets(true),
            .reconnects(true),
            .reconnectWait(3),
            .reconnectAttempts(5),
            .secure(currentServerURL.hasPrefix("https"))
        ])

        socket = manager?.defaultSocket

        setupEventHandlers()
        socket?.connect()
    }

    func connectToMainServer() {
        connect(toMain: true)
    }

    func connectToLocalServer() {
        connect(toMain: false)
    }

    func tryLocalThenMain() {
        // Try local first, if fails connect to main
        print("Trying local server first...")
        connect(toMain: false)

        // Set up a timeout to switch to main server if local fails
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            if !self.isConnected && !self.useMainServer {
                print("Local server not available, connecting to main server...")
                self.connect(toMain: true)
            }
        }
    }

    func disconnect() {
        socket?.disconnect()
        DispatchQueue.main.async {
            self.isConnected = false
            self.serverStatus = "Disconnected"
        }
    }

    private func setupEventHandlers() {
        guard let socket = socket else { return }

        socket.on(clientEvent: .connect) { [weak self] data, ack in
            guard let self = self else { return }
            print("Connected to server: \(self.currentServerURL)")
            DispatchQueue.main.async {
                self.isConnected = true
                self.serverStatus = "Connected"
                self.connectedServer = self.useMainServer ? "Main Server" : "Local Server"
                self.errorMessage = nil
            }
            // Request room list after connecting
            self.getRooms()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, ack in
            print("Disconnected from server")
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.serverStatus = "Disconnected"
            }
        }

        socket.on(clientEvent: .error) { [weak self] data, ack in
            print("Socket error: \(data)")
            DispatchQueue.main.async {
                self?.errorMessage = "Connection error"
                self?.serverStatus = "Error"
            }
        }

        socket.on(clientEvent: .reconnect) { [weak self] data, ack in
            print("Reconnecting...")
            DispatchQueue.main.async {
                self?.serverStatus = "Reconnecting..."
            }
        }

        // Room list response
        socket.on("room-list") { [weak self] data, ack in
            print("Received room list: \(data)")
            if let roomsData = data[0] as? [[String: Any]] {
                let rooms = roomsData.compactMap { ServerRoom(from: $0) }
                DispatchQueue.main.async {
                    self?.rooms = rooms
                }
            }
        }

        // Room created response
        socket.on("room-created") { [weak self] data, ack in
            print("Room created: \(data)")
            self?.getRooms()
        }

        // Room joined response
        socket.on("room-joined") { [weak self] data, ack in
            print("Joined room: \(data)")
            if let roomData = data[0] as? [String: Any] {
                // Handle room join success
                NotificationCenter.default.post(name: .roomJoined, object: roomData)
            }
        }

        // User joined room
        socket.on("user-joined") { [weak self] data, ack in
            print("User joined: \(data)")
            if let userData = data[0] as? [String: Any],
               let user = RoomUser(from: userData) {
                DispatchQueue.main.async {
                    if !self!.currentRoomUsers.contains(where: { $0.id == user.id }) {
                        self?.currentRoomUsers.append(user)
                    }
                }
            }
        }

        // User left room
        socket.on("user-left") { [weak self] data, ack in
            print("User left: \(data)")
            if let userData = data[0] as? [String: Any],
               let odId = userData["odId"] as? String {
                DispatchQueue.main.async {
                    self?.currentRoomUsers.removeAll { $0.odId == odId }
                }
            }
        }

        // Room users list
        socket.on("room-users") { [weak self] data, ack in
            print("Room users: \(data)")
            if let usersData = data[0] as? [[String: Any]] {
                let users = usersData.compactMap { RoomUser(from: $0) }
                DispatchQueue.main.async {
                    self?.currentRoomUsers = users
                }
            }
        }

        // Error response
        socket.on("error") { [weak self] data, ack in
            print("Server error: \(data)")
            if let message = data[0] as? String {
                DispatchQueue.main.async {
                    self?.errorMessage = message
                }
            }
        }

        // Server push events for sync
        socket.on("sync-push") { data, ack in
            if let pushData = data[0] as? [String: Any] {
                SyncManager.shared.handleServerPush(pushData)
            }
        }

        // Membership update push
        socket.on("membership-update") { data, ack in
            if let updateData = data[0] as? [String: Any] {
                var pushData = updateData
                pushData["type"] = "membership_update"
                SyncManager.shared.handleServerPush(pushData)
            }
        }

        // Trust score update push
        socket.on("trust-update") { data, ack in
            if let updateData = data[0] as? [String: Any] {
                var pushData = updateData
                pushData["type"] = "trust_update"
                SyncManager.shared.handleServerPush(pushData)
            }
        }

        // Wallet balance update
        socket.on("wallet-update") { data, ack in
            if let updateData = data[0] as? [String: Any] {
                var pushData = updateData
                pushData["type"] = "wallet_update"
                SyncManager.shared.handleServerPush(pushData)
            }
        }

        // Complaint received
        socket.on("complaint-received") { data, ack in
            if let complaintData = data[0] as? [String: Any] {
                var pushData = complaintData
                pushData["type"] = "complaint"
                SyncManager.shared.handleServerPush(pushData)
            }
        }

        // Level upgrade notification
        socket.on("level-upgrade") { data, ack in
            if let upgradeData = data[0] as? [String: Any] {
                var pushData = upgradeData
                pushData["type"] = "level_upgrade"
                SyncManager.shared.handleServerPush(pushData)
            }
        }
    }

    // MARK: - API Methods

    func getRooms() {
        socket?.emit("get-rooms")
    }

    func createRoom(name: String, description: String, isPrivate: Bool, password: String? = nil) {
        var roomData: [String: Any] = [
            "name": name,
            "description": description,
            "isPrivate": isPrivate
        ]
        if let password = password {
            roomData["password"] = password
        }
        socket?.emit("create-room", roomData)
    }

    func joinRoom(roomId: String, username: String, password: String? = nil) {
        var joinData: [String: Any] = [
            "roomId": roomId,
            "username": username
        ]
        if let password = password {
            joinData["password"] = password
        }
        socket?.emit("join-room", joinData)
    }

    func leaveRoom() {
        socket?.emit("leave-room")
        DispatchQueue.main.async {
            self.currentRoomUsers = []
        }
    }

    func sendAudioState(isMuted: Bool, isDeafened: Bool) {
        socket?.emit("audio-state", [
            "muted": isMuted,
            "deafened": isDeafened
        ])
    }

    // MARK: - Access Revocation

    func sendRevocation(clientId: String, completion: @escaping (Bool) -> Void) {
        socket?.emit("revoke-access", ["clientId": clientId])

        // For now, assume success - in production this would wait for server acknowledgment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completion(true)
        }
    }

    func setupRevocationListener() {
        // Listen for access revocation events (as a client)
        socket?.on("access-revoked") { [weak self] data, ack in
            guard let dict = data[0] as? [String: Any] else { return }

            let revokedClientId = dict["clientId"] as? String
            let revokedBy = dict["revokedBy"] as? String ?? "server"

            DispatchQueue.main.async {
                // Check if this revocation is for us
                let ourClientId = UserDefaults.standard.string(forKey: "clientId")
                if revokedClientId == ourClientId || revokedClientId == nil {
                    // Our access has been revoked
                    self?.handleAccessRevoked(revokedBy: revokedBy)
                }
            }
        }
    }

    private func handleAccessRevoked(revokedBy: String) {
        // Disconnect from server
        disconnect()

        // Post notification for UI to handle
        NotificationCenter.default.post(
            name: .accessRevoked,
            object: nil,
            userInfo: ["revokedBy": revokedBy]
        )
    }
}

// MARK: - Revocation Notification
extension Notification.Name {
    static let accessRevoked = Notification.Name("accessRevoked")
}

// MARK: - Models

struct ServerRoom: Identifiable {
    let id: String
    let name: String
    let description: String
    let userCount: Int
    let isPrivate: Bool
    let maxUsers: Int

    init?(from dict: [String: Any]) {
        guard let id = dict["id"] as? String ?? dict["roomId"] as? String,
              let name = dict["name"] as? String else {
            return nil
        }
        self.id = id
        self.name = name
        self.description = dict["description"] as? String ?? ""
        self.userCount = dict["userCount"] as? Int ?? dict["users"] as? Int ?? 0
        self.isPrivate = dict["isPrivate"] as? Bool ?? dict["private"] as? Bool ?? false
        self.maxUsers = dict["maxUsers"] as? Int ?? 50
    }
}

struct RoomUser: Identifiable {
    let id: String
    let odId: String
    let username: String
    let isMuted: Bool
    let isDeafened: Bool
    let isSpeaking: Bool

    init?(from dict: [String: Any]) {
        guard let odId = dict["odId"] as? String ?? dict["id"] as? String,
              let username = dict["username"] as? String ?? dict["name"] as? String else {
            return nil
        }
        self.id = odId
        self.odId = odId
        self.username = username
        self.isMuted = dict["muted"] as? Bool ?? dict["isMuted"] as? Bool ?? false
        self.isDeafened = dict["deafened"] as? Bool ?? dict["isDeafened"] as? Bool ?? false
        self.isSpeaking = dict["speaking"] as? Bool ?? dict["isSpeaking"] as? Bool ?? false
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let roomLeft = Notification.Name("roomLeft")
}
