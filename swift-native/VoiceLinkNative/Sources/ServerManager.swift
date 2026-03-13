import Foundation
import SocketIO
import AVFoundation
import CoreAudio
import UserNotifications

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
    @Published var serverConfig: ServerConfig?
    @Published var publicFederationStatus: PublicFederationStatus?
    @Published var currentRoomMedia: RoomMediaState?
    @Published var isCurrentRoomMediaMuted: Bool = false

    // Server options
    static let mainServer = APIEndpointResolver.canonicalMainBase
    static let localServer = APIEndpointResolver.localBase

    private var currentServerURL: String = ""
    private var useMainServer: Bool = true
    private var domainRecoveryTimer: Timer?
    private var federationStatusTimer: Timer?
    private let incomingAudioQueue = DispatchQueue(label: "voicelink.incoming-audio", qos: .userInitiated)
    private let audioStartQueue = DispatchQueue(label: "voicelink.audio-start", qos: .userInitiated)
    private var pendingAudioStartWorkItem: DispatchWorkItem?
    private var pendingJoinRoomId: String?
    private var pendingJoinTimeoutWorkItem: DispatchWorkItem?
    private var roomStreamPlayer: AVPlayer?
    private var currentRoomStreamURL: URL?
    private var roomStreamDidStopExplicitly = false
    private var roomStreamKeepAliveTimer: Timer?
    private var roomStreamEndObserver: NSObjectProtocol?
    private var previewStreamPlayer: AVPlayer?
    private var previewStreamURL: URL?
    private var previewStreamKeepAliveTimer: Timer?
    private var previewStreamEndObserver: NSObjectProtocol?
    private var previewRestoreWorkItem: DispatchWorkItem?
    private var previewRoomDuckVolume: Float = 0.06
    private var previewCrossfadeDuration: TimeInterval = 0.28
    private var lastSystemNotificationFingerprint: String?
    private var lastSystemNotificationAt: Date?
    private let defaultRoomStreamURLString = "https://chrismixradio.com"
    private let roomStreamDefaultVolume: Float = 0.4
    private var audioDeviceChangeObserver: NSObjectProtocol?

    // Public accessor for the current server URL
    var baseURL: String? {
        currentServerURL.isEmpty ? nil : currentServerURL
    }

    init() {
        // Default to main server
        self.currentServerURL = ServerManager.mainServer
        setupMessageNotifications()
        setupPreviewNotifications()
        setupVolumeNotifications()
        setupAudioRecoveryObservers()
    }

    private func setupMessageNotifications() {
        // Listen for outgoing messages from MessagingManager
        NotificationCenter.default.addObserver(
            forName: .sendMessageToServer,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let data = notification.userInfo else { return }
            let content = data["content"] as? String ?? ""
            let isDirect = data["isDirect"] as? Bool ?? false
            let recipientId = data["recipientId"] as? String
            let replyToId = data["replyToId"] as? String
            let type = data["type"] as? String ?? "text"
            let attachmentId = data["attachmentId"] as? String
            let attachmentName = data["attachmentName"] as? String
            let attachmentURL = data["attachmentURL"] as? String
            let attachmentCaption = data["attachmentCaption"] as? String
            let attachmentExpiresAt = data["attachmentExpiresAt"]
            let attachmentRemoved = data["attachmentRemoved"] as? Bool ?? false

            if isDirect, let recipient = recipientId {
                // Direct message
                var msgData: [String: Any] = [
                    "targetUserId": recipient,
                    "message": content,
                    "type": type,
                    "attachmentRemoved": attachmentRemoved
                ]
                if let reply = replyToId {
                    msgData["replyTo"] = reply
                }
                if let attachmentId { msgData["attachmentId"] = attachmentId }
                if let attachmentName { msgData["attachmentName"] = attachmentName }
                if let attachmentURL { msgData["attachmentURL"] = attachmentURL }
                if let attachmentCaption { msgData["attachmentCaption"] = attachmentCaption }
                if let attachmentExpiresAt { msgData["attachmentExpiresAt"] = attachmentExpiresAt }
                self?.socket?.emit("direct-message", msgData)
            } else {
                // Room message
                var msgData: [String: Any] = [
                    "message": content,
                    "type": type,
                    "attachmentRemoved": attachmentRemoved
                ]
                if let roomId = self?.activeRoomId {
                    msgData["roomId"] = roomId
                }
                if let reply = replyToId {
                    msgData["replyTo"] = reply
                }
                if let attachmentId { msgData["attachmentId"] = attachmentId }
                if let attachmentName { msgData["attachmentName"] = attachmentName }
                if let attachmentURL { msgData["attachmentURL"] = attachmentURL }
                if let attachmentCaption { msgData["attachmentCaption"] = attachmentCaption }
                if let attachmentExpiresAt { msgData["attachmentExpiresAt"] = attachmentExpiresAt }
                self?.socket?.emit("chat-message", msgData)
            }
        }

        // Typing indicator
        NotificationCenter.default.addObserver(
            forName: .sendTypingIndicator,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let data = notification.userInfo,
                  let typing = data["typing"] as? Bool else { return }
            self?.socket?.emit("typing", ["typing": typing])
        }

        // Message reactions
        NotificationCenter.default.addObserver(
            forName: .sendReactionToServer,
            object: nil,
            queue: nil
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

    private func setupPreviewNotifications() {
        NotificationCenter.default.addObserver(
            forName: .startPeekingRoom,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let roomId = notification.userInfo?["roomId"] as? String else { return }
            self.startPreviewPlayback(for: roomId)
        }

        NotificationCenter.default.addObserver(
            forName: .stopPeekingRoom,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stopPreviewPlayback()
        }
    }

    private func setupVolumeNotifications() {
        NotificationCenter.default.addObserver(
            forName: .masterVolumeChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.applyCurrentPlaybackVolume()
        }
    }

    private func setupAudioRecoveryObservers() {
        audioDeviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .audioDevicesChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleAudioDeviceChange()
        }
    }

    private func handleAudioDeviceChange() {
        // Refresh output route and volume immediately.
        applyCurrentPlaybackVolume()
        roomStreamPlayer?.isMuted = isCurrentRoomMediaMuted || outputMuted
        previewStreamPlayer?.isMuted = outputMuted

        // If actively transmitting, restart capture so the new input selection takes effect.
        guard isConnected, activeRoomId != nil, !inputMuted else { return }
        audioStartQueue.async { [weak self] in
            guard let self else { return }
            self.stopAudioTransmissionNow()
            self.startAudioTransmissionNow()
        }
    }

    private func shouldAcceptSystemNotification(fingerprint: String) -> Bool {
        if lastSystemNotificationFingerprint == fingerprint,
           let lastAt = lastSystemNotificationAt,
           Date().timeIntervalSince(lastAt) < 1.25 {
            return false
        }
        lastSystemNotificationFingerprint = fingerprint
        lastSystemNotificationAt = Date()
        return true
    }

    private func presentSystemActionNotification(_ payload: [String: Any]) {
        let settings = SettingsManager.shared
        let title = (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false) ? title! : "VoiceLink System"
        let resolvedMessage = (message?.isEmpty == false) ? message! : "A system action was sent."
        let type = (payload["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "system_action"
        let timestamp = (payload["timestamp"] as? String) ?? ""
        let fingerprint = "\(type)|\(resolvedTitle)|\(resolvedMessage)|\(timestamp)"
        guard shouldAcceptSystemNotification(fingerprint: fingerprint) else { return }

        if let roomId = (payload["roomId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !roomId.isEmpty,
           roomId == activeRoomId {
            NotificationCenter.default.post(
                name: .incomingChatMessage,
                object: nil,
                userInfo: [
                    "senderId": "system",
                    "senderName": "System",
                    "content": resolvedMessage,
                    "type": "system",
                    "messageId": payload["id"] as? String ?? UUID().uuidString,
                    "timestamp": payload["timestamp"] as Any
                ]
            )
        }

        guard settings.systemActionNotifications else { return }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .systemActionNotification,
                object: nil,
                userInfo: payload
            )
            if settings.soundNotifications && settings.systemActionNotificationSound {
                AppSoundManager.shared.playSound(.notification)
            }
            AccessibilityManager.shared.announceStatus("\(resolvedTitle). \(resolvedMessage)")
            guard settings.desktopNotifications else { return }
            self.deliverSystemActionDesktopNotification(
                identifier: "system-action-\(UUID().uuidString)",
                title: resolvedTitle,
                body: resolvedMessage
            )
        }
    }

    private func deliverSystemActionDesktopNotification(identifier: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let deliver: () -> Void = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                center.add(request)
            }

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                deliver()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    if granted {
                        deliver()
                    }
                }
            default:
                break
            }
        }
    }

    private func refreshSpatialLayoutIfNeeded() {
        guard SettingsManager.shared.spatialAudioEnabled else { return }
        if let activeRoomId,
           let activeRoom = rooms.first(where: { $0.id == activeRoomId }),
           activeRoom.spatialAudioEnabled == false {
            return
        }

        let listeners = currentRoomUsers.filter { !$0.isBot }
        guard !listeners.isEmpty else { return }

        let ordered = listeners.sorted {
            let left = ($0.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? $0.displayName!
                : $0.username).localizedLowercase
            let right = ($1.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? $1.displayName!
                : $1.username).localizedLowercase
            return left < right
        }

        let total = max(ordered.count, 1)
        let startAngle: Float = total == 1 ? 0 : -70
        let endAngle: Float = total == 1 ? 0 : 70
        let distance: Float = 2.2

        for (index, user) in ordered.enumerated() {
            let angle: Float
            if total == 1 {
                angle = 0
            } else {
                let progress = Float(index) / Float(total - 1)
                angle = startAngle + ((endAngle - startAngle) * progress)
            }
            SpatialAudioEngine.shared.setUserPositionPolar(userId: user.odId, angle: angle, distance: distance)
        }
    }

    private var effectiveRoomPlaybackVolume: Float {
        let appVolume = UserAudioControlManager.shared.masterVolume
        return max(0.0, min(1.0, roomStreamDefaultVolume * appVolume))
    }

    private func applyCurrentPlaybackVolume() {
        let volume = effectiveRoomPlaybackVolume
        roomStreamPlayer?.volume = volume
        previewStreamPlayer?.volume = volume
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
        stopFederationStatusTimer()
        DispatchQueue.main.async {
            self.isConnected = false
            self.serverStatus = "Disconnected"
            self.connectedServer = ""
            self.publicFederationStatus = nil
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

    func fetchPublicServerConfig() async {
        let decoder = JSONDecoder()

        for base in APIEndpointResolver.apiBaseCandidates(preferred: currentServerURL) {
            guard let configURL = APIEndpointResolver.url(base: base, path: "/api/config") else { continue }

            var request = URLRequest(url: configURL)
            request.timeoutInterval = 4
            request.httpMethod = "GET"

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    continue
                }
                let config = try decoder.decode(ServerConfig.self, from: data)
                await MainActor.run {
                    self.serverConfig = config
                }
                return
            } catch {
                continue
            }
        }

        await MainActor.run {
            self.serverConfig = nil
        }
    }

    func fetchPublicFederationStatus() async {
        for base in APIEndpointResolver.apiBaseCandidates(preferred: currentServerURL) {
            guard let statusURL = APIEndpointResolver.url(base: base, path: "/api/federation/status") else { continue }

            var request = URLRequest(url: statusURL)
            request.timeoutInterval = 4
            request.httpMethod = "GET"

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let connectedServerCount: Int = {
                    if let value = json["connectedServers"] as? Int {
                        return value
                    }
                    if let array = json["connectedServers"] as? [[String: Any]] {
                        return array.count
                    }
                    if let array = json["connectedServers"] as? [Any] {
                        return array.count
                    }
                    return 0
                }()

                let status = PublicFederationStatus(
                    enabled: json["enabled"] as? Bool ?? false,
                    allowIncoming: json["allowIncoming"] as? Bool ?? true,
                    allowOutgoing: json["allowOutgoing"] as? Bool ?? true,
                    trustedServers: json["trustedServers"] as? [String] ?? [],
                    maintenanceModeEnabled: json["maintenanceModeEnabled"] as? Bool ?? false,
                    autoHandoffEnabled: json["autoHandoffEnabled"] as? Bool ?? false,
                    handoffTargetServer: json["handoffTargetServer"] as? String,
                    connectedServerCount: connectedServerCount
                )

                await MainActor.run {
                    self.publicFederationStatus = status
                }
                return
            } catch {
                continue
            }
        }

        await MainActor.run {
            self.publicFederationStatus = nil
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

    private func startFederationStatusTimer() {
        stopFederationStatusTimer()
        federationStatusTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            Task {
                await self.fetchPublicFederationStatus()
            }
        }
        if let federationStatusTimer {
            RunLoop.main.add(federationStatusTimer, forMode: .common)
        }
    }

    private func stopFederationStatusTimer() {
        federationStatusTimer?.invalidate()
        federationStatusTimer = nil
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
            self.startFederationStatusTimer()
            Task {
                await self.fetchPublicServerConfig()
                await self.fetchPublicFederationStatus()
            }
            // Request room list after connecting
            self.getRooms()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, ack in
            print("Disconnected from server")
            self?.stopDomainRecoveryTimer()
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.serverStatus = "Disconnected"
                self?.serverConfig = nil
                self?.publicFederationStatus = nil
                NotificationCenter.default.post(name: .serverConnectionChanged, object: nil)
            }
            self?.failPendingJoin(with: "Disconnected while joining room.")
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

        // Room joined response (support multiple event names used by different server versions).
        let handleJoinedRoomEvent: ([Any]) -> Void = { [weak self] data in
            print("Joined room: \(data)")
            guard let self = self else { return }
            let responseData = data.first as? [String: Any] ?? [:]
            let roomData = (responseData["room"] as? [String: Any]) ?? responseData

            if let usersData = (roomData["users"] as? [[String: Any]]) ?? (responseData["users"] as? [[String: Any]]) {
                let users = usersData.compactMap { RoomUser(from: $0) }
                DispatchQueue.main.async {
                    self.currentRoomUsers = users
                    self.refreshSpatialLayoutIfNeeded()
                }
            }

            let roomId = roomData["id"] as? String
                ?? roomData["roomId"] as? String
                ?? responseData["roomId"] as? String
                ?? responseData["id"] as? String
                ?? self.pendingJoinRoomId

            if let roomId {
                self.completePendingJoin(for: roomId)
                DispatchQueue.main.async {
                    self.activeRoomId = roomId
                    self.audioTransmissionStatus = "Joined room"
                }
                self.fetchActiveRoomStream(for: roomId)
                self.scheduleAudioTransmissionStart(for: roomId)
            } else {
                self.cancelJoinTimeout()
            }

            var joinedPayload = roomData
            if let roomId {
                joinedPayload["roomId"] = roomId
                if joinedPayload["id"] == nil {
                    joinedPayload["id"] = roomId
                }
            }
            NotificationCenter.default.post(name: .roomJoined, object: joinedPayload)
        }
        let joinSuccessEvents = ["joined-room", "room-joined", "join-room-success"]
        for eventName in joinSuccessEvents {
            socket.on(eventName) { data, ack in
                handleJoinedRoomEvent(data)
            }
        }

        // User joined room
        socket.on("user-joined") { [weak self] data, ack in
            print("User joined: \(data)")
            if let userData = data[0] as? [String: Any],
               let user = RoomUser(from: userData) {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if !self.currentRoomUsers.contains(where: { $0.id == user.id }) {
                        self.currentRoomUsers.append(user)
                        self.refreshSpatialLayoutIfNeeded()
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
                    self?.refreshSpatialLayoutIfNeeded()
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
                    self?.refreshSpatialLayoutIfNeeded()
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
                    self?.refreshSpatialLayoutIfNeeded()
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
                self?.failPendingJoin(with: message)
            } else if let payload = data.first as? [String: Any],
                      let message = payload["error"] as? String ?? payload["message"] as? String {
                DispatchQueue.main.async {
                    self?.errorMessage = message
                }
                self?.failPendingJoin(with: message)
            }
        }

        let roomJoinErrorEvents = ["join-room-error", "room-join-error", "room-error", "join-error"]
        for eventName in roomJoinErrorEvents {
            socket.on(eventName) { [weak self] data, ack in
                let payload = data.first as? [String: Any]
                let message = (payload?["error"] as? String)
                    ?? (payload?["message"] as? String)
                    ?? (data.first as? String)
                    ?? "Unable to join room."
                DispatchQueue.main.async {
                    self?.errorMessage = message
                }
                self?.failPendingJoin(with: message)
            }
        }

        socket.on("kicked-from-room") { [weak self] data, ack in
            let payload = data.first as? [String: Any]
            let message = (payload?["reason"] as? String)
                ?? (payload?["message"] as? String)
                ?? "You were removed from the room."
            DispatchQueue.main.async {
                self?.errorMessage = message
            }
            self?.handleForcedRoomExit()
        }

        let handleSystemActionEvent: ([Any]) -> Void = { [weak self] data in
            guard let self else { return }
            guard let payload = data.first as? [String: Any] else { return }
            self.presentSystemActionNotification(payload)
        }
        socket.on("system-action-notification") { data, ack in
            handleSystemActionEvent(data)
        }
        socket.on("admin-notification") { data, ack in
            handleSystemActionEvent(data)
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
                let messageId = msgData["messageId"] as? String ?? msgData["id"] as? String ?? ""
                let timestamp = msgData["timestamp"] ?? msgData["createdAt"] ?? msgData["sentAt"]

                NotificationCenter.default.post(
                    name: .incomingChatMessage,
                    object: nil,
                    userInfo: [
                        "senderId": senderId,
                        "senderName": senderName,
                        "content": content,
                        "type": messageType,
                        "messageId": messageId,
                        "timestamp": timestamp as Any,
                        "attachmentId": msgData["attachmentId"] as Any,
                        "attachmentName": msgData["attachmentName"] as Any,
                        "attachmentURL": (msgData["attachmentURL"] ?? msgData["attachmentUrl"]) as Any,
                        "attachmentCaption": (msgData["attachmentCaption"] ?? msgData["caption"]) as Any,
                        "attachmentExpiresAt": msgData["attachmentExpiresAt"] as Any,
                        "attachmentRemoved": msgData["attachmentRemoved"] as Any
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
                let messageType = msgData["type"] as? String ?? "text"
                let messageId = msgData["messageId"] as? String ?? msgData["id"] as? String ?? ""
                let timestamp = msgData["timestamp"] ?? msgData["createdAt"] ?? msgData["sentAt"]

                NotificationCenter.default.post(
                    name: .incomingDirectMessage,
                    object: nil,
                    userInfo: [
                        "senderId": senderId,
                        "senderName": senderName,
                        "content": content,
                        "type": messageType,
                        "messageId": messageId,
                        "timestamp": timestamp as Any,
                        "attachmentId": msgData["attachmentId"] as Any,
                        "attachmentName": msgData["attachmentName"] as Any,
                        "attachmentURL": (msgData["attachmentURL"] ?? msgData["attachmentUrl"]) as Any,
                        "attachmentCaption": (msgData["attachmentCaption"] ?? msgData["caption"]) as Any,
                        "attachmentExpiresAt": msgData["attachmentExpiresAt"] as Any,
                        "attachmentRemoved": msgData["attachmentRemoved"] as Any
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
                self.roomStreamDidStopExplicitly = false
                self.startRoomStreamPlayback(from: streamUrl)
            } else if let activeRoomId = self.activeRoomId {
                // Some servers omit streamUrl in push payloads; re-fetch full room stream state.
                self.fetchActiveRoomStream(for: activeRoomId)
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
            self.stopRoomStreamPlayback(explicit: false)
            if let activeRoomId = self.activeRoomId {
                self.fetchActiveRoomStream(for: activeRoomId)
            }
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
        let channels = max(1, audioInfo["channels"] as? Int ?? 1)

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
                sampleRate: sampleRate,
                channels: channels
            )
        }
    }

    func createRoom(
        name: String,
        description: String,
        isPrivate: Bool,
        password: String? = nil,
        preferredServerBase: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        var roomData: [String: Any] = [
            "name": name,
            "description": description,
            "isPrivate": isPrivate
        ]
        if let password = password {
            roomData["password"] = password
        }
        if let preferredServerBase, !preferredServerBase.isEmpty {
            roomData["preferredServerBase"] = preferredServerBase
        }
        if let metadata {
            for (key, value) in metadata {
                roomData[key] = value
            }
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
        pendingJoinRoomId = roomId
        scheduleJoinTimeout(for: roomId)
        socket?.emitWithAck("join-room", joinData).timingOut(after: 8) { [weak self] ackData in
            guard let self = self else { return }
            if let first = ackData.first as? String, first.uppercased() == "NO ACK" {
                return
            }
            if let payload = ackData.first as? [String: Any] {
                if let message = payload["error"] as? String {
                    DispatchQueue.main.async {
                        self.errorMessage = message
                    }
                    self.failPendingJoin(with: message)
                    return
                }
                if let success = payload["success"] as? Bool, success == false {
                    let message = (payload["message"] as? String) ?? "Failed to join room."
                    DispatchQueue.main.async {
                        self.errorMessage = message
                    }
                    self.failPendingJoin(with: message)
                    return
                }
            }
            if let message = ackData.first as? String {
                let lowered = message.lowercased()
                if lowered.contains("error") || lowered.contains("denied") || lowered.contains("failed") {
                    DispatchQueue.main.async {
                        self.errorMessage = message
                    }
                    self.failPendingJoin(with: message)
                    return
                }
                if lowered.contains("ok") || lowered.contains("success") || lowered.contains("joined") {
                    self.completeJoinFromAck(roomId: roomId, payload: ["roomId": roomId])
                    return
                }
            }
            // Some server builds ACK join-room without emitting a follow-up join event.
            // Treat any non-error ACK payload as join success to avoid client-side stalls.
            if let payload = ackData.first as? [String: Any] {
                self.completeJoinFromAck(roomId: roomId, payload: payload)
                return
            }
            if ackData.isEmpty {
                self.completeJoinFromAck(roomId: roomId, payload: ["roomId": roomId])
            }
        }
        DispatchQueue.main.async {
            self.audioTransmissionStatus = "Joining room..."
        }
    }

    private func completeJoinFromAck(roomId: String, payload: [String: Any]) {
        let roomData = (payload["room"] as? [String: Any]) ?? payload
        let joinedRoomId = roomData["id"] as? String
            ?? roomData["roomId"] as? String
            ?? payload["roomId"] as? String
            ?? payload["id"] as? String
            ?? roomId

        completePendingJoin(for: joinedRoomId)
        DispatchQueue.main.async {
            self.activeRoomId = joinedRoomId
            self.audioTransmissionStatus = "Joined room"
        }
        fetchActiveRoomStream(for: joinedRoomId)
        scheduleAudioTransmissionStart(for: joinedRoomId)

        var joinedPayload = roomData
        joinedPayload["roomId"] = joinedRoomId
        if joinedPayload["id"] == nil {
            joinedPayload["id"] = joinedRoomId
        }
        NotificationCenter.default.post(name: .roomJoined, object: joinedPayload)
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
        var indexBySourceAndName: [String: Int] = [:]

        for room in rooms {
            let idKey = room.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let nameKey = room.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let sourceKey = (room.hostServerName ?? room.hostServerOwner ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let compositeKey = [sourceKey, nameKey].joined(separator: "::")

            if let idx = indexById[idKey], !idKey.isEmpty {
                deduped[idx] = mergeRoomEntries(primary: deduped[idx], incoming: room)
                continue
            }

            if let idx = indexBySourceAndName[compositeKey], !nameKey.isEmpty {
                deduped[idx] = mergeRoomEntries(primary: deduped[idx], incoming: room)
                if !idKey.isEmpty { indexById[idKey] = idx }
                continue
            }

            let nextIndex = deduped.count
            deduped.append(room)
            if !idKey.isEmpty { indexById[idKey] = nextIndex }
            if !nameKey.isEmpty { indexBySourceAndName[compositeKey] = nextIndex }
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
            uptimeSeconds: mergedUptimeSeconds(primary: primary.uptimeSeconds, incoming: incoming.uptimeSeconds),
            lastActiveUsername: preferIncoming ? (incoming.lastActiveUsername ?? primary.lastActiveUsername) : (primary.lastActiveUsername ?? incoming.lastActiveUsername),
            lastActivityAt: max(primaryDate, incomingDate) == .distantPast ? nil : max(primaryDate, incomingDate),
            hostServerName: mergedHostServerName,
            hostServerOwner: mergedHostServerOwner,
            spatialAudioEnabled: primary.spatialAudioEnabled ?? incoming.spatialAudioEnabled
        )
    }

    private func mergedUptimeSeconds(primary: Int?, incoming: Int?) -> Int? {
        switch (primary, incoming) {
        case let (a?, b?):
            return max(a, b)
        case let (a?, nil):
            return a
        case let (nil, b?):
            return b
        case (nil, nil):
            return nil
        }
    }

    func leaveRoom() {
        cancelJoinTimeout()
        pendingJoinRoomId = nil
        pendingAudioStartWorkItem?.cancel()
        pendingAudioStartWorkItem = nil
        socket?.emit("leave-room")
        handleForcedRoomExit()
    }

    private func handleForcedRoomExit() {
        stopAudioTransmission()
        stopRoomStreamPlayback(explicit: true)
        DispatchQueue.main.async {
            self.currentRoomUsers = []
            self.activeRoomId = nil
            self.audioTransmissionStatus = self.inputMuted ? "Input muted" : "Stopped"
        }
        NotificationCenter.default.post(name: .roomLeft, object: nil)
    }

    private func fetchRoomStreamState(for roomId: String, completion: @escaping (RoomMediaState?) -> Void) {
        guard let encodedRoomId = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let candidates = APIEndpointResolver.apiBaseCandidates(preferred: currentServerURL)

        func tryCandidate(at index: Int) {
            guard index < candidates.count else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard let url = APIEndpointResolver.url(base: candidates[index], path: "/api/jellyfin/room-stream/\(encodedRoomId)") else {
                tryCandidate(at: index + 1)
                return
            }

            URLSession.shared.dataTask(with: url) { data, response, _ in
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    tryCandidate(at: index + 1)
                    return
                }

                let isActive = json["active"] as? Bool ?? false
                let mediaEnabled = json["mediaEnabled"] as? Bool ?? !(json["disabled"] as? Bool ?? false)
                let streamUrl = (json["streamUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard isActive, !streamUrl.isEmpty else {
                    DispatchQueue.main.async {
                        completion(RoomMediaState(
                            active: false,
                            mediaEnabled: mediaEnabled,
                            title: (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                            streamURL: "",
                            type: (json["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                            volume: json["volume"] as? Int
                        ))
                    }
                    return
                }

                let mediaState = RoomMediaState(
                    active: isActive,
                    mediaEnabled: mediaEnabled,
                    title: (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    streamURL: streamUrl,
                    type: (json["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    volume: json["volume"] as? Int
                )
                DispatchQueue.main.async { completion(mediaState) }
            }.resume()
        }

        tryCandidate(at: 0)
    }

    private func fetchActiveRoomStream(for roomId: String) {
        roomStreamDidStopExplicitly = false
        fetchRoomStreamState(for: roomId) { [weak self] mediaState in
            guard let self else { return }
            guard let mediaState else {
                self.currentRoomMedia = nil
                self.stopRoomStreamPlayback(explicit: false)
                return
            }
            guard mediaState.active, !mediaState.streamURL.isEmpty else {
                self.currentRoomMedia = mediaState
                self.stopRoomStreamPlayback(explicit: false)
                return
            }
            self.currentRoomMedia = mediaState
            self.startRoomStreamPlayback(from: mediaState.streamURL)
        }
    }

    func refreshCurrentRoomMedia() {
        guard let roomId = activeRoomId, !roomId.isEmpty else { return }
        fetchActiveRoomStream(for: roomId)
    }

    private func startRoomStreamPlayback(from rawURL: String) {
        guard let url = normalizedMediaStreamURL(from: rawURL) else { return }
        DispatchQueue.main.async {
            if self.currentRoomStreamURL == url, let player = self.roomStreamPlayer {
                player.volume = self.effectiveRoomPlaybackVolume
                player.isMuted = self.isCurrentRoomMediaMuted || self.outputMuted
                player.playImmediately(atRate: 1.0)
                self.ensureRoomStreamKeepAlive()
                return
            }
            self.currentRoomStreamURL = url
            let item = AVPlayerItem(url: url)
            if let observer = self.roomStreamEndObserver {
                NotificationCenter.default.removeObserver(observer)
                self.roomStreamEndObserver = nil
            }
            self.roomStreamEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                guard !self.roomStreamDidStopExplicitly, let current = self.currentRoomStreamURL else { return }
                self.startRoomStreamPlayback(from: current.absoluteString)
            }

            if let player = self.roomStreamPlayer {
                player.replaceCurrentItem(with: item)
                player.volume = self.effectiveRoomPlaybackVolume
                player.isMuted = self.isCurrentRoomMediaMuted || self.outputMuted
                player.playImmediately(atRate: 1.0)
            } else {
                let player = AVPlayer(playerItem: item)
                player.automaticallyWaitsToMinimizeStalling = false
                player.volume = self.effectiveRoomPlaybackVolume
                player.isMuted = self.isCurrentRoomMediaMuted || self.outputMuted
                self.roomStreamPlayer = player
                player.playImmediately(atRate: 1.0)
            }
            self.ensureRoomStreamKeepAlive()
        }
    }

    private func ensureRoomStreamKeepAlive() {
        roomStreamKeepAliveTimer?.invalidate()
        roomStreamKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let activeRoomId = self.activeRoomId else { return }
            guard !self.roomStreamDidStopExplicitly else { return }
            self.fetchRoomStreamState(for: activeRoomId) { [weak self] mediaState in
                guard let self else { return }
                guard !self.roomStreamDidStopExplicitly else { return }
                guard let mediaState else {
                    self.stopRoomStreamPlayback(explicit: false)
                    return
                }

                self.currentRoomMedia = mediaState
                guard mediaState.active, !mediaState.streamURL.isEmpty else {
                    self.stopRoomStreamPlayback(explicit: false)
                    return
                }
                let nextURL = mediaState.streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let currentURL = self.currentRoomStreamURL?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if nextURL.caseInsensitiveCompare(currentURL) != .orderedSame {
                    self.startRoomStreamPlayback(from: nextURL)
                    return
                }

                guard let player = self.roomStreamPlayer else {
                    self.startRoomStreamPlayback(from: nextURL)
                    return
                }
                player.volume = self.effectiveRoomPlaybackVolume
                player.isMuted = self.isCurrentRoomMediaMuted || self.outputMuted
                if player.currentItem == nil {
                    self.startRoomStreamPlayback(from: nextURL)
                    return
                }
                if player.timeControlStatus != .playing {
                    player.playImmediately(atRate: 1.0)
                }
            }
        }
    }

    private func startPreviewPlayback(for roomId: String) {
        fetchRoomStreamState(for: roomId) { [weak self] mediaState in
            guard let self else { return }
            guard let mediaState else {
                self.stopPreviewPlayback()
                return
            }
            self.startPreviewStreamPlayback(from: mediaState.streamURL)
        }
    }

    private func startPreviewStreamPlayback(from rawURL: String) {
        guard let url = normalizedMediaStreamURL(from: rawURL) else { return }
        DispatchQueue.main.async {
            self.previewRestoreWorkItem?.cancel()
            self.previewRestoreWorkItem = nil
            self.duckCurrentRoomForPreview()
            if self.previewStreamURL == url, let player = self.previewStreamPlayer {
                player.volume = 0
                player.isMuted = self.outputMuted
                player.playImmediately(atRate: 1.0)
                self.fadePlayerVolume(player, to: self.effectiveRoomPlaybackVolume, duration: self.previewCrossfadeDuration)
                self.ensurePreviewStreamKeepAlive()
                return
            }

            self.previewStreamURL = url
            let item = AVPlayerItem(url: url)
            if let observer = self.previewStreamEndObserver {
                NotificationCenter.default.removeObserver(observer)
                self.previewStreamEndObserver = nil
            }
            self.previewStreamEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: nil
            ) { [weak self] _ in
                guard let self, let current = self.previewStreamURL else { return }
                self.startPreviewStreamPlayback(from: current.absoluteString)
            }

            if let player = self.previewStreamPlayer {
                player.replaceCurrentItem(with: item)
                player.volume = 0
                player.isMuted = self.outputMuted
                player.playImmediately(atRate: 1.0)
                self.fadePlayerVolume(player, to: self.effectiveRoomPlaybackVolume, duration: self.previewCrossfadeDuration)
            } else {
                let player = AVPlayer(playerItem: item)
                player.automaticallyWaitsToMinimizeStalling = false
                player.volume = 0
                player.isMuted = self.outputMuted
                self.previewStreamPlayer = player
                player.playImmediately(atRate: 1.0)
                self.fadePlayerVolume(player, to: self.effectiveRoomPlaybackVolume, duration: self.previewCrossfadeDuration)
            }
            self.ensurePreviewStreamKeepAlive()
        }
    }

    private func ensurePreviewStreamKeepAlive() {
        previewStreamKeepAliveTimer?.invalidate()
        previewStreamKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let player = self.previewStreamPlayer else { return }
            player.volume = self.effectiveRoomPlaybackVolume
            player.isMuted = self.outputMuted
            if player.currentItem == nil, let current = self.previewStreamURL {
                self.startPreviewStreamPlayback(from: current.absoluteString)
                return
            }
            if player.timeControlStatus != .playing {
                player.playImmediately(atRate: 1.0)
            }
        }
    }

    private func stopPreviewPlayback() {
        DispatchQueue.main.async {
            self.previewStreamKeepAliveTimer?.invalidate()
            self.previewStreamKeepAliveTimer = nil
            if let observer = self.previewStreamEndObserver {
                NotificationCenter.default.removeObserver(observer)
                self.previewStreamEndObserver = nil
            }
            let outgoingPlayer = self.previewStreamPlayer
            let restoreDelay = SettingsManager.shared.previewSoundCuesEnabled ? 0.32 : 0.0
            if let outgoingPlayer {
                self.fadePlayerVolume(outgoingPlayer, to: 0, duration: self.previewCrossfadeDuration)
            }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                outgoingPlayer?.pause()
                outgoingPlayer?.replaceCurrentItem(with: nil)
                if self.previewStreamPlayer === outgoingPlayer {
                    self.previewStreamPlayer = nil
                }
                self.previewStreamURL = nil
                self.restoreCurrentRoomAfterPreview()
            }
            self.previewRestoreWorkItem?.cancel()
            self.previewRestoreWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + max(restoreDelay, self.previewCrossfadeDuration), execute: workItem)
        }
    }

    private func stopRoomStreamPlayback(explicit: Bool = true) {
        DispatchQueue.main.async {
            if explicit {
                self.roomStreamDidStopExplicitly = true
            }
            self.roomStreamKeepAliveTimer?.invalidate()
            self.roomStreamKeepAliveTimer = nil
            if let observer = self.roomStreamEndObserver {
                NotificationCenter.default.removeObserver(observer)
                self.roomStreamEndObserver = nil
            }
            self.roomStreamPlayer?.pause()
            self.roomStreamPlayer?.replaceCurrentItem(with: nil)
            self.currentRoomStreamURL = nil
            self.currentRoomMedia = nil
        }
    }

    func setCurrentRoomMediaMuted(_ muted: Bool) {
        DispatchQueue.main.async {
            self.isCurrentRoomMediaMuted = muted
            self.roomStreamPlayer?.volume = self.effectiveRoomPlaybackVolume
            self.roomStreamPlayer?.isMuted = muted || self.outputMuted
        }
    }

    private func duckCurrentRoomForPreview() {
        guard let player = roomStreamPlayer else { return }
        if player.timeControlStatus != .playing {
            player.playImmediately(atRate: 1.0)
        }
        player.isMuted = outputMuted
        fadePlayerVolume(player, to: min(previewRoomDuckVolume, effectiveRoomPlaybackVolume), duration: previewCrossfadeDuration)
    }

    private func restoreCurrentRoomAfterPreview() {
        guard let player = roomStreamPlayer else { return }
        player.isMuted = isCurrentRoomMediaMuted || outputMuted
        if player.currentItem != nil, !player.isMuted {
            player.playImmediately(atRate: 1.0)
        }
        fadePlayerVolume(player, to: effectiveRoomPlaybackVolume, duration: previewCrossfadeDuration)
    }

    private func fadePlayerVolume(_ player: AVPlayer, to target: Float, duration: TimeInterval) {
        let start = player.volume
        let delta = target - start
        guard abs(delta) > 0.001 else {
            player.volume = target
            return
        }
        let steps = max(1, Int(duration / 0.04))
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + (duration * Double(step) / Double(steps))) {
                player.volume = start + (delta * Float(step) / Float(steps))
            }
        }
    }

    func toggleCurrentRoomMediaMuted() {
        setCurrentRoomMediaMuted(!isCurrentRoomMediaMuted)
    }

    func stopCurrentRoomMedia() {
        stopRoomStreamPlayback(explicit: true)
    }

    func setRoomMediaEnabled(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        guard let roomId = activeRoomId?.trimmingCharacters(in: .whitespacesAndNewlines), !roomId.isEmpty else {
            completion?(false)
            return
        }

        guard let body = try? JSONSerialization.data(withJSONObject: ["enabled": enabled]) else {
            completion?(false)
            return
        }

        let candidates = APIEndpointResolver.apiBaseCandidates(preferred: currentServerURL)

        func tryCandidate(at index: Int) {
            guard index < candidates.count else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            guard let encodedRoomId = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = APIEndpointResolver.url(base: candidates[index], path: "/api/rooms/\(encodedRoomId)/media-enabled") else {
                tryCandidate(at: index + 1)
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.timeoutInterval = 8
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
                guard let self else { return }
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    DispatchQueue.main.async {
                        if enabled {
                            AccessibilityManager.shared.announceStatus("Room stream enabled for this room.")
                            self.roomStreamDidStopExplicitly = false
                            self.refreshCurrentRoomMedia()
                        } else {
                            self.roomStreamDidStopExplicitly = true
                            self.stopRoomStreamPlayback(explicit: true)
                            AccessibilityManager.shared.announceStatus("Room stream disabled for this room.")
                        }
                        completion?(true)
                    }
                    return
                }
                tryCandidate(at: index + 1)
            }.resume()
        }

        tryCandidate(at: 0)
    }

    private func normalizedMediaStreamURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let explicit = URL(string: trimmed), let scheme = explicit.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return explicit
        }

        // Relative paths from API payloads should resolve against the active API base.
        if trimmed.hasPrefix("/") {
            for base in APIEndpointResolver.apiBaseCandidates(preferred: currentServerURL) {
                if let resolved = APIEndpointResolver.url(base: base, path: trimmed) {
                    return resolved
                }
            }
        }

        // Many admin-configured streams are saved without a scheme.
        if let httpsFallback = URL(string: "https://\(trimmed)") {
            return httpsFallback
        }
        if let httpFallback = URL(string: "http://\(trimmed)") {
            return httpFallback
        }
        return nil
    }

    func sendAudioState(isMuted: Bool, isDeafened: Bool) {
        DispatchQueue.main.async {
            self.inputMuted = isMuted
            self.outputMuted = isDeafened
            self.applyCurrentPlaybackVolume()
            self.roomStreamPlayer?.isMuted = self.isCurrentRoomMediaMuted || isDeafened
            self.previewStreamPlayer?.isMuted = isDeafened
        }
        LocalMonitorManager.shared.setInputMuted(isMuted)

        socket?.emit("audio-state", [
            "muted": isMuted,
            "deafened": isDeafened
        ])

        // Start/stop audio transmission based on mute state
        if isMuted {
            DispatchQueue.main.async {
                self.audioTransmissionStatus = "Input muted"
            }
            audioStartQueue.async { [weak self] in
                self?.stopAudioTransmissionNow()
            }
        } else {
            DispatchQueue.main.async {
                self.audioTransmissionStatus = isDeafened ? "Transmitting (output muted)" : "Transmitting"
            }
            audioStartQueue.async { [weak self] in
                self?.startAudioTransmissionNow()
            }
        }
    }

    // MARK: - Audio Transmission

    private var audioTransmitCaptureToken: UUID?
    private var isTransmitting = false

    private func scheduleAudioTransmissionStart(for roomId: String) {
        pendingAudioStartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.activeRoomId == roomId, self.isConnected else { return }
            self.startAudioTransmission()
        }
        pendingAudioStartWorkItem = work
        audioStartQueue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func scheduleJoinTimeout(for roomId: String) {
        cancelJoinTimeout()
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.pendingJoinRoomId == roomId else { return }
            self.failPendingJoin(with: "Room join timed out. Please try again.")
        }
        pendingJoinTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeoutWork)
    }

    private func cancelJoinTimeout() {
        pendingJoinTimeoutWorkItem?.cancel()
        pendingJoinTimeoutWorkItem = nil
    }

    private func completePendingJoin(for roomId: String) {
        if pendingJoinRoomId == roomId {
            pendingJoinRoomId = nil
        }
        cancelJoinTimeout()
    }

    private func failPendingJoin(with message: String) {
        guard pendingJoinRoomId != nil else { return }
        cancelJoinTimeout()
        pendingJoinRoomId = nil
        DispatchQueue.main.async {
            self.audioTransmissionStatus = "Join failed"
            self.errorMessage = message
        }
        pendingAudioStartWorkItem?.cancel()
        pendingAudioStartWorkItem = nil
    }

    func startAudioTransmission() {
        audioStartQueue.async { [weak self] in
            self?.startAudioTransmissionNow()
        }
    }

    private func startAudioTransmissionNow() {
        if inputMuted {
            DispatchQueue.main.async {
                self.isAudioTransmitting = false
                self.audioTransmissionStatus = "Input muted"
            }
            return
        }
        guard !isTransmitting else { return }

        // Ensure selected devices are applied before opening capture path.
        SettingsManager.shared.applySelectedAudioDevices(notifyChange: false)
        do {
            try SpatialAudioEngine.shared.start()
        } catch {
            print("[Audio] Spatial audio engine start warning: \(error)")
        }

        let sampleRate = 48000.0
        let channels: UInt32 = 2

        // Request relay mode from server
        socket?.emit("enable-audio-relay", [
            "sampleRate": sampleRate,
            "channels": channels
        ])

        let selectedInput = SettingsManager.shared.inputDevice
        audioTransmitCaptureToken = SelectedAudioInputCapture.shared.start(deviceName: selectedInput) { [weak self] buffer in
            guard let self = self, self.isTransmitting else { return }
            LocalMonitorManager.shared.ingestSharedTransmissionBuffer(buffer)

            // Convert PCM buffer to Data
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let channelCount = Int(max(buffer.format.channelCount, 1))
            var interleaved = [Float](repeating: 0, count: frameLength * channelCount)
            let gain = Float(min(max(SettingsManager.shared.inputVolume, 0), 1))
            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    interleaved[(frame * channelCount) + channel] = channelData[channel][frame] * gain
                }
            }
            let data = interleaved.withUnsafeBufferPointer { pointer in
                Data(buffer: pointer)
            }

            // Encode as base64 for Socket.IO transmission
            let base64Audio = data.base64EncodedString()

            // Send audio data to server for relay
            self.socket?.emit("audio-data", [
                "audioData": base64Audio,
                "timestamp": Date().timeIntervalSince1970,
                "sampleRate": buffer.format.sampleRate,
                "channels": channelCount
            ])
        }

        isTransmitting = true
        LocalMonitorManager.shared.refreshForSharedCaptureChange(reason: "audioTransmissionStarted")
        DispatchQueue.main.async {
            self.isAudioTransmitting = true
            self.audioTransmissionStatus = "Transmitting"
        }
        print("[Audio] Microphone capture started, transmitting to server")
    }

    func stopAudioTransmission() {
        audioStartQueue.async { [weak self] in
            self?.stopAudioTransmissionNow()
        }
    }

    private func stopAudioTransmissionNow() {
        if isTransmitting {
            if let token = audioTransmitCaptureToken {
                SelectedAudioInputCapture.shared.stop(token: token)
                audioTransmitCaptureToken = nil
            }
            isTransmitting = false
            LocalMonitorManager.shared.refreshForSharedCaptureChange(reason: "audioTransmissionStopped")
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
                let ourClientId = UserDefaults().string(forKey: "clientId")
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
    let spatialAudioEnabled: Bool?

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
        hostServerOwner: String?,
        spatialAudioEnabled: Bool?
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
        self.spatialAudioEnabled = spatialAudioEnabled
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
        self.spatialAudioEnabled = dict["spatialAudioEnabled"] as? Bool
            ?? (dict["metadata"] as? [String: Any])?["spatialAudioEnabled"] as? Bool
    }
}

