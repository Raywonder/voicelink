import Foundation
import SocketIO
import AVFoundation
import CoreAudio

private enum VoiceLinkDesktopAudioTransport {
    static let targetSampleRate = 48_000.0
    static let preferredChannels: AVAudioChannelCount = 2
    static let frameSize: AVAudioFrameCount = 960
    static let pcmCodec = "pcm-f32"
    static let preferredCodec = "opus"
    static let engine = "apple-avengine-miniaudio-ready"

    static var audioMode: String {
        UserDefaults.standard.string(forKey: "audioMode") ?? "original"
    }

    static func capabilityPayload(sampleRate: Double = targetSampleRate, channels: AVAudioChannelCount = preferredChannels) -> [String: Any] {
        [
            "enabled": true,
            "sampleRate": sampleRate > 0 ? sampleRate : targetSampleRate,
            "channels": Int(max(1, channels)),
            "codec": pcmCodec,
            "preferredCodec": preferredCodec,
            "engine": engine,
            "audioMode": audioMode,
            "supportsStereo": true,
            "supportsOpus": true,
            "supportsDynamicProcessing": true
        ]
    }
}

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
    @Published var currentUserId: String?

    // Server options
    static let mainServer = APIEndpointResolver.canonicalMainBase
    static let localServer = APIEndpointResolver.localBase

    private var currentServerURL: String = ""
    private var useMainServer: Bool = true
    private var domainRecoveryTimer: Timer?
    private var backendRefreshTimer: Timer?
    private let incomingAudioQueue = DispatchQueue(label: "voicelink.incoming-audio", qos: .userInitiated)
    private let audioStartQueue = DispatchQueue(label: "voicelink.audio-start", qos: .userInitiated)
    private var pendingAudioStartWorkItem: DispatchWorkItem?
    private var pendingJoinRoomId: String?
    private var pendingJoinTimeoutWorkItem: DispatchWorkItem?
    private var roomStreamPlayer: AVPlayer?
    private var currentRoomStreamURL: URL?
    private var currentRoomStreamTitle: String?
    private var roomStreamDidStopExplicitly = false
    private var roomStreamKeepAliveTimer: Timer?
    private var roomStreamEndObserver: NSObjectProtocol?
    private var roomStreamFadeTimer: Timer?
    private var roomStreamFadeDuration: TimeInterval = 1.5
    private let defaultRoomStreamURLString = "https://chrismixradio.com"
    private let roomStreamDefaultVolume: Float = 0.12
    private var registeredSocketSession = false
    private var pendingSessionRegistrationWorkItem: DispatchWorkItem?
    private var awaitingDeviceApproval = false
    private var recentRoomJoinSoundKeys: [String: Date] = [:]
    private var recentUserJoinSoundKeys: [String: Date] = [:]
    private var recentRoomMessageKeys: [String: Date] = [:]
    @Published var currentRoomMediaVolume: Float = 0.12
    @Published private(set) var currentRoomMediaMuted: Bool = false

    struct CurrentRoomMediaState {
        let active: Bool
        let streamURL: String
        let title: String?
    }

    // Public accessor for the current server URL
    var baseURL: String? {
        currentServerURL.isEmpty ? nil : currentServerURL
    }

    var currentRoomMedia: CurrentRoomMediaState? {
        guard let url = currentRoomStreamURL,
              let player = roomStreamPlayer,
              player.currentItem != nil,
              activeRoomId != nil else { return nil }
        let activePlayback = player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        return CurrentRoomMediaState(
            active: activePlayback,
            streamURL: url.absoluteString,
            title: currentRoomStreamTitle
        )
    }

    var isCurrentRoomMediaMuted: Bool {
        currentRoomMediaMuted
    }

    var isCurrentRoomMediaPlaying: Bool {
        guard let player = roomStreamPlayer,
              player.currentItem != nil,
              activeRoomId != nil else { return false }
        return player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    init() {
        // Leave unresolved until the first connect attempt picks the best server.
        self.currentServerURL = ""
        setupMessageNotifications()
    }

    private func setupMessageNotifications() {
        // Listen for outgoing messages from MessagingManager
        NotificationCenter.default.addObserver(
            forName: .sendMessageToServer,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let data = notification.userInfo else { return }
            let messageId = data["messageId"] as? String
            let content = data["content"] as? String ?? ""
            let isDirect = data["isDirect"] as? Bool ?? false
            let recipientId = data["recipientId"] as? String
            let replyToId = data["replyToId"] as? String
            let mentions = data["mentions"] as? [String]
            let roomId = data["roomId"] as? String
            let messageType = data["type"] as? String ?? "text"
            let userName = UserDefaults.standard.string(forKey: "voicelink.userName")
                ?? UserDefaults.standard.string(forKey: "username")
                ?? AuthenticationManager.shared.currentUser?.username
                ?? "User"

            if isDirect, let recipient = recipientId {
                // Direct message
                var msgData: [String: Any] = [
                    "targetUserId": recipient,
                    "message": content,
                    "content": content,
                    "type": messageType,
                    "userName": userName
                ]
                if let messageId {
                    msgData["messageId"] = messageId
                }
                if let reply = replyToId {
                    msgData["replyTo"] = reply
                }
                if let mentions, !mentions.isEmpty {
                    msgData["mentions"] = mentions
                }
                self?.socket?.emit("direct-message", msgData)
            } else {
                // Room message
                var msgData: [String: Any] = [
                    "message": content,
                    "content": content,
                    "type": messageType,
                    "userName": userName
                ]
                if let roomId, !roomId.isEmpty {
                    msgData["roomId"] = roomId
                }
                if let messageId {
                    msgData["messageId"] = messageId
                }
                if let reply = replyToId {
                    msgData["replyTo"] = reply
                }
                if let mentions, !mentions.isEmpty {
                    msgData["mentions"] = mentions
                }
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

    private func socketDictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            return dict
        }
        if let dict = value as? [AnyHashable: Any] {
            var normalized: [String: Any] = [:]
            for (key, value) in dict {
                normalized[String(describing: key)] = value
            }
            return normalized
        }
        if let dict = value as? NSDictionary {
            var normalized: [String: Any] = [:]
            for (key, value) in dict {
                normalized[String(describing: key)] = value
            }
            return normalized
        }
        return nil
    }

    private func socketArrayDictionaryValue(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }
        if let array = value as? [NSDictionary] {
            return array.compactMap { $0 as? [String: Any] }
        }
        if let array = value as? [Any] {
            return array.compactMap { socketDictionaryValue($0) }
        }
        return []
    }

    private func normalizedIncomingChatPayload(_ msgData: [String: Any], fallbackRoomId: String?) -> [String: Any]? {
        let room = socketDictionaryValue(msgData["room"])
        let sender = socketDictionaryValue(msgData["sender"])
        let messageId = msgData["id"] as? String
            ?? msgData["messageId"] as? String
            ?? msgData["_id"] as? String
            ?? UUID().uuidString
        let senderId = msgData["userId"] as? String
            ?? msgData["senderId"] as? String
            ?? sender?["id"] as? String
            ?? sender?["userId"] as? String
            ?? ""
        let senderName = msgData["userName"] as? String
            ?? msgData["senderName"] as? String
            ?? msgData["author"] as? String
            ?? msgData["name"] as? String
            ?? sender?["name"] as? String
            ?? sender?["displayName"] as? String
            ?? "Unknown"
        let content = msgData["message"] as? String
            ?? msgData["content"] as? String
            ?? msgData["body"] as? String
            ?? msgData["text"] as? String
            ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let messageType = msgData["type"] as? String
            ?? msgData["messageType"] as? String
            ?? ((senderId.lowercased().hasPrefix("system") || senderName.lowercased() == "system") ? "system" : "text")
        let roomId = msgData["roomId"] as? String
            ?? room?["roomId"] as? String
            ?? room?["id"] as? String
            ?? fallbackRoomId

        return [
            "messageId": messageId,
            "senderId": senderId,
            "senderName": senderName,
            "content": content,
            "type": messageType,
            "roomId": roomId as Any,
            "mentions": msgData["mentions"] as? [String] ?? [],
            "isBot": msgData["isBot"] as? Bool ?? senderId.lowercased().hasPrefix("bot:"),
            "hasAudioControls": msgData["hasAudioControls"] as? Bool ?? false,
            "authProvider": msgData["authProvider"] as? String ?? "",
            "transcript": msgData["transcript"] as? Bool ?? false,
            "transcriptUserName": msgData["transcriptUserName"] as? String ?? "",
            "replyToId": msgData["replyToId"] as? String ?? msgData["replyTo"] as? String ?? ""
        ]
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
        // Try local server first, fallback to main/federated endpoints.
        print("Connecting to local server (primary)...")
        connect(toMain: false)

        // Set up a timeout to try the main/federated path if local fails.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if !self.isConnected && !self.useMainServer {
                print("Local server not available, trying main server...")
                self.connect(toMain: true)
            }
        }
    }

    func tryMainThenLocal() {
        // Try main/federated endpoints first, fallback to local.
        print("Connecting to main server (primary)...")
        connect(toMain: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if !self.isConnected && self.useMainServer {
                print("Main server not available, trying local server...")
                self.connect(toMain: false)
            }
        }
    }

    func disconnect() {
        socket?.disconnect()
        stopDomainRecoveryTimer()
        stopBackendRefreshTimer()
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
            .reconnectAttempts(10_000)
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
            .reconnectAttempts(10_000),
            .secure(serverURL.hasPrefix("https"))
        ])

        socket = manager?.defaultSocket

        setupEventHandlers()
        socket?.connect()
    }

    private func resolveBestMainServer() async -> String {
        let candidates = APIEndpointResolver.remoteMainBaseCandidates(preferred: currentServerURL)
        for candidate in candidates {
            if await isReachableServer(candidate) {
                return candidate
            }
        }

        await requestMainServerStart(candidates: candidates)

        for candidate in candidates {
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

    private func requestMainServerStart(candidates: [String]) async {
        let normalizedCandidates = Array(Set(candidates.map { APIEndpointResolver.normalize($0) }))
        for base in normalizedCandidates {
            for path in ["/api/service/voicelink/start", "/api/admin/start"] {
                guard let url = APIEndpointResolver.url(base: base, path: path) else { continue }
                var request = URLRequest(url: url)
                request.timeoutInterval = 4
                request.httpMethod = "POST"
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                        print("Requested PM2/API start via \(url.absoluteString)")
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        return
                    }
                } catch {
                    continue
                }
            }
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

    private func startBackendRefreshTimer() {
        stopBackendRefreshTimer()
        backendRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            self.getRooms()
            if let activeRoomId = self.activeRoomId {
                self.socket?.emit("get-room-users", ["roomId": activeRoomId])
                self.socket?.emit("get-room-messages", ["roomId": activeRoomId, "limit": 200])
            }
        }
    }

    private func stopBackendRefreshTimer() {
        backendRefreshTimer?.invalidate()
        backendRefreshTimer = nil
    }

    func refreshActiveRoomState(reason: String = "manual") {
        guard let activeRoomId else { return }
        refreshRoomState(roomId: activeRoomId, reason: reason)
    }

    private func refreshRoomState(roomId: String, reason: String) {
        let trimmedRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoomId.isEmpty else { return }
        socket?.emit("get-room-users", ["roomId": trimmedRoomId, "reason": reason])
        socket?.emit("get-room-messages", ["roomId": trimmedRoomId, "limit": 200, "reason": reason])
    }

    private func shouldPlayRoomJoinSound(roomId: String) -> Bool {
        let key = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let now = Date()
        recentRoomJoinSoundKeys = recentRoomJoinSoundKeys.filter { now.timeIntervalSince($0.value) < 10 }
        if let lastPlayed = recentRoomJoinSoundKeys[key],
           now.timeIntervalSince(lastPlayed) < 3 {
            return false
        }
        recentRoomJoinSoundKeys[key] = now
        return true
    }

    private func shouldPlayUserJoinSound(for user: RoomUser, roomId: String?) -> Bool {
        if isLikelyLocalMessage(senderId: user.odId, senderName: user.username) {
            return false
        }
        let roomKey = roomId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? activeRoomId ?? "room"
        let key = "\(roomKey)|\(user.id)"
        let now = Date()
        recentUserJoinSoundKeys = recentUserJoinSoundKeys.filter { now.timeIntervalSince($0.value) < 10 }
        if let lastPlayed = recentUserJoinSoundKeys[key],
           now.timeIntervalSince(lastPlayed) < 3 {
            return false
        }
        recentUserJoinSoundKeys[key] = now
        return true
    }

    private func shouldPostRoomMessage(_ payload: [String: Any]) -> Bool {
        let messageId = (payload["messageId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let roomId = (payload["roomId"] as? String ?? activeRoomId ?? "room").trimmingCharacters(in: .whitespacesAndNewlines)
        let senderId = (payload["senderId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let content = (payload["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = !messageId.isEmpty ? "\(roomId)|id|\(messageId)" : "\(roomId)|body|\(senderId)|\(content)"
        let now = Date()
        recentRoomMessageKeys = recentRoomMessageKeys.filter { now.timeIntervalSince($0.value) < 300 }
        if let previous = recentRoomMessageKeys[key], now.timeIntervalSince(previous) < 300 {
            return false
        }
        recentRoomMessageKeys[key] = now
        return true
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
            self.registeredSocketSession = false
            self.awaitingDeviceApproval = false
            self.registerAuthenticatedSessionIfNeeded()
            self.scheduleSessionRegistrationRetry()
            self.scheduleDomainRecoveryIfNeeded()
            self.startBackendRefreshTimer()
            // Request room list after connecting
            self.getRooms()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, ack in
            print("Disconnected from server")
            self?.stopDomainRecoveryTimer()
            self?.stopBackendRefreshTimer()
            self?.cancelPendingSessionRegistrationRetry()
            self?.registeredSocketSession = false
            self?.awaitingDeviceApproval = false
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.serverStatus = "Disconnected"
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

        socket.on("auth_success") { [weak self] data, ack in
            print("Socket session registered: \(data)")
            self?.cancelPendingSessionRegistrationRetry()
            self?.registeredSocketSession = true
            self?.awaitingDeviceApproval = false
            DispatchQueue.main.async {
                DeviceRevocationManager.shared.markCurrentDeviceOnline()
                if let serverURL = self?.baseURL ?? self?.currentServerURL, !serverURL.isEmpty {
                    DeviceRevocationManager.shared.fetchDevices(serverURL: serverURL)
                }
                NotificationCenter.default.post(name: .serverConnectionChanged, object: nil)
            }
            self?.rejoinActiveRoomIfNeeded()
        }

        socket.on("auth_failed") { [weak self] data, ack in
            print("Socket session registration failed: \(data)")
            self?.registeredSocketSession = false
            self?.awaitingDeviceApproval = false
            let message = (data.first as? [String: Any])?["message"] as? String
                ?? (data.first as? String)
                ?? "Authentication required"
            let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            DispatchQueue.main.async {
                if AuthenticationManager.shared.currentUser == nil {
                    self?.errorMessage = message
                } else if normalizedMessage.contains("invalid or expired whmcs session") {
                    AuthenticationManager.shared.authError = "Your client portal session expired. Sign in again."
                    AuthenticationManager.shared.logout()
                    self?.errorMessage = "Your client portal session expired. Sign in again."
                } else {
                    self?.errorMessage = message
                }
            }
        }

        socket.on("auth_token_refreshed") { data, ack in
            guard let payload = data.first as? [String: Any],
                  let token = payload["token"] as? String else {
                return
            }
            DispatchQueue.main.async {
                AuthenticationManager.shared.updateCurrentUserAccessToken(token)
            }
        }

        socket.on("device-approval-request") { data, ack in
            guard let payload = data.first as? [String: Any] else { return }
            NotificationCenter.default.post(name: .deviceApprovalRequested, object: nil, userInfo: payload)
            DispatchQueue.main.async {
                DeviceRevocationManager.shared.fetchPendingApprovals()
            }
        }

        socket.on("device-approval-pending") { [weak self] data, ack in
            guard let payload = data.first as? [String: Any] else { return }
            self?.cancelPendingSessionRegistrationRetry()
            self?.awaitingDeviceApproval = true
            NotificationCenter.default.post(name: .deviceApprovalPending, object: nil, userInfo: payload)
            DispatchQueue.main.async {
                self?.errorMessage = "This sign-in is waiting for approval from another trusted device."
            }
        }

        socket.on("device-approval-approved") { [weak self] data, ack in
            guard let payload = data.first as? [String: Any] else { return }
            self?.awaitingDeviceApproval = false
            NotificationCenter.default.post(name: .deviceApprovalApproved, object: nil, userInfo: payload)
            NotificationCenter.default.post(name: .deviceApprovalResolved, object: nil, userInfo: payload)
        }

        socket.on("device-approval-denied") { [weak self] data, ack in
            guard let payload = data.first as? [String: Any] else { return }
            self?.cancelPendingSessionRegistrationRetry()
            self?.awaitingDeviceApproval = false
            NotificationCenter.default.post(name: .deviceApprovalDenied, object: nil, userInfo: payload)
            NotificationCenter.default.post(name: .deviceApprovalResolved, object: nil, userInfo: payload)
            DispatchQueue.main.async {
                self?.errorMessage = payload["reason"] as? String ?? "Sign-in was denied by another trusted device."
            }
        }

        socket.on("device-approval-expired") { [weak self] data, ack in
            guard let payload = data.first as? [String: Any] else { return }
            self?.cancelPendingSessionRegistrationRetry()
            self?.awaitingDeviceApproval = false
            NotificationCenter.default.post(name: .deviceApprovalExpired, object: nil, userInfo: payload)
            NotificationCenter.default.post(name: .deviceApprovalResolved, object: nil, userInfo: payload)
            DispatchQueue.main.async {
                self?.errorMessage = payload["reason"] as? String ?? "Sign-in approval request expired."
            }
        }

        socket.on("device-approval-resolved") { data, ack in
            guard let payload = data.first as? [String: Any] else { return }
            NotificationCenter.default.post(name: .deviceApprovalResolved, object: nil, userInfo: payload)
            DispatchQueue.main.async {
                DeviceRevocationManager.shared.fetchPendingApprovals()
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
            let responseData = self.socketDictionaryValue(data.first) ?? [:]
            let roomData = self.socketDictionaryValue(responseData["room"]) ?? responseData
            let joinedUserData = self.socketDictionaryValue(responseData["user"])

            let usersData = self.socketArrayDictionaryValue(roomData["users"]).isEmpty
                ? self.socketArrayDictionaryValue(responseData["users"])
                : self.socketArrayDictionaryValue(roomData["users"])
            if !usersData.isEmpty {
                let users = usersData.compactMap { RoomUser(from: $0) }
                DispatchQueue.main.async {
                    self.currentRoomUsers = users
                }
            }

            if let joinedUserId = joinedUserData?["id"] as? String ?? joinedUserData?["odId"] as? String {
                DispatchQueue.main.async {
                    self.currentUserId = joinedUserId
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
                self.refreshRoomState(roomId: roomId, reason: "join-event")
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
            if let roomId, self.shouldPlayRoomJoinSound(roomId: roomId) {
                AppSoundManager.shared.playSound(.userJoin)
            }
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
            if let self,
               let userData = self.socketDictionaryValue(data.first),
               let user = RoomUser(from: userData) {
                DispatchQueue.main.async {
                    if !self.currentRoomUsers.contains(where: { $0.id == user.id }) {
                        self.currentRoomUsers.append(user)
                        if self.shouldPlayUserJoinSound(for: user, roomId: self.activeRoomId) {
                            AppSoundManager.shared.playSound(.userJoin)
                            AccessibilityManager.shared.announceUserJoined(user.username)
                        }
                    }
                }
            }
        }

        // User left room
        socket.on("user-left") { [weak self] data, ack in
            print("User left: \(data)")
            if let self,
               let userData = self.socketDictionaryValue(data.first) {
                let userId = (userData["userId"] as? String ?? userData["odId"] as? String ?? userData["id"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !userId.isEmpty else { return }
                DispatchQueue.main.async {
                    // Get username before removing for announcement
                    let userName = self.currentRoomUsers.first(where: { $0.id == userId || $0.odId == userId })?.username
                    self.currentRoomUsers.removeAll { $0.id == userId || $0.odId == userId }
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
            if let self,
               let responseData = self.socketDictionaryValue(data.first) {
                let usersData = self.socketArrayDictionaryValue(responseData["users"])
                let users = usersData.compactMap { RoomUser(from: $0) }
                DispatchQueue.main.async {
                    self.currentRoomUsers = users
                }
            }
        }

        // Room user count update (broadcast when users join/leave)
        socket.on("room-user-count") { [weak self] data, ack in
            print("Room user count update: \(data)")
            if let self,
               let responseData = self.socketDictionaryValue(data.first) {
                let usersData = self.socketArrayDictionaryValue(responseData["users"])
                let users = usersData.compactMap { RoomUser(from: $0) }
                DispatchQueue.main.async {
                    self.currentRoomUsers = users
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
            if let msgData = self.socketDictionaryValue(data.first),
               let messagePayload = self.normalizedIncomingChatPayload(msgData, fallbackRoomId: self.activeRoomId) {
                guard self.shouldPostRoomMessage(messagePayload) else { return }
                let senderId = messagePayload["senderId"] as? String ?? ""
                let senderName = messagePayload["senderName"] as? String ?? "Unknown"
                let content = messagePayload["content"] as? String ?? ""
                let messageType = messagePayload["type"] as? String ?? "text"
                let roomId = messagePayload["roomId"] as? String ?? self.activeRoomId
                self.announceLiveRoomMessage(
                    senderId: senderId,
                    senderName: senderName,
                    content: content,
                    messageType: messageType,
                    roomId: roomId
                )

                NotificationCenter.default.post(
                    name: .incomingChatMessage,
                    object: nil,
                    userInfo: messagePayload
                )
            }
        }

        socket.on("room-messages") { data, ack in
            guard let responseData = self.socketDictionaryValue(data.first) else { return }
            let messages = self.socketArrayDictionaryValue(responseData["messages"])
            let roomId = responseData["roomId"] as? String ?? self.activeRoomId
            for msgData in messages {
                guard var messagePayload = self.normalizedIncomingChatPayload(msgData, fallbackRoomId: roomId) else { continue }
                guard self.shouldPostRoomMessage(messagePayload) else { continue }
                messagePayload["historical"] = true

                NotificationCenter.default.post(
                    name: .incomingChatMessage,
                    object: nil,
                    userInfo: messagePayload
                )
            }
        }

        socket.on("room-transcript") { data, ack in
            guard let payload = data.first as? [String: Any] else { return }
            let roomId = payload["roomId"] as? String ?? self.activeRoomId ?? ""
            let userId = payload["userId"] as? String ?? ""
            let userName = payload["userName"] as? String ?? "Live Transcript"
            let text = payload["text"] as? String ?? ""
            guard !roomId.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            NotificationCenter.default.post(
                name: .roomTranscriptReceived,
                object: nil,
                userInfo: [
                    "roomId": roomId,
                    "userId": userId,
                    "userName": userName,
                    "text": text,
                    "language": payload["language"] as? String ?? ""
                ]
            )
        }

        socket.on("bot-audio") { data, ack in
            guard let payload = data.first as? [String: Any] else { return }
            NotificationCenter.default.post(
                name: .botAudioReceived,
                object: nil,
                userInfo: payload
            )
        }

        // Direct message received
        socket.on("direct-message") { data, ack in
            print("Direct message received: \(data)")
            if let msgData = data[0] as? [String: Any] {
                let senderId = msgData["senderId"] as? String ?? ""
                let senderName = msgData["senderName"] as? String ?? "Unknown"
                let content = msgData["message"] as? String ?? msgData["content"] as? String ?? ""
                self.announceLiveDirectMessage(
                    senderId: senderId,
                    senderName: senderName,
                    content: content
                )

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
                self.roomStreamDidStopExplicitly = false
                self.startRoomStreamPlayback(from: streamUrl, title: mediaTitle)
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
            self.currentRoomStreamTitle = mediaTitle
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

        socket.on("room-media-updated") { data, ack in
            let payload = (data.first as? [String: Any]) ?? [:]
            let roomId = (payload["roomId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !roomId.isEmpty else { return }
            if self.activeRoomId == roomId {
                let payloadHasPlayableMedia = !((payload["streamUrl"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    || !((payload["backgroundStream"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    || ((payload["active"] as? Bool) == true)
                    || ((payload["playing"] as? Bool) == true)
                if payloadHasPlayableMedia {
                    self.roomStreamDidStopExplicitly = false
                }
                self.fetchActiveRoomStream(for: roomId)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .jellyfinWebhookEvent,
                    object: nil,
                    userInfo: [
                        "title": "Room media updated",
                        "message": "Room media changed for the current room.",
                        "eventType": "room-media-updated",
                        "payload": payload
                    ]
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
            self?.socket?.emit("enable-audio-relay", VoiceLinkDesktopAudioTransport.capabilityPayload())
        }
    }

    private func announceLiveRoomMessage(senderId: String, senderName: String, content: String, messageType: String, roomId: String?) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }
        if let roomId = roomId?.trimmingCharacters(in: .whitespacesAndNewlines),
           let activeRoomId = activeRoomId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !roomId.isEmpty,
           !activeRoomId.isEmpty,
           roomId != activeRoomId {
            return
        }
        if isLikelyLocalMessage(senderId: senderId, senderName: senderName) {
            return
        }

        let normalizedType = messageType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedSender = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        if normalizedType == "system" {
            prefix = resolvedSender.isEmpty || resolvedSender == "Unknown" ? "System" : resolvedSender
        } else if normalizedType == "bot" {
            prefix = resolvedSender.isEmpty || resolvedSender == "Unknown" ? "VoiceLink bot" : resolvedSender
        } else {
            prefix = resolvedSender.isEmpty || resolvedSender == "Unknown" ? "Message" : "\(resolvedSender) says"
        }
        AccessibilityManager.shared.announce("\(prefix). \(trimmedContent)", priority: .polite, category: .roomEvents)
    }

    private func announceLiveDirectMessage(senderId: String, senderName: String, content: String) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty, !isLikelyLocalMessage(senderId: senderId, senderName: senderName) else { return }
        let resolvedSender = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = resolvedSender.isEmpty || resolvedSender == "Unknown" ? "Direct message" : "Direct message from \(resolvedSender)"
        AccessibilityManager.shared.announce("\(prefix). \(trimmedContent)", priority: .polite, category: .roomEvents)
    }

    private func isLikelyLocalMessage(senderId: String, senderName: String) -> Bool {
        let normalizedSenderId = senderId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSenderName = senderName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCurrentUserId = (currentUserId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedSenderId.isEmpty, !normalizedCurrentUserId.isEmpty, normalizedSenderId == normalizedCurrentUserId {
            return true
        }
        let localNames = [
            UserDefaults.standard.string(forKey: "voicelink.displayName"),
            UserDefaults.standard.string(forKey: "voicelink.accountDisplayName"),
            UserDefaults.standard.string(forKey: "voicelink.userName")
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
        return !normalizedSenderName.isEmpty && localNames.contains(normalizedSenderName)
    }

    func syncAuthenticatedSession() {
        guard isConnected else { return }
        registeredSocketSession = false
        registerAuthenticatedSessionIfNeeded()
        scheduleSessionRegistrationRetry()
    }

    private func registerAuthenticatedSessionIfNeeded() {
        guard isConnected, !registeredSocketSession else { return }
        guard let socket else { return }
        guard let currentUser = AuthenticationManager.shared.currentUser else { return }

        let provider = normalizedSessionProvider(for: currentUser)
        var payload: [String: Any] = [
            "provider": provider,
            "token": currentUser.accessToken,
            "deviceId": currentDeviceIdentifier(),
            "deviceName": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            "deviceType": "macos",
            "clientVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "appVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            "timeZone": TimeZone.current.identifier,
            "locale": Locale.current.identifier
        ]

        payload["user"] = [
            "id": currentUser.id,
            "accountId": currentUser.accountId as Any,
            "canonicalAccountId": currentUser.canonicalAccountId as Any,
            "linkedLocalUserId": currentUser.linkedLocalUserId as Any,
            "username": currentUser.username,
            "displayName": currentUser.displayName,
            "email": currentUser.email as Any,
            "canonicalEmail": currentUser.canonicalEmail as Any,
            "role": currentUser.role as Any,
            "permissions": currentUser.permissions,
            "authProvider": currentUser.authProvider ?? provider,
            "contactCard": currentUser.contactCard.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as Any,
            "lastLoginAt": currentUser.lastLoginAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
            "lastSeenAt": currentUser.lastSeenAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
            "lastActiveAt": currentUser.lastActiveAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
            "presence": currentUser.presence
        ]

        socket.emit("register-session", payload)
    }

    private func scheduleSessionRegistrationRetry(attempt: Int = 1) {
        cancelPendingSessionRegistrationRetry()
        guard attempt <= 5 else { return }
        guard isConnected, !registeredSocketSession, !awaitingDeviceApproval else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.isConnected, !self.registeredSocketSession, !self.awaitingDeviceApproval else { return }
            self.registerAuthenticatedSessionIfNeeded()
            self.scheduleSessionRegistrationRetry(attempt: attempt + 1)
        }
        pendingSessionRegistrationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func cancelPendingSessionRegistrationRetry() {
        pendingSessionRegistrationWorkItem?.cancel()
        pendingSessionRegistrationWorkItem = nil
    }

    private func normalizedSessionProvider(for user: AuthenticatedUser) -> String {
        let preferred = (user.authProvider ?? user.authMethod.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch preferred {
        case "mastodon":
            return "mastodon"
        case "whmcs":
            return "whmcs"
        case "local", "email", "admin_invite":
            return "email"
        default:
            switch user.authMethod {
            case .mastodon:
                return "mastodon"
            case .discord:
                return "discord"
            case .whmcs:
                return "whmcs"
            case .email, .adminInvite:
                return "email"
            case .pairingCode:
                return "email"
            }
        }
    }

    private func currentDeviceIdentifier() -> String {
        if let existing = UserDefaults.standard.string(forKey: "device_identifier"),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }
        let generated = UUID().uuidString.prefix(12).description
        UserDefaults.standard.set(generated, forKey: "device_identifier")
        return generated
    }

    private func currentPreferredJoinName() -> String {
        let candidates = [
            AuthenticationManager.shared.currentUser?.displayName,
            AuthenticationManager.shared.currentUser?.username,
            UserDefaults.standard.string(forKey: "guestName"),
            Host.current().localizedName
        ]
        for candidate in candidates {
            let trimmed = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "VoiceLink User"
    }

    private func rejoinActiveRoomIfNeeded() {
        guard let activeRoomId, !activeRoomId.isEmpty else { return }
        let joinName = currentPreferredJoinName()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            guard self.isConnected, self.registeredSocketSession else { return }
            self.joinRoom(roomId: activeRoomId, username: joinName)
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
                username: self.usernameForRoomUser(userId: userId),
                data: audioBuffer,
                timestamp: timestamp,
                sampleRate: sampleRate,
                channels: audioInfo["channels"] as? Int
            )
        }
    }

    private func usernameForRoomUser(userId: String) -> String {
        currentRoomUsers.first(where: { $0.id == userId || $0.odId == userId })?.username ?? userId
    }

    func createRoom(
        name: String,
        description: String,
        isPrivate: Bool,
        password: String? = nil,
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
            if let joinedUserData = payload["user"] as? [String: Any],
               let joinedUserId = joinedUserData["id"] as? String ?? joinedUserData["odId"] as? String {
                self.currentUserId = joinedUserId
            }
        }
        fetchActiveRoomStream(for: joinedRoomId)
        refreshRoomState(roomId: joinedRoomId, reason: "join-ack")
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
                    String(room.botCount),
                    String(room.totalVisible),
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
        let mergedWelcomeMessage: String? = {
            let left = primary.welcomeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let right = incoming.welcomeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if right.count > left.count { return right.isEmpty ? nil : right }
            return left.isEmpty ? nil : left
        }()

        let mergedCreatedBy = (primary.createdBy?.isEmpty == false ? primary.createdBy : incoming.createdBy)
        let mergedCreatedByRole = (primary.createdByRole?.isEmpty == false ? primary.createdByRole : incoming.createdByRole)
        let mergedRoomType = (primary.roomType?.isEmpty == false ? primary.roomType : incoming.roomType)
        let mergedHostServerName = (primary.hostServerName?.isEmpty == false ? primary.hostServerName : incoming.hostServerName)
        let mergedHostServerOwner = (primary.hostServerOwner?.isEmpty == false ? primary.hostServerOwner : incoming.hostServerOwner)
        let mergedLockedBy = (primary.lockedBy?.isEmpty == false ? primary.lockedBy : incoming.lockedBy)

        return ServerRoom(
            id: primary.id,
            name: primary.name.isEmpty ? incoming.name : primary.name,
            description: mergedDescription,
            welcomeMessage: mergedWelcomeMessage,
            liveBroadcast: primary.liveBroadcast ?? incoming.liveBroadcast,
            userCount: max(primary.userCount, incoming.userCount),
            botCount: max(primary.botCount, incoming.botCount),
            totalVisible: max(primary.totalVisible, incoming.totalVisible, max(primary.userCount + primary.botCount, incoming.userCount + incoming.botCount)),
            isPrivate: primary.isPrivate || incoming.isPrivate,
            isLocked: primary.isLocked || incoming.isLocked,
            recordingAllowed: primary.recordingAllowed || incoming.recordingAllowed,
            maxUsers: max(primary.maxUsers, incoming.maxUsers),
            createdBy: mergedCreatedBy,
            createdByRole: mergedCreatedByRole,
            roomType: mergedRoomType,
            createdAt: primary.createdAt ?? incoming.createdAt,
            uptimeSeconds: max(primary.uptimeSeconds ?? 0, incoming.uptimeSeconds ?? 0),
            lastActiveUsername: preferIncoming ? (incoming.lastActiveUsername ?? primary.lastActiveUsername) : (primary.lastActiveUsername ?? incoming.lastActiveUsername),
            lastActivityAt: max(primaryDate, incomingDate) == .distantPast ? nil : max(primaryDate, incomingDate),
            hostServerName: mergedHostServerName,
            hostServerOwner: mergedHostServerOwner,
            lockedBy: mergedLockedBy
        )
    }

    func leaveRoom() {
        cancelJoinTimeout()
        pendingJoinRoomId = nil
        pendingAudioStartWorkItem?.cancel()
        pendingAudioStartWorkItem = nil
        let leftRoomId = activeRoomId
        socket?.emit("leave-room")
        stopAudioTransmission()
        stopRoomStreamPlayback(explicit: true)
        DispatchQueue.main.async {
            self.currentRoomUsers = []
            self.activeRoomId = nil
            self.currentUserId = nil
            self.recentRoomMessageKeys.removeAll()
        }
        NotificationCenter.default.post(name: .roomLeft, object: nil, userInfo: ["roomId": leftRoomId as Any])
    }

    private func fetchActiveRoomStream(for roomId: String) {
        guard !roomStreamDidStopExplicitly else {
            stopRoomStreamPlayback(explicit: false)
            return
        }
        guard let encodedRoomId = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(currentServerURL)/api/jellyfin/room-stream/\(encodedRoomId)") else {
            stopRoomStreamPlayback(explicit: false)
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data else {
                self.stopRoomStreamPlayback(explicit: false)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.stopRoomStreamPlayback(explicit: false)
                return
            }
            let isActive = json["active"] as? Bool ?? false
            guard isActive, let streamUrl = json["streamUrl"] as? String else {
                self.stopRoomStreamPlayback(explicit: false)
                return
            }
            let mediaTitle = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let volumeValue = json["volume"] as? NSNumber {
                let normalizedVolume = min(max(volumeValue.floatValue / 100.0, 0), 1.5)
                DispatchQueue.main.async {
                    self.currentRoomMediaVolume = normalizedVolume
                    if let player = self.roomStreamPlayer, !self.currentRoomMediaMuted {
                        player.volume = normalizedVolume
                    }
                }
            }
            self.startRoomStreamPlayback(from: streamUrl, title: mediaTitle)
        }.resume()
    }

    private func startRoomStreamPlayback(from rawURL: String, title: String? = nil) {
        guard let url = normalizedRoomStreamURL(from: rawURL) else { return }
        DispatchQueue.main.async {
            let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.currentRoomStreamTitle = trimmedTitle?.isEmpty == false ? trimmedTitle : self.currentRoomStreamTitle
            if self.currentRoomStreamURL == url, let player = self.roomStreamPlayer {
                self.roomStreamFadeTimer?.invalidate()
                self.roomStreamFadeTimer = nil
                player.volume = self.currentRoomMediaMuted ? 0 : self.currentRoomMediaVolume
                player.play()
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
                player.volume = 0
                player.play()
                if !self.currentRoomMediaMuted {
                    self.fadeRoomStreamVolume(
                        to: self.currentRoomMediaVolume,
                        duration: self.roomStreamFadeDuration
                    )
                }
            } else {
                let player = AVPlayer(playerItem: item)
                player.volume = 0
                self.roomStreamPlayer = player
                player.play()
                if !self.currentRoomMediaMuted {
                    self.fadeRoomStreamVolume(
                        to: self.currentRoomMediaVolume,
                        duration: self.roomStreamFadeDuration
                    )
                }
            }
            self.ensureRoomStreamKeepAlive()
        }
    }

    private func normalizedRoomStreamURL(from rawURL: String) -> URL? {
        guard let components = URLComponents(string: rawURL) else { return nil }
        return components.url
    }

    private func startDefaultRoomStreamIfNeeded() {
        guard !roomStreamDidStopExplicitly else { return }
        startRoomStreamPlayback(from: defaultRoomStreamURLString)
    }

    private func ensureRoomStreamKeepAlive() {
        roomStreamKeepAliveTimer?.invalidate()
        roomStreamKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.activeRoomId != nil else { return }
            guard !self.roomStreamDidStopExplicitly else { return }
            guard let player = self.roomStreamPlayer else { return }
            player.volume = self.currentRoomMediaMuted ? 0 : self.currentRoomMediaVolume
            if player.currentItem == nil, let current = self.currentRoomStreamURL {
                self.startRoomStreamPlayback(from: current.absoluteString)
                return
            }
            if player.timeControlStatus != .playing {
                player.play()
            }
        }
    }

    private func stopRoomStreamPlayback(explicit: Bool = true) {
        DispatchQueue.main.async {
            if explicit {
                self.roomStreamDidStopExplicitly = true
            }
            self.roomStreamFadeTimer?.invalidate()
            self.roomStreamFadeTimer = nil
            self.roomStreamKeepAliveTimer?.invalidate()
            self.roomStreamKeepAliveTimer = nil
            if let observer = self.roomStreamEndObserver {
                NotificationCenter.default.removeObserver(observer)
                self.roomStreamEndObserver = nil
            }
            self.roomStreamPlayer?.pause()
            self.roomStreamPlayer?.replaceCurrentItem(with: nil)
            self.currentRoomStreamURL = nil
            self.currentRoomStreamTitle = nil
            self.currentRoomMediaMuted = false
        }
    }

    func stopCurrentRoomMedia() {
        DispatchQueue.main.async {
            guard self.roomStreamPlayer != nil else {
                self.stopRoomStreamPlayback()
                return
            }
            self.roomStreamDidStopExplicitly = true
            self.fadeRoomStreamVolume(
                to: 0,
                duration: self.roomStreamFadeDuration,
                stopWhenComplete: true
            )
        }
    }

    func toggleCurrentRoomMediaMuted() {
        DispatchQueue.main.async {
            guard let player = self.roomStreamPlayer else { return }
            self.currentRoomMediaMuted.toggle()
            player.volume = self.currentRoomMediaMuted ? 0 : self.currentRoomMediaVolume
        }
    }

    func setCurrentRoomMediaVolume(_ volume: Float) {
        let clamped = min(max(volume, 0), 1.5)
        DispatchQueue.main.async {
            self.currentRoomMediaVolume = clamped
            guard let player = self.roomStreamPlayer, !self.isCurrentRoomMediaMuted else { return }
            player.volume = clamped
        }
    }

    func refreshRoomMedia(for roomId: String? = nil) {
        let targetRoomId = roomId ?? activeRoomId
        guard let targetRoomId, !targetRoomId.isEmpty else { return }
        guard !roomStreamDidStopExplicitly || targetRoomId != activeRoomId else { return }
        fetchActiveRoomStream(for: targetRoomId)
    }

    func playCurrentRoomMedia(from rawURL: String, fadeDuration: TimeInterval? = nil) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let fadeDuration {
            setRoomMediaFadeDuration(fadeDuration)
        }
        roomStreamDidStopExplicitly = false
        startRoomStreamPlayback(from: trimmed)
    }

    func setRoomMediaFadeDuration(_ duration: TimeInterval) {
        roomStreamFadeDuration = max(duration, 0.05)
    }

    private func fadeRoomStreamVolume(to target: Float, duration: TimeInterval, stopWhenComplete: Bool = false) {
        DispatchQueue.main.async {
            guard let player = self.roomStreamPlayer else {
                if stopWhenComplete {
                    self.stopRoomStreamPlayback()
                }
                return
            }

            self.roomStreamFadeTimer?.invalidate()
            self.roomStreamFadeTimer = nil

            let startingVolume = player.volume
            let clampedTarget = min(max(target, 0), 1.5)
            guard duration > 0.05 else {
                player.volume = clampedTarget
                if stopWhenComplete {
                    self.stopRoomStreamPlayback()
                }
                return
            }

            let stepInterval = 0.05
            let steps = max(Int(duration / stepInterval), 1)
            var currentStep = 0

            self.roomStreamFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
                guard let self, let player = self.roomStreamPlayer else {
                    timer.invalidate()
                    return
                }

                currentStep += 1
                let progress = min(Float(currentStep) / Float(steps), 1)
                player.volume = startingVolume + ((clampedTarget - startingVolume) * progress)

                if progress >= 1 {
                    timer.invalidate()
                    self.roomStreamFadeTimer = nil
                    if stopWhenComplete {
                        self.stopRoomStreamPlayback()
                    }
                }
            }
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

    private var audioTransmitEngine: AVAudioEngine?
    private var isTransmitting = false
    private let audioTransmissionTapBufferSize = VoiceLinkDesktopAudioTransport.frameSize

    private func scheduleAudioTransmissionStart(for roomId: String) {
        pendingAudioStartWorkItem?.cancel()
        DispatchQueue.main.async {
            if self.activeRoomId == roomId, !self.inputMuted, !self.isAudioTransmitting {
                self.audioTransmissionStatus = "Starting audio..."
            }
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.activeRoomId == roomId else { return }
                guard self.isConnected else {
                    self.audioTransmissionStatus = "Waiting for server connection"
                    return
                }
                self.startAudioTransmission()
            }
        }
        pendingAudioStartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
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
        guard let failedRoomId = pendingJoinRoomId else { return }
        cancelJoinTimeout()
        pendingJoinRoomId = nil
        let alreadyJoined = activeRoomId == failedRoomId
        DispatchQueue.main.async {
            if alreadyJoined {
                if self.isAudioTransmitting {
                    self.audioTransmissionStatus = LocalMonitorManager.shared.isMonitoring ? "Transmitting + monitoring" : "Transmitting"
                } else {
                    self.audioTransmissionStatus = "Joined room"
                }
            } else {
                self.audioTransmissionStatus = "Join failed"
                self.errorMessage = message
            }
        }
        if !alreadyJoined {
            pendingAudioStartWorkItem?.cancel()
            pendingAudioStartWorkItem = nil
        }
    }

    func startAudioTransmission() {
        audioStartQueue.async { [weak self] in
            self?.startAudioTransmissionNow()
        }
    }

    func setLocalMonitoringEnabled(_ enabled: Bool) {
        LocalMonitorManager.shared.setMonitoringEnabled(enabled)
        if enabled, isAudioTransmitting || isTransmitting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                LocalMonitorManager.shared.refreshForSharedCaptureChange(reason: "monitorEnabledDuringTransmission")
            }
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
        guard isConnected, socket != nil else {
            DispatchQueue.main.async {
                self.isAudioTransmitting = false
                self.audioTransmissionStatus = "Waiting for server connection"
            }
            return
        }
        guard activeRoomId != nil else {
            DispatchQueue.main.async {
                self.isAudioTransmitting = false
                self.audioTransmissionStatus = "Join a room to transmit"
            }
            return
        }
        guard !isTransmitting else {
            DispatchQueue.main.async {
                self.isAudioTransmitting = true
                self.audioTransmissionStatus = LocalMonitorManager.shared.isMonitoring ? "Transmitting + monitoring" : "Transmitting"
                LocalMonitorManager.shared.refreshForSharedCaptureChange(reason: "audioTransmissionAlreadyRunning")
            }
            return
        }

        // Ensure selected devices are applied before opening capture path.
        SettingsManager.shared.applySelectedAudioDevices()
        do {
            try SpatialAudioEngine.shared.start()
        } catch {
            print("[Audio] Spatial audio engine start warning: \(error)")
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        let channelCount = min(
            max(AVAudioChannelCount(1), format.channelCount),
            VoiceLinkDesktopAudioTransport.preferredChannels
        )

        socket?.emit("enable-audio-relay", VoiceLinkDesktopAudioTransport.capabilityPayload(
            sampleRate: format.sampleRate,
            channels: channelCount
        ))

        inputNode.installTap(onBus: 0, bufferSize: audioTransmissionTapBufferSize, format: format) { [weak self] buffer, time in
            guard let self = self, self.isTransmitting else { return }
            LocalMonitorManager.shared.ingestSharedTransmissionBuffer(buffer)
            let localUsername = AuthenticationManager.shared.currentUser?.displayName
                ?? AuthenticationManager.shared.currentUser?.username
                ?? "Local User"
            RecordingManager.shared.addLocalAudio(username: localUsername, buffer: buffer)

            // Convert PCM buffer to Data
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let channelsToSend = Int(min(channelCount, buffer.format.channelCount))
            let inputGain = Float(SettingsManager.shared.effectiveInputVolume)
            var scaledSamples = [Float]()
            scaledSamples.reserveCapacity(frameLength * max(1, channelsToSend))
            if channelsToSend <= 1 {
                scaledSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                if inputGain != 1 {
                    for index in scaledSamples.indices {
                        scaledSamples[index] *= inputGain
                    }
                }
            } else {
                for frame in 0..<frameLength {
                    for channelIndex in 0..<channelsToSend {
                        scaledSamples.append(channelData[channelIndex][frame] * inputGain)
                    }
                }
            }
            let data = scaledSamples.withUnsafeBufferPointer {
                Data(buffer: $0)
            }

            // Encode as base64 for Socket.IO transmission
            let base64Audio = data.base64EncodedString()

            // Send audio data to server for relay
            guard self.isConnected, self.activeRoomId != nil else { return }
            self.socket?.emit("audio-data", [
                "audioData": base64Audio,
                "timestamp": Date().timeIntervalSince1970,
                "sampleRate": format.sampleRate,
                "channels": channelsToSend,
                "codec": VoiceLinkDesktopAudioTransport.pcmCodec,
                "preferredCodec": VoiceLinkDesktopAudioTransport.preferredCodec,
                "engine": VoiceLinkDesktopAudioTransport.engine,
                "audioMode": VoiceLinkDesktopAudioTransport.audioMode,
                "frameSize": frameLength
            ])
        }

        do {
            engine.prepare()
            try engine.start()
            audioTransmitEngine = engine
            isTransmitting = true
            DispatchQueue.main.async {
                self.isAudioTransmitting = true
                self.audioTransmissionStatus = LocalMonitorManager.shared.isMonitoring ? "Transmitting + monitoring" : "Transmitting"
                LocalMonitorManager.shared.refreshForSharedCaptureChange(reason: "audioTransmissionStarted")
                LocalMonitorManager.shared.refreshForSharedCaptureChange(reason: "audioTransmissionStartedStabilized", after: 0.75)
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
        audioStartQueue.async { [weak self] in
            self?.stopAudioTransmissionNow()
        }
    }

    private func stopAudioTransmissionNow() {
        if isTransmitting {
            audioTransmitEngine?.inputNode.removeTap(onBus: 0)
            audioTransmitEngine?.stop()
            audioTransmitEngine = nil
            isTransmitting = false
        }
        DispatchQueue.main.async {
            self.isAudioTransmitting = false
            self.audioTransmissionStatus = self.inputMuted ? "Input muted" : "Stopped"
            LocalMonitorManager.shared.refreshForSharedCaptureChange(reason: "audioTransmissionStopped")
            LocalMonitorManager.shared.refreshForSharedCaptureChange(reason: "audioTransmissionStoppedStabilized", after: 0.75)
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
    let welcomeMessage: String?
    let liveBroadcast: RoomLiveBroadcast?
    let userCount: Int
    let botCount: Int
    let totalVisible: Int
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
        welcomeMessage: String?,
        liveBroadcast: RoomLiveBroadcast?,
        userCount: Int,
        botCount: Int = 0,
        totalVisible: Int = 0,
        isPrivate: Bool,
        isLocked: Bool,
        recordingAllowed: Bool,
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
        lockedBy: String?
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.welcomeMessage = welcomeMessage
        self.liveBroadcast = liveBroadcast
        self.userCount = userCount
        self.botCount = max(0, botCount)
        self.totalVisible = max(userCount + max(0, botCount), totalVisible)
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
            func dateFromTimestamp(_ raw: TimeInterval) -> Date {
                let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
                return Date(timeIntervalSince1970: seconds)
            }

            if let timestamp = value as? TimeInterval {
                return dateFromTimestamp(timestamp)
            }
            if let timestampInt = value as? Int {
                return dateFromTimestamp(TimeInterval(timestampInt))
            }
            guard let stringValue = value as? String, !stringValue.isEmpty else {
                return nil
            }
            let isoFormatter = ISO8601DateFormatter()
            if let parsed = isoFormatter.date(from: stringValue) {
                return parsed
            }
            if let timestamp = TimeInterval(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return dateFromTimestamp(timestamp)
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
            ?? {
                guard let metadata = dict["metadata"] as? [String: Any] else { return nil }
                return stringValue(metadata["description"])
                    ?? stringValue(metadata["roomDescription"])
                    ?? stringValue(metadata["room_description"])
                    ?? stringValue(metadata["details"])
                    ?? stringValue(metadata["topic"])
                    ?? stringValue(metadata["about"])
                    ?? stringValue(metadata["summary"])
                    ?? stringValue(metadata["subtitle"])
            }()
            ?? stringValue(dict["details"])
            ?? stringValue(dict["topic"])
            ?? stringValue(dict["about"])
            ?? stringValue(dict["summary"])
            ?? stringValue(dict["subtitle"])
            ?? ""
        self.welcomeMessage = stringValue(dict["welcomeMessage"])
            ?? stringValue(dict["roomWelcomeMessage"])
            ?? stringValue(dict["welcome"])
        if let liveBroadcastDict = dict["liveBroadcast"] as? [String: Any] {
            let shareURL = stringValue(liveBroadcastDict["shareUrl"])
                ?? stringValue(liveBroadcastDict["publicUrl"])
            self.liveBroadcast = RoomLiveBroadcast(
                enabled: liveBroadcastDict["enabled"] as? Bool ?? false,
                isLive: liveBroadcastDict["isLive"] as? Bool ?? false,
                status: stringValue(liveBroadcastDict["status"]) ?? "idle",
                provider: stringValue(liveBroadcastDict["provider"]) ?? "aaastreamer",
                providerName: stringValue(liveBroadcastDict["providerName"]) ?? "AAAStreamer",
                shareURL: shareURL
            )
        } else {
            self.liveBroadcast = nil
        }
        self.userCount = intValue(dict["userCount"]) ?? intValue(dict["users"]) ?? intValue(dict["memberCount"]) ?? 0
        self.botCount = intValue(dict["botCount"]) ?? 0
        self.totalVisible = max(self.userCount + self.botCount, intValue(dict["totalVisible"]) ?? 0)
        self.isPrivate = dict["isPrivate"] as? Bool ?? dict["private"] as? Bool ?? false
        self.isLocked = dict["isLocked"] as? Bool ?? dict["locked"] as? Bool ?? false
        self.recordingAllowed = dict["recordingAllowed"] as? Bool
            ?? dict["allowRecording"] as? Bool
            ?? dict["recordingEnabled"] as? Bool
            ?? false
        self.maxUsers = intValue(dict["maxUsers"]) ?? 50
        self.createdBy = stringValue(dict["createdBy"]) ?? stringValue(dict["ownerUsername"]) ?? stringValue(dict["owner"])
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
        self.lockedBy = stringValue(dict["lockedBy"])
            ?? stringValue(dict["lockedByUsername"])
            ?? stringValue(dict["locked_by"])
    }
}

struct RoomUser: Identifiable {
    let id: String
    let odId: String
    let sessionId: String?
    let deviceId: String?
    let username: String
    let displayName: String
    let isBot: Bool
    let hasAudioControls: Bool
    let isMuted: Bool
    let isDeafened: Bool
    let isSpeaking: Bool
    let transmitEnabled: Bool

    init?(from dict: [String: Any]) {
        guard let odId = dict["odId"] as? String
                ?? dict["userId"] as? String
                ?? dict["accountId"] as? String
                ?? dict["id"] as? String,
              let username = dict["username"] as? String
                ?? dict["userName"] as? String
                ?? dict["name"] as? String
                ?? dict["displayName"] as? String else {
            return nil
        }
        self.odId = odId
        self.sessionId = dict["sessionId"] as? String
            ?? dict["socketId"] as? String
            ?? dict["socketID"] as? String
            ?? dict["connectionId"] as? String
        self.deviceId = dict["deviceId"] as? String
            ?? dict["clientId"] as? String
            ?? dict["deviceName"] as? String
        self.id = [
            self.sessionId,
            self.deviceId,
            dict["presenceId"] as? String,
            dict["participantId"] as? String,
            odId
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? odId
        self.username = username
        self.displayName = dict["displayName"] as? String ?? username
        self.isBot = dict["isBot"] as? Bool ?? false
        self.hasAudioControls = dict["hasAudioControls"] as? Bool ?? !self.isBot
        self.isMuted = dict["muted"] as? Bool ?? dict["isMuted"] as? Bool ?? false
        self.isDeafened = dict["deafened"] as? Bool ?? dict["isDeafened"] as? Bool ?? false
        self.isSpeaking = dict["speaking"] as? Bool ?? dict["isSpeaking"] as? Bool ?? false
        self.transmitEnabled = dict["transmitEnabled"] as? Bool ?? true
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let roomLeft = Notification.Name("roomLeft")
    static let roomTranscriptReceived = Notification.Name("roomTranscriptReceived")
    static let botAudioReceived = Notification.Name("botAudioReceived")
    static let jellyfinWebhookEvent = Notification.Name("jellyfinWebhookEvent")
    static let jellyfinMediaStreamStarted = Notification.Name("jellyfinMediaStreamStarted")
    static let jellyfinMediaStreamStopped = Notification.Name("jellyfinMediaStreamStopped")
}
