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
    static let communityServer = "https://vps1.tappedin.fm"
    static let localServer = "http://localhost:4004"

    private enum ConnectionMode {
        case main
        case community
        case local
        case custom
    }

    private var currentServerURL: String = ""
    private var connectionMode: ConnectionMode = .main

    // Public accessor for the current server URL
    var baseURL: String? {
        currentServerURL.isEmpty ? nil : currentServerURL
    }

    init() {
        // Default to main server
        self.currentServerURL = ServerManager.mainServer
        setupMessageNotifications()
    }

    private func setupMessageNotifications() {
        // Listen for outgoing messages from MessagingManager
        NotificationCenter.default.addObserver(
            forName: .sendMessageToServer,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let data = notification.userInfo else { return }
            let content = data["content"] as? String ?? ""
            let isDirect = data["isDirect"] as? Bool ?? false
            let recipientId = data["recipientId"] as? String
            let replyToId = data["replyToId"] as? String

            if isDirect, let recipient = recipientId {
                // Direct message
                var msgData: [String: Any] = [
                    "targetUserId": recipient,
                    "message": content
                ]
                if let reply = replyToId {
                    msgData["replyTo"] = reply
                }
                self?.socket?.emit("direct-message", msgData)
            } else {
                // Room message
                var msgData: [String: Any] = ["message": content]
                if let reply = replyToId {
                    msgData["replyTo"] = reply
                }
                self?.socket?.emit("chat-message", msgData)
            }
        }

        // Typing indicator
        NotificationCenter.default.addObserver(
            forName: .sendTypingIndicator,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let data = notification.userInfo,
                  let typing = data["typing"] as? Bool else { return }
            self?.socket?.emit("typing", ["typing": typing])
        }

        // Message reactions
        NotificationCenter.default.addObserver(
            forName: .sendReactionToServer,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let data = notification.userInfo,
                  let messageId = data["messageId"] as? String,
                  let emoji = data["emoji"] as? String else { return }
            self?.socket?.emit("message-reaction", [
                "messageId": messageId,
                "reaction": emoji
            ])
        }
    }

    func connect(toMain: Bool = true) {
        // Disconnect existing connection
        socket?.disconnect()

        // Choose server
        currentServerURL = toMain ? ServerManager.mainServer : ServerManager.localServer
        connectionMode = toMain ? .main : .local

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

    func connectToCommunityServer() {
        // Disconnect existing connection
        socket?.disconnect()

        currentServerURL = ServerManager.communityServer
        connectionMode = .community

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

    func tryLocalThenMain() {
        // Try main/remote server first (primary), fallback to local
        print("Connecting to main server (primary)...")
        connect(toMain: true)

        // Set up a timeout to try local server if main fails
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if !self.isConnected && self.connectionMode == .main {
                print("Main server not available, trying local server...")
                self.connect(toMain: false)
            }
        }
    }

    func tryMainThenLocal() {
        // Alias for tryLocalThenMain - main is now primary
        tryLocalThenMain()
    }

    func disconnect() {
        socket?.disconnect()
        DispatchQueue.main.async {
            self.isConnected = false
            self.serverStatus = "Disconnected"
            self.connectedServer = ""
            NotificationCenter.default.post(name: .serverConnectionChanged, object: nil)
        }
    }

    /// Connect to a custom server URL
    func connectToURL(_ urlString: String) {
        // Disconnect existing connection
        socket?.disconnect()

        // Normalize URL
        var serverURL = urlString
        if !serverURL.hasPrefix("http://") && !serverURL.hasPrefix("https://") {
            serverURL = "https://" + serverURL
        }

        currentServerURL = serverURL
        connectionMode = .custom

        guard let url = URL(string: serverURL) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid server URL"
            }
            return
        }

        print("Connecting to custom server: \(serverURL)")

        manager = SocketManager(socketURL: url, config: [
            .log(false),
            .compress,
            .forceWebsockets(true),
            .reconnects(true),
            .reconnectWait(2),
            .reconnectAttempts(5)
        ])

        socket = manager?.defaultSocket
        setupEventHandlers()
        socket?.connect()

        DispatchQueue.main.async {
            self.serverStatus = "Connecting..."
            self.connectedServer = serverURL
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
                switch self.connectionMode {
                case .main:
                    self.connectedServer = "Main Server"
                case .community:
                    self.connectedServer = "Community Server"
                case .local:
                    self.connectedServer = "Local Server"
                case .custom:
                    self.connectedServer = self.currentServerURL
                }
                self.errorMessage = nil
                NotificationCenter.default.post(name: .serverConnectionChanged, object: nil)
            }
            // Request room list after connecting
            self.getRooms()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, ack in
            print("Disconnected from server")
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.serverStatus = "Disconnected"
                NotificationCenter.default.post(name: .serverConnectionChanged, object: nil)
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

        // Room joined response (server sends "joined-room")
        socket.on("joined-room") { [weak self] data, ack in
            print("Joined room: \(data)")
            if let responseData = data[0] as? [String: Any],
               let roomData = responseData["room"] as? [String: Any] {
                // Extract users from room data
                if let usersData = roomData["users"] as? [[String: Any]] {
                    let users = usersData.compactMap { RoomUser(from: $0) }
                    DispatchQueue.main.async {
                        self?.currentRoomUsers = users
                    }
                }
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
                        AppSoundManager.shared.playSound(.userJoin)
                    }
                }
            }
        }

        // User left room
        socket.on("user-left") { [weak self] data, ack in
            print("User left: \(data)")
            if let userData = data[0] as? [String: Any],
               let odId = userData["userId"] as? String {
                DispatchQueue.main.async {
                    self?.currentRoomUsers.removeAll { $0.id == odId }
                    AppSoundManager.shared.playSound(.userLeave)
                }
            }
        }

        // Room users list
        socket.on("room-users") { [weak self] data, ack in
            print("Room users: \(data)")
            if let responseData = data[0] as? [String: Any],
               let usersData = responseData["users"] as? [[String: Any]] {
                let users = usersData.compactMap { RoomUser(from: $0) }
                DispatchQueue.main.async {
                    self?.currentRoomUsers = users
                }
            }
        }

        // Room user count update (broadcast when users join/leave)
        socket.on("room-user-count") { [weak self] data, ack in
            print("Room user count update: \(data)")
            if let responseData = data[0] as? [String: Any],
               let usersData = responseData["users"] as? [[String: Any]] {
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

        // Device access revoked by server admin
        socket.on("access-revoked") { data, ack in
            print("Access revoked: \(data)")
            if let revokeData = data[0] as? [String: Any] {
                let reason = revokeData["reason"] as? String ?? "Access has been revoked by the server administrator"
                DispatchQueue.main.async {
                    // Post notification for UI handling
                    NotificationCenter.default.post(
                        name: .accessRevoked,
                        object: nil,
                        userInfo: ["reason": reason, "deviceId": revokeData["deviceId"] as? String ?? ""]
                    )
                }
            }
        }

        // Device linked notification
        socket.on("device-linked") { data, ack in
            print("Device linked: \(data)")
            if let deviceData = data[0] as? [String: Any] {
                NotificationCenter.default.post(
                    name: .deviceLinked,
                    object: nil,
                    userInfo: deviceData
                )
            }
        }

        // Device unlinked notification
        socket.on("device-unlinked") { data, ack in
            print("Device unlinked: \(data)")
            if let deviceData = data[0] as? [String: Any] {
                NotificationCenter.default.post(
                    name: .deviceUnlinked,
                    object: nil,
                    userInfo: deviceData
                )
            }
        }

        // Device removed notification
        socket.on("device-removed") { data, ack in
            print("Device removed: \(data)")
            if let deviceData = data[0] as? [String: Any] {
                NotificationCenter.default.post(
                    name: .deviceUnlinked,
                    object: nil,
                    userInfo: deviceData
                )
            }
        }

        // Chat message received
        socket.on("chat-message") { data, ack in
            print("Chat message received: \(data)")
            if let msgData = data[0] as? [String: Any] {
                let senderId = msgData["userId"] as? String ?? msgData["senderId"] as? String ?? ""
                let senderName = msgData["userName"] as? String ?? msgData["senderName"] as? String ?? "Unknown"
                let content = msgData["message"] as? String ?? msgData["content"] as? String ?? ""
                let messageType = msgData["type"] as? String ?? "text"

                NotificationCenter.default.post(
                    name: .incomingChatMessage,
                    object: nil,
                    userInfo: [
                        "senderId": senderId,
                        "senderName": senderName,
                        "content": content,
                        "type": messageType
                    ]
                )
            }
        }

        // Direct message received
        socket.on("direct-message") { data, ack in
            print("Direct message received: \(data)")
            if let msgData = data[0] as? [String: Any] {
                let senderId = msgData["senderId"] as? String ?? ""
                let senderName = msgData["senderName"] as? String ?? "Unknown"
                let content = msgData["message"] as? String ?? msgData["content"] as? String ?? ""

                NotificationCenter.default.post(
                    name: .incomingDirectMessage,
                    object: nil,
                    userInfo: [
                        "senderId": senderId,
                        "senderName": senderName,
                        "content": content
                    ]
                )
            }
        }

        // Typing indicator
        socket.on("user-typing") { data, ack in
            if let typingData = data[0] as? [String: Any] {
                let userId = typingData["userId"] as? String ?? ""
                let typing = typingData["typing"] as? Bool ?? false

                NotificationCenter.default.post(
                    name: .userTypingIndicator,
                    object: nil,
                    userInfo: ["userId": userId, "typing": typing]
                )
            }
        }
    }

    // MARK: - API Methods

    func getRooms() {
        socket?.emit("get-rooms")
    }

    func createRoom(
        name: String,
        description: String,
        isPrivate: Bool,
        password: String? = nil,
        durationMs: Int? = nil,
        visibility: String = "public",
        accessType: String = "hybrid",
        isAuthenticated: Bool = false,
        creatorHandle: String? = nil,
        completion: ((Result<String, Error>) -> Void)? = nil
    ) {
        guard let baseURL = baseURL, let url = URL(string: "\(baseURL)/api/rooms") else {
            completion?(.failure(NSError(domain: "VoiceLink", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "name": name,
            "description": description,
            "password": password as Any,
            "visibility": visibility,
            "accessType": accessType,
            "duration": durationMs as Any,
            "isAuthenticated": isAuthenticated,
            "creatorHandle": creatorHandle as Any,
            "visibleToGuests": visibility == "public" && accessType != "hidden"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion?(.failure(error))
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion?(.failure(NSError(domain: "VoiceLink", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])))
                    return
                }

                if let roomId = json["roomId"] as? String {
                    completion?(.success(roomId))
                } else if let errorMessage = json["error"] as? String ?? json["message"] as? String {
                    completion?(.failure(NSError(domain: "VoiceLink", code: -3, userInfo: [NSLocalizedDescriptionKey: errorMessage])))
                } else {
                    completion?(.failure(NSError(domain: "VoiceLink", code: -4, userInfo: [NSLocalizedDescriptionKey: "Room creation failed"])))
                }
            }
        }.resume()
    }

    func joinRoom(roomId: String, username: String, password: String? = nil) {
        var joinData: [String: Any] = [
            "roomId": roomId,
            "userName": username
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
            MessagingManager.shared.clearMessages()
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