struct RoomMediaState: Equatable {
    let active: Bool
    let mediaEnabled: Bool
    let title: String?
    let streamURL: String
    let type: String?
    let volume: Int?
}

struct PublicFederationStatus: Equatable {
    let enabled: Bool
    let allowIncoming: Bool
    let allowOutgoing: Bool
    let trustedServers: [String]
    let maintenanceModeEnabled: Bool
    let autoHandoffEnabled: Bool
    let handoffTargetServer: String?
    let connectedServerCount: Int
}

struct RoomUser: Identifiable {
    enum InteractionMode: String {
        case text
        case audio
        case textAndAudio

        var supportsAudio: Bool {
            switch self {
            case .text:
                return false
            case .audio, .textAndAudio:
                return true
            }
        }
    }

    let id: String
    let odId: String
    let username: String
    let isMuted: Bool
    let isDeafened: Bool
    let isSpeaking: Bool
    let displayName: String?
    let role: String?
    let status: String?
    let authProvider: String?
    let email: String?
    let serverTitle: String?
    let isBot: Bool
    let interactionMode: InteractionMode
    let hasAudioControls: Bool
    let statusMessage: String?
    let joinedAt: Date?
    let lastActiveAt: Date?
    let avatarURL: URL?

    init?(from dict: [String: Any]) {
        guard let odId = dict["odId"] as? String ?? dict["id"] as? String ?? dict["userId"] as? String,
              let username = dict["username"] as? String ?? dict["name"] as? String ?? dict["displayName"] as? String else {
            return nil
        }
        self.id = odId
        self.odId = odId
        self.username = username
        self.isMuted = dict["muted"] as? Bool ?? dict["isMuted"] as? Bool ?? false
        self.isDeafened = dict["deafened"] as? Bool ?? dict["isDeafened"] as? Bool ?? false
        self.isSpeaking = dict["speaking"] as? Bool ?? dict["isSpeaking"] as? Bool ?? false
        let rawDisplayName = (dict["displayName"] as? String ?? dict["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawDisplayName, !rawDisplayName.isEmpty, rawDisplayName.caseInsensitiveCompare(username) != .orderedSame {
            self.displayName = rawDisplayName
        } else {
            self.displayName = nil
        }
        self.role = dict["role"] as? String
            ?? dict["userRole"] as? String
            ?? dict["accountRole"] as? String
            ?? dict["accessRole"] as? String
        self.status = dict["status"] as? String
            ?? dict["presence"] as? String
            ?? dict["state"] as? String
        self.authProvider = dict["authProvider"] as? String
            ?? dict["provider"] as? String
            ?? dict["loginProvider"] as? String
        self.email = dict["email"] as? String ?? dict["userEmail"] as? String
        self.serverTitle = dict["serverTitle"] as? String
            ?? dict["serverName"] as? String
            ?? dict["serverDisplayName"] as? String
            ?? dict["instanceName"] as? String
        self.isBot = dict["isBot"] as? Bool ?? false
        self.interactionMode = RoomUser.parseInteractionMode(from: dict, isBot: self.isBot)
        self.hasAudioControls = dict["hasAudioControls"] as? Bool ?? (self.isBot ? self.interactionMode.supportsAudio : true)
        self.statusMessage = dict["statusMessage"] as? String
            ?? dict["botStatus"] as? String
            ?? dict["statusText"] as? String
        self.joinedAt = RoomUser.parseDate(
            dict["joinedAt"] ?? dict["joined"] ?? dict["joinedAtUtc"] ?? dict["joinTime"]
        )
        self.lastActiveAt = RoomUser.parseDate(
            dict["lastActiveAt"] ?? dict["lastActive"] ?? dict["lastSeen"] ?? dict["lastActivity"]
        )
        if let avatarString = dict["avatarUrl"] as? String
            ?? dict["avatarURL"] as? String
            ?? dict["avatar"] as? String
            ?? dict["profileImageUrl"] as? String {
            self.avatarURL = URL(string: avatarString)
        } else {
            self.avatarURL = nil
        }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        switch value {
        case let date as Date:
            return date
        case let seconds as TimeInterval:
            if seconds > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: seconds / 1000)
            }
            return Date(timeIntervalSince1970: seconds)
        case let number as NSNumber:
            let raw = number.doubleValue
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            return Date(timeIntervalSince1970: raw)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if let interval = TimeInterval(trimmed) {
                if interval > 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: interval / 1000)
                }
                return Date(timeIntervalSince1970: interval)
            }
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFormatter.date(from: trimmed) {
                return date
            }
            isoFormatter.formatOptions = [.withInternetDateTime]
            return isoFormatter.date(from: trimmed)
        default:
            return nil
        }
    }

    private static func parseInteractionMode(from dict: [String: Any], isBot: Bool) -> InteractionMode {
        let rawValue = (
            dict["interactionMode"] as? String
            ?? dict["botType"] as? String
            ?? dict["botCapability"] as? String
            ?? dict["mediaCapability"] as? String
            ?? dict["capabilityType"] as? String
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

        switch rawValue {
        case "audio":
            return .audio
        case "text+audio", "text_audio", "audio+text", "audio_text", "both":
            return .textAndAudio
        case "text":
            return .text
        default:
            return isBot ? .text : .textAndAudio
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let roomLeft = Notification.Name("roomLeft")
    static let jellyfinWebhookEvent = Notification.Name("jellyfinWebhookEvent")
    static let jellyfinMediaStreamStarted = Notification.Name("jellyfinMediaStreamStarted")
    static let jellyfinMediaStreamStopped = Notification.Name("jellyfinMediaStreamStopped")
}
