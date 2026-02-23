import Foundation
import SocketIO
import AVFoundation
import CoreAudio

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
    @Published var isAudioTransmitting: Bool = false
    @Published var audioTransmissionStatus: String = "Idle"
    @Published var inputMuted: Bool = false
    @Published var outputMuted: Bool = false
    @Published var activeRoomId: String?

    // Server options
    static let mainServer = APIEndpointResolver.canonicalMainBase
    static let localServer = APIEndpointResolver.localBase

    private var currentServerURL: String = ""
    private var useMainServer: Bool = true
    private var domainRecoveryTimer: Timer?
    private let incomingAudioQueue = DispatchQueue(label: "voicelink.incoming-audio", qos: .userInitiated)
    private let audioStartQueue = DispatchQueue(label: "voicelink.audio-start", qos: .userInitiated)
    private var pendingAudioStartWorkItem: DispatchWorkItem?
    private var roomStreamPlayer: AVPlayer?
    private var currentRoomStreamURL: URL?

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

        if toMain {
            Task { @MainActor in
                let resolvedMain = await self.resolveBestMainServer()
                self.connectSocket(to: resolvedMain, asMain: true)
            }
            return
        }

        connectSocket(to: ServerManager.localServer, asMain: false)
    }

    func connectToMainServer() {
        connect(toMain: true)
    }

    func connectToLocalServer() {
        connect(toMain: false)
    }

    func tryLocalThenMain() {
        // Try main/remote server first (primary), fallback to local
        print("Connecting to main server (primary)...")
        connect(toMain: true)

        // Set up a timeout to try local server if main fails
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if !self.isConnected && self.useMainServer {
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
        stopDomainRecoveryTimer()
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
        useMainServer = false

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

    private func connectSocket(to serverURL: String, asMain: Bool) {
        currentServerURL = serverURL
        useMainServer = asMain

        guard let url = URL(string: serverURL) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid server URL"
            }
            return
        }

        print("Connecting to server: \(serverURL)")

        manager = SocketManager(socketURL: url, config: [
            .log(false),
            .compress,
            .forceWebsockets(true),
            .reconnects(true),
            .reconnectWait(3),
            .reconnectAttempts(5),
            .secure(serverURL.hasPrefix("https"))
        ])

        socket = manager?.defaultSocket

        setupEventHandlers()
        socket?.connect()
    }

    private func resolveBestMainServer() async -> String {
        for candidate in APIEndpointResolver.mainBaseCandidates(preferred: currentServerURL) {
            if await isReachableServer(candidate) {
                return candidate
            }
        }
        return ServerManager.mainServer
    }

    private func isReachableServer(_ base: String) async -> Bool {
        guard let healthURL = APIEndpointResolver.url(base: base, path: "/api/health") else {
            return false
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 3
        request.httpMethod = "GET"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200...499).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func scheduleDomainRecoveryIfNeeded() {
        stopDomainRecoveryTimer()
        guard useMainServer else { return }
        guard APIEndpointResolver.normalize(currentServerURL) != APIEndpointResolver.canonicalMainBase else { return }

        domainRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.isConnected, self.useMainServer else {
                self.stopDomainRecoveryTimer()
                return
            }

            Task { @MainActor in
                let canonical = APIEndpointResolver.canonicalMainBase
                if APIEndpointResolver.normalize(self.currentServerURL) != canonical,
                   await self.isReachableServer(canonical) {
                    print("Domain reachable again, restoring connection to canonical domain")
                    self.connectSocket(to: canonical, asMain: true)
                }
            }
        }
    }

    private func stopDomainRecoveryTimer() {
        domainRecoveryTimer?.invalidate()
        domainRecoveryTimer = nil
    }

    private func setupEventHandlers() {
        guard let socket = socket else { return }

        // Remove all existing handlers to prevent duplicates
        socket.removeAllHandlers()

        socket.on(clientEvent: .connect) { [weak self] data, ack in
            guard let self = self else { return }
            print("Connected to server: \(self.currentServerURL)")
            DispatchQueue.main.async {
                self.isConnected = true
                self.serverStatus = "Connected"
                self.connectedServer = self.useMainServer ? "Federation" : "Local Server"
                self.errorMessage = nil
                NotificationCenter.default.post(name: .serverConnectionChanged, object: nil)
            }
            self.scheduleDomainRecoveryIfNeeded()
            // Request room list after connecting
            self.getRooms()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, ack in
            print("Disconnected from server")
            self?.stopDomainRecoveryTimer()
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
                let rooms = self?.normalizedRooms(from: roomsData) ?? []
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.roomListSignature(self.rooms) != self.roomListSignature(rooms) {
                        self.rooms = rooms
                    }
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
                if let roomId = roomData["id"] as? String ?? roomData["roomId"] as? String {
                    DispatchQueue.main.async {
                        self?.activeRoomId = roomId
                    }
                    self?.fetchActiveRoomStream(for: roomId)
                }
                self?.scheduleAudioTransmissionStart()
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
                        // Play user join sound
                        AppSoundManager.shared.playSound(.userJoin)
                        // Announce user joined
                        AccessibilityManager.shared.announceUserJoined(user.username)
                    }
                }
            }
        }

        // User left room
        socket.on("user-left") { [weak self] data, ack in
            print("User left: \(data)")
            if let userData = data[0] as? [String: Any],
               let userId = userData["userId"] as? String {
                DispatchQueue.main.async {
                    // Get username before removing for announcement
                    let userName = self?.currentRoomUsers.first(where: { $0.id == userId })?.username
                    self?.currentRoomUsers.removeAll { $0.id == userId }
                    // Play user leave sound
                    AppSoundManager.shared.playSound(.userLeave)
                    // Announce user left
                    if let name = userName {
                        AccessibilityManager.shared.announceUserLeft(name)
                    }
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

        // Jellyfin media/webhook push events
        socket.on("jellyfin-webhook-event") { data, ack in
            guard let eventData = data.first as? [String: Any] else { return }
            let title = eventData["title"] as? String ?? "Media"
            let message = eventData["message"] as? String ?? ""
            let eventType = eventData["eventType"] as? String ?? "unknown"
            let loweredType = eventType.lowercased()

            DispatchQueue.main.async {
                AppSoundManager.shared.playSound(.notification)
                if loweredType.contains("start") || loweredType.contains("play") {
                    AccessibilityManager.shared.announceStatus("\(title) started.")
                } else if loweredType.contains("stop") || loweredType.contains("end") {
                    AccessibilityManager.shared.announceStatus("\(title) stopped.")
                } else if message.isEmpty {
                    AccessibilityManager.shared.announceStatus(title)
                } else {
                    AccessibilityManager.shared.announceStatus("\(title). \(message)")
                }
                NotificationCenter.default.post(
                    name: .jellyfinWebhookEvent,
                    object: nil,
                    userInfo: [
                        "title": title,
                        "message": message,
                        "eventType": eventType,
                        "payload": eventData
                    ]
                )
            }
        }

        socket.on("media-stream-started") { data, ack in
            guard let payload = data.first as? [String: Any] else { return }
            let mediaTitle = (payload["title"] as? String)
                ?? (payload["itemName"] as? String)
                ?? (payload["itemId"] as? String)
                ?? "Media"
            let streamUrl = payload["streamUrl"] as? String
            if let streamUrl {
                self.startRoomStreamPlayback(from: streamUrl)
            }
            DispatchQueue.main.async {
                AccessibilityManager.shared.announceStatus("\(mediaTitle) started.")
                NotificationCenter.default.post(
                    name: .jellyfinMediaStreamStarted,
                    object: nil,
                    userInfo: payload
                )
            }
        }

        socket.on("media-stream-stopped") { data, ack in
            let payload = (data.first as? [String: Any]) ?? [:]
            let mediaTitle = (payload["title"] as? String)
                ?? (payload["itemName"] as? String)
                ?? (payload["itemId"] as? String)
                ?? "Media"
            self.stopRoomStreamPlayback()
            DispatchQueue.main.async {
                AccessibilityManager.shared.announceStatus("\(mediaTitle) stopped.")
                NotificationCenter.default.post(
                    name: .jellyfinMediaStreamStopped,
                    object: nil,
                    userInfo: payload
                )
            }
        }

        // MARK: - Audio Relay Handlers

        // Receive relayed audio from server (when P2P fails)
        socket.on("relayed-audio") { [weak self] data, ack in
            guard let audioInfo = data.first as? [String: Any] else { return }
            self?.processIncomingAudioPacket(audioInfo)
        }

        // Also listen for audio-data event (alternative name)
        socket.on("audio-data") { [weak self] data, ack in
            guard let audioInfo = data.first as? [String: Any] else { return }
            self?.processIncomingAudioPacket(audioInfo)
        }

        // Relay status updates
        socket.on("relay-status") { data, ack in
            print("[Audio] Relay status update: \(data)")
        }

        // P2P fallback notification
        socket.on("p2p-fallback-needed") { [weak self] data, ack in
            print("[Audio] P2P fallback needed, switching to relay mode")
            // Enable relay mode - emit audio data through server
            self?.socket?.emit("enable-audio-relay", [
                "sampleRate": 48000,
                "channels": 2
            ])
        }
    }

    // MARK: - API Methods

    func getRooms() {
        socket?.emit("get-rooms")
    }

    private func processIncomingAudioPacket(_ audioInfo: [String: Any]) {
        guard let userId = audioInfo["userId"] as? String,
              let timestamp = audioInfo["timestamp"] as? Double,
              let sampleRate = audioInfo["sampleRate"] as? Double else {
            return
        }

        incomingAudioQueue.async {
            let audioData: Data?
            if let base64String = audioInfo["audioData"] as? String {
                audioData = Data(base64Encoded: base64String)
            } else if let rawData = audioInfo["audioData"] as? Data {
                audioData = rawData
            } else {
                audioData = nil
            }

            guard let audioBuffer = audioData else { return }
            SpatialAudioEngine.shared.receiveAudioData(
                from: userId,
                data: audioBuffer,
                timestamp: timestamp,
                sampleRate: sampleRate
            )
        }
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
            "username": username,
            "userName": username
        ]
        if let password = password {
            joinData["password"] = password
        }
        socket?.emit("join-room", joinData)
        DispatchQueue.main.async {
            self.audioTransmissionStatus = "Joining room..."
        }
    }

    private func normalizedRooms(from rawRooms: [[String: Any]]) -> [ServerRoom] {
        let parsed = rawRooms.compactMap { ServerRoom(from: $0) }
        return deduplicateRooms(parsed)
    }

    private func roomListSignature(_ rooms: [ServerRoom]) -> String {
        rooms
            .map { room in
                [
                    room.id,
                    room.name,
                    room.description,
                    String(room.userCount),
                    room.isPrivate ? "1" : "0",
                    String(room.maxUsers),
                    room.createdBy ?? "",
                    room.createdByRole ?? "",
                    room.roomType ?? "",
                    room.hostServerName ?? "",
                    room.hostServerOwner ?? ""
                ].joined(separator: "|")
            }
            .sorted()
            .joined(separator: "||")
    }

    func deduplicateRooms(_ rooms: [ServerRoom]) -> [ServerRoom] {
        var deduped: [ServerRoom] = []
        var indexById: [String: Int] = [:]
        var indexByName: [String: Int] = [:]

        for room in rooms {
            let idKey = room.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let nameKey = room.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

            if let idx = indexById[idKey], !idKey.isEmpty {
                deduped[idx] = mergeRoomEntries(primary: deduped[idx], incoming: room)
                continue
            }

            if let idx = indexByName[nameKey], !nameKey.isEmpty {
                deduped[idx] = mergeRoomEntries(primary: deduped[idx], incoming: room)
                if !idKey.isEmpty { indexById[idKey] = idx }
                continue
            }

            let nextIndex = deduped.count
            deduped.append(room)
            if !idKey.isEmpty { indexById[idKey] = nextIndex }
            if !nameKey.isEmpty { indexByName[nameKey] = nextIndex }
        }

        return deduped
    }

    private func mergeRoomEntries(primary: ServerRoom, incoming: ServerRoom) -> ServerRoom {
        let primaryDate = primary.lastActivityAt ?? primary.createdAt ?? .distantPast
        let incomingDate = incoming.lastActivityAt ?? incoming.createdAt ?? .distantPast
        let preferIncoming = incomingDate > primaryDate

        let mergedDescription: String = {
            let left = primary.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let right = incoming.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if right.count > left.count { return right }
            return left
        }()

        let mergedCreatedBy = (primary.createdBy?.isEmpty == false ? primary.createdBy : incoming.createdBy)
        let mergedCreatedByRole = (primary.createdByRole?.isEmpty == false ? primary.createdByRole : incoming.createdByRole)
        let mergedRoomType = (primary.roomType?.isEmpty == false ? primary.roomType : incoming.roomType)
        let mergedHostServerName = (primary.hostServerName?.isEmpty == false ? primary.hostServerName : incoming.hostServerName)
        let mergedHostServerOwner = (primary.hostServerOwner?.isEmpty == false ? primary.hostServerOwner : incoming.hostServerOwner)

        return ServerRoom(
            id: primary.id,
            name: primary.name.isEmpty ? incoming.name : primary.name,
            description: mergedDescription,
            userCount: max(primary.userCount, incoming.userCount),
            isPrivate: primary.isPrivate || incoming.isPrivate,
            maxUsers: max(primary.maxUsers, incoming.maxUsers),
            createdBy: mergedCreatedBy,
            createdByRole: mergedCreatedByRole,
            roomType: mergedRoomType,
            createdAt: primary.createdAt ?? incoming.createdAt,
            uptimeSeconds: max(primary.uptimeSeconds ?? 0, incoming.uptimeSeconds ?? 0),
            lastActiveUsername: preferIncoming ? (incoming.lastActiveUsername ?? primary.lastActiveUsername) : (primary.lastActiveUsername ?? incoming.lastActiveUsername),
            lastActivityAt: max(primaryDate, incomingDate) == .distantPast ? nil : max(primaryDate, incomingDate),
            hostServerName: mergedHostServerName,
            hostServerOwner: mergedHostServerOwner
        )
    }

    func leaveRoom() {
        pendingAudioStartWorkItem?.cancel()
        pendingAudioStartWorkItem = nil
        socket?.emit("leave-room")
        stopAudioTransmission()
        stopRoomStreamPlayback()
        DispatchQueue.main.async {
            self.currentRoomUsers = []
            self.activeRoomId = nil
        }
    }

    private func fetchActiveRoomStream(for roomId: String) {
        guard let encodedRoomId = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(currentServerURL)/api/jellyfin/room-stream/\(encodedRoomId)") else {
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let isActive = json["active"] as? Bool ?? false
            guard isActive, let streamUrl = json["streamUrl"] as? String else {
                self.stopRoomStreamPlayback()
                return
            }
            self.startRoomStreamPlayback(from: streamUrl)
        }.resume()
    }

    private func startRoomStreamPlayback(from rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        if currentRoomStreamURL == url, roomStreamPlayer != nil {
            return
        }

        DispatchQueue.main.async {
            self.currentRoomStreamURL = url
            let item = AVPlayerItem(url: url)
            if let player = self.roomStreamPlayer {
                player.replaceCurrentItem(with: item)
                player.play()
            } else {
                let player = AVPlayer(playerItem: item)
                player.volume = 0.75
                self.roomStreamPlayer = player
                player.play()
            }
        }
    }

    private func stopRoomStreamPlayback() {
        DispatchQueue.main.async {
            self.roomStreamPlayer?.pause()
            self.roomStreamPlayer?.replaceCurrentItem(with: nil)
            self.currentRoomStreamURL = nil
        }
    }

    func sendAudioState(isMuted: Bool, isDeafened: Bool) {
        DispatchQueue.main.async {
            self.inputMuted = isMuted
            self.outputMuted = isDeafened
        }

        socket?.emit("audio-state", [
            "muted": isMuted,
            "deafened": isDeafened
        ])

        // Start/stop audio transmission based on mute state
        if isMuted {
            DispatchQueue.main.async {
                self.audioTransmissionStatus = "Input muted"
            }
            stopAudioTransmission()
        } else {
            DispatchQueue.main.async {
                self.audioTransmissionStatus = isDeafened ? "Transmitting (output muted)" : "Transmitting"
            }
            startAudioTransmission()
        }
    }

    // MARK: - Audio Transmission

    private var audioTransmitEngine: AVAudioEngine?
    private var isTransmitting = false

    private func scheduleAudioTransmissionStart() {
        pendingAudioStartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startAudioTransmission()
        }
        pendingAudioStartWorkItem = work
        audioStartQueue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func startAudioTransmission() {
        if inputMuted {
            DispatchQueue.main.async {
                self.isAudioTransmitting = false
                self.audioTransmissionStatus = "Input muted"
            }
            return
        }
        guard !isTransmitting else { return }

        // Ensure selected devices are applied before opening capture path.
        SettingsManager.shared.applySelectedAudioDevices()
        do {
            try SpatialAudioEngine.shared.start()
        } catch {
            print("[Audio] Spatial audio engine start warning: \(error)")
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Request relay mode from server
        socket?.emit("enable-audio-relay", [
            "sampleRate": format.sampleRate,
            "channels": format.channelCount
        ])

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self = self, self.isTransmitting else { return }

            // Convert PCM buffer to Data
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let data = Data(bytes: channelData[0], count: frameLength * MemoryLayout<Float>.size)

            // Encode as base64 for Socket.IO transmission
            let base64Audio = data.base64EncodedString()

            // Send audio data to server for relay
            self.socket?.emit("audio-data", [
                "audioData": base64Audio,
                "timestamp": Date().timeIntervalSince1970,
                "sampleRate": format.sampleRate
            ])
        }

        do {
            try engine.start()
            audioTransmitEngine = engine
            isTransmitting = true
            DispatchQueue.main.async {
                self.isAudioTransmitting = true
                self.audioTransmissionStatus = "Transmitting"
            }
            print("[Audio] Microphone capture started, transmitting to server")
        } catch {
            DispatchQueue.main.async {
                self.isAudioTransmitting = false
                self.audioTransmissionStatus = "Failed: \(error.localizedDescription)"
            }
            print("[Audio] Failed to start audio engine: \(error)")
        }
    }

    func stopAudioTransmission() {
        if isTransmitting {
            audioTransmitEngine?.inputNode.removeTap(onBus: 0)
            audioTransmitEngine?.stop()
            audioTransmitEngine = nil
            isTransmitting = false
        }
        DispatchQueue.main.async {
            self.isAudioTransmitting = false
            self.audioTransmissionStatus = self.inputMuted ? "Input muted" : "Stopped"
        }
        print("[Audio] Microphone capture stopped")
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
        maxUsers: Int,
        createdBy: String?,
        createdByRole: String?,
        roomType: String?,
        createdAt: Date?,
        uptimeSeconds: Int?,
        lastActiveUsername: String?,
        lastActivityAt: Date?,
        hostServerName: String?,
        hostServerOwner: String?
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

    init?(from dict: [String: Any]) {
        func stringValue(_ value: Any?) -> String? {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let int = value as? Int {
                return String(int)
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            return nil
        }

        func intValue(_ value: Any?) -> Int? {
            if let int = value as? Int {
                return int
            }
            if let number = value as? NSNumber {
                return number.intValue
            }
            if let string = value as? String,
               let parsed = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
            return nil
        }

        guard let id = stringValue(dict["id"]) ?? stringValue(dict["roomId"]),
              let name = stringValue(dict["name"]) ?? stringValue(dict["roomName"]) ?? stringValue(dict["title"]) else {
            return nil
        }
        func parseDate(_ value: Any?) -> Date? {
            if let timestamp = value as? TimeInterval {
                return Date(timeIntervalSince1970: timestamp)
            }
            if let timestampInt = value as? Int {
                return Date(timeIntervalSince1970: TimeInterval(timestampInt))
            }
            guard let stringValue = value as? String, !stringValue.isEmpty else {
                return nil
            }
            let isoFormatter = ISO8601DateFormatter()
            if let parsed = isoFormatter.date(from: stringValue) {
                return parsed
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.date(from: stringValue)
        }
        self.id = id
        self.name = name
        self.description =
            stringValue(dict["description"])
            ?? stringValue(dict["roomDescription"])
            ?? stringValue(dict["room_description"])
            ?? stringValue(dict["details"])
            ?? stringValue(dict["topic"])
            ?? stringValue(dict["about"])
            ?? stringValue(dict["summary"])
            ?? stringValue(dict["subtitle"])
            ?? ""
        self.userCount = intValue(dict["userCount"]) ?? intValue(dict["users"]) ?? intValue(dict["memberCount"]) ?? 0
        self.isPrivate = dict["isPrivate"] as? Bool ?? dict["private"] as? Bool ?? false
        self.maxUsers = intValue(dict["maxUsers"]) ?? 50
        self.createdBy = stringValue(dict["createdBy"]) ?? stringValue(dict["ownerUsername"])
        self.createdByRole = stringValue(dict["createdByRole"]) ?? stringValue(dict["ownerRole"])
        self.roomType = stringValue(dict["roomType"])
            ?? stringValue(dict["type"])
            ?? stringValue(dict["creationType"])
        self.createdAt = parseDate(dict["createdAt"] ?? dict["created"])
        self.uptimeSeconds = intValue(dict["uptimeSeconds"])
            ?? intValue(dict["uptime"])
            ?? intValue(dict["roomUptime"])
        self.lastActiveUsername = stringValue(dict["lastActiveUsername"])
            ?? stringValue(dict["lastUser"])
            ?? stringValue(dict["lastSpeaker"])
        self.lastActivityAt = parseDate(dict["lastActivityAt"] ?? dict["lastActiveAt"] ?? dict["updatedAt"])
        self.hostServerName = stringValue(dict["hostServerName"])
            ?? stringValue(dict["serverDisplayName"])
            ?? stringValue(dict["serverName"])
            ?? stringValue(dict["instanceName"])
            ?? stringValue(dict["nodeName"])
        self.hostServerOwner = stringValue(dict["hostServerOwner"])
            ?? stringValue(dict["serverOwner"])
            ?? stringValue(dict["ownerUsername"])
            ?? stringValue(dict["createdBy"])
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
    static let jellyfinWebhookEvent = Notification.Name("jellyfinWebhookEvent")
    static let jellyfinMediaStreamStarted = Notification.Name("jellyfinMediaStreamStarted")
    static let jellyfinMediaStreamStopped = Notification.Name("jellyfinMediaStreamStopped")
}
