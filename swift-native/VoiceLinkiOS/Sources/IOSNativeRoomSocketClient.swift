import Foundation
import AVFoundation
import UIKit
import SocketIO

@MainActor
final class IOSNativeRoomSocketClient: ObservableObject {
    static let shared = IOSNativeRoomSocketClient()

    @Published private(set) var connectionStatus = "Offline"
    @Published private(set) var joinedRoomId = ""
    @Published private(set) var joinedRoomName = ""
    @Published private(set) var audioRelayStatus = "Relay idle"
    @Published private(set) var inputMuted = false
    @Published private(set) var outputMuted = false
    @Published private(set) var userAudioLevels: [String: Float] = [:]
    @Published private(set) var roomUsers: [IOSDirectMessageTarget] = []
    @Published private(set) var userPlaybackGains: [String: Float] = [:]
    @Published private(set) var userPlaybackMuted: [String: Bool] = [:]

    private struct PendingSession {
        let baseURL: String
        let roomId: String
        let roomName: String
        let displayName: String
        let authToken: String
        let authProvider: String
        let authUser: [String: Any]
    }

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var activeBaseURL = ""
    private var pendingSession: PendingSession?
    private var observers: [NSObjectProtocol] = []
    private let relayPlayer = IOSRoomAudioRelayPlayer()
    private let microphoneCapture = IOSRoomMicrophoneCapture()

    private init() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .iosRequestLeaveRoom, object: nil, queue: .main) { [weak self] note in
                let roomId = (note.userInfo?["roomId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.leaveRoom(roomId: roomId.isEmpty ? self.joinedRoomId : roomId)
                }
            }
        )
        observers.append(
            center.addObserver(forName: .iosSendDirectMessage, object: nil, queue: .main) { [weak self] note in
                let body = (note.userInfo?["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let userId = (note.userInfo?["userId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty, !userId.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.socket?.emit("direct-message", ["targetUserId": userId, "message": body])
                }
            }
        )
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func startSession(
        baseURL: String,
        roomId: String,
        roomName: String,
        displayName: String,
        authToken: String,
        authProvider: String = "",
        authUserJSON: String = ""
    ) {
        let normalizedBase = normalizedSocketBaseURL(baseURL)
        pendingSession = PendingSession(
            baseURL: normalizedBase,
            roomId: roomId,
            roomName: roomName,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Guest" : displayName,
            authToken: authToken.trimmingCharacters(in: .whitespacesAndNewlines),
            authProvider: authProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            authUser: decodeAuthUserPayload(authUserJSON)
        )

        if activeBaseURL != normalizedBase || socket == nil {
            reconnect(to: normalizedBase)
            return
        }

        if socket?.status == .connected {
            joinPendingSessionIfNeeded()
        } else if socket?.status != .connecting {
            connectionStatus = "Connecting…"
            socket?.connect()
        }
    }

    func leaveRoom(roomId: String) {
        let trimmedRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoomId.isEmpty else { return }
        socket?.emit("leave-room", ["roomId": trimmedRoomId])
        NotificationCenter.default.post(
            name: .iosRoomLeft,
            object: nil,
            userInfo: ["roomId": trimmedRoomId, "roomName": joinedRoomName]
        )
        joinedRoomId = ""
        joinedRoomName = ""
        pendingSession = nil
        connectionStatus = "Left room."
        audioRelayStatus = "Relay stopped"
        userAudioLevels = [:]
        roomUsers = []
        userPlaybackGains = [:]
        userPlaybackMuted = [:]
        relayPlayer.setMonitorUserId(nil)
        microphoneCapture.stop()
        relayPlayer.stop()
        socket?.disconnect()
    }

    func sendRoomMessage(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !joinedRoomId.isEmpty else { return }
        socket?.emit("chat-message", [
            "roomId": joinedRoomId,
            "message": body,
            "type": "text"
        ])
    }

    func requestRoomUsers() {
        guard !joinedRoomId.isEmpty else { return }
        socket?.emit("get-room-users", ["roomId": joinedRoomId])
    }

    func requestRoomMessages() {
        guard !joinedRoomId.isEmpty else { return }
        socket?.emit("get-room-messages", ["roomId": joinedRoomId, "limit": 100])
    }

    func refreshRoomSnapshotViaHTTP() async {
        let roomId = joinedRoomId.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = activeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roomId.isEmpty, !baseURL.isEmpty else { return }
        await refreshRoomUsersViaHTTP(baseURL: baseURL, roomId: roomId)
        await refreshRoomMessagesViaHTTP(baseURL: baseURL, roomId: roomId)
    }

    func setPlaybackGain(_ gain: Float) {
        relayPlayer.setGain(gain)
    }

    func setPlaybackMuted(_ muted: Bool) {
        outputMuted = muted
        relayPlayer.setMuted(muted)
        publishAudioState()
    }

    func setInputMuted(_ muted: Bool) {
        inputMuted = muted
        publishAudioState()
    }

    func setOutputMuted(_ muted: Bool) {
        outputMuted = muted
        relayPlayer.setMuted(muted)
        publishAudioState()
    }

    func setPlaybackDuckScale(_ scale: Float) {
        relayPlayer.setDuckScale(scale)
    }

    func setMonitorUserId(_ userId: String?) {
        let normalizedUserId = (userId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        relayPlayer.setMonitorUserId(normalizedUserId.isEmpty ? nil : normalizedUserId)
        audioRelayStatus = normalizedUserId.isEmpty ? "Relay active" : "Monitoring one user"
    }

    func setUserPlaybackGain(_ gain: Float, for userId: String) {
        let normalizedUserId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserId.isEmpty else { return }
        let clampedGain = max(0, min(3, gain))
        userPlaybackGains[normalizedUserId] = clampedGain
        relayPlayer.setUserGain(clampedGain, for: normalizedUserId)
    }

    func setUserPlaybackMuted(_ muted: Bool, for userId: String) {
        let normalizedUserId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserId.isEmpty else { return }
        userPlaybackMuted[normalizedUserId] = muted
        relayPlayer.setUserMuted(muted, for: normalizedUserId)
    }

    private func reconnect(to baseURL: String) {
        socket?.disconnect()
        manager = nil
        socket = nil
        activeBaseURL = baseURL
        connectionStatus = "Connecting…"

        guard let socketURL = URL(string: baseURL) else {
            connectionStatus = "Invalid server URL."
            return
        }

        let manager = SocketManager(
            socketURL: socketURL,
            config: [
                .log(false),
                .compress,
                .forceWebsockets(true),
                .path("/socket.io"),
                .reconnects(true),
                .reconnectAttempts(6),
                .reconnectWait(2)
            ]
        )
        let socket = manager.defaultSocket
        self.manager = manager
        self.socket = socket
        installHandlers(on: socket)
        socket.connect()
    }

    private func installHandlers(on socket: SocketIOClient) {
        socket.removeAllHandlers()

        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self else { return }
            self.connectionStatus = "Connected"
            self.registerPendingSessionIfNeeded()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, _ in
            guard let self else { return }
            let reason = (data.first as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Disconnected"
            if self.joinedRoomId.isEmpty {
                self.connectionStatus = reason
            } else {
                self.connectionStatus = "Disconnected from room."
            }
        }

        socket.on(clientEvent: .error) { [weak self] data, _ in
            guard let self else { return }
            let message = self.parseErrorMessage(data) ?? "Socket error"
            self.connectionStatus = message
        }

        socket.on("joined-room") { [weak self] data, _ in
            guard let self,
                  let payload = self.socketDictionary(from: data) else { return }
            let room = Self.socketDictionaryValue(payload["room"]) ?? [:]
            let fallbackRoomId = self.pendingSession?.roomId ?? self.joinedRoomId
            let roomId = normalizedSocketText(room["id"], fallback: fallbackRoomId)
            let roomName = normalizedSocketText(room["name"], fallback: self.joinedRoomName)
            self.joinedRoomId = roomId
            self.joinedRoomName = roomName
            self.connectionStatus = roomName.isEmpty ? "Joined room." : "Joined \(roomName)."
            let users = Self.socketUsersValue(payload)
            self.updateRoomUsers(Self.socketUserDictionaries(users), fallbackRoomId: roomId)
            NotificationCenter.default.post(
                name: .iosRoomJoined,
                object: nil,
                userInfo: [
                    "roomId": roomId,
                    "roomName": roomName,
                    "users": users
                ]
            )
            if users.isEmpty, let joinedUser = Self.socketDictionaryValue(payload["user"]) {
                self.updateRoomUsers([joinedUser], fallbackRoomId: roomId)
                NotificationCenter.default.post(
                    name: .iosRoomUsersUpdated,
                    object: nil,
                    userInfo: ["roomId": roomId, "users": [joinedUser]]
                )
            } else if !users.isEmpty {
                NotificationCenter.default.post(
                    name: .iosRoomUsersUpdated,
                    object: nil,
                    userInfo: ["roomId": roomId, "users": users]
                )
            }
            self.requestRoomUsers()
            self.requestRoomMessages()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.requestRoomUsers()
                self?.requestRoomMessages()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.requestRoomUsers()
                self?.requestRoomMessages()
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.refreshRoomSnapshotViaHTTP()
            }
            self.socket?.emit("enable-audio-relay", [
                "enabled": true,
                "sampleRate": 48000,
                "channels": 1
            ])
            self.startMicrophoneCaptureIfNeeded()
        }

        socket.on("join-room-error") { [weak self] data, _ in
            guard let self else { return }
            let message = self.parseErrorMessage(data) ?? "Could not join room."
            self.connectionStatus = message
        }

        socket.on("auth_success") { [weak self] _, _ in
            guard let self else { return }
            if !self.joinedRoomId.isEmpty {
                return
            }
            self.connectionStatus = "Session verified"
            self.joinPendingSessionIfNeeded()
        }

        socket.on("auth_failed") { [weak self] data, _ in
            guard let self else { return }
            let message = self.parseErrorMessage(data) ?? "Authentication failed"
            self.connectionStatus = "\(message). Joining as guest…"
            self.joinPendingSessionIfNeeded()
        }

        socket.on("auth_token_refreshed") { data, _ in
            guard let payload = Self.socketDictionaryValue(data.first) else { return }
            let token = String(describing: payload["token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }
            UserDefaults.standard.set(token, forKey: "voicelink.authToken")
            let provider = String(describing: payload["provider"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !provider.isEmpty {
                UserDefaults.standard.set(provider.lowercased(), forKey: "voicelink.authProvider")
            }
        }

        socket.on("error") { [weak self] data, _ in
            guard let self else { return }
            let message = self.parseErrorMessage(data) ?? "Request failed."
            self.connectionStatus = message
        }

        socket.on("room-users") { [weak self] data, _ in
            guard let self,
                  let payload = self.socketDictionary(from: data) else { return }
            let roomId = Self.socketRoomId(payload, fallback: self.joinedRoomId)
            let users = Self.socketUsersValue(payload)
            self.updateRoomUsers(Self.socketUserDictionaries(users), fallbackRoomId: roomId)
            NotificationCenter.default.post(
                name: .iosRoomUsersUpdated,
                object: nil,
                userInfo: ["roomId": roomId, "users": users]
            )
        }

        socket.on("room-user-count") { [weak self] data, _ in
            guard let self,
                  let payload = self.socketDictionary(from: data) else { return }
            let roomId = Self.socketRoomId(payload, fallback: self.joinedRoomId)
            let users = Self.socketUsersValue(payload)
            guard !users.isEmpty else {
                self.requestRoomUsers()
                Task { [weak self] in
                    await self?.refreshRoomUsersViaHTTP(
                        baseURL: self?.activeBaseURL ?? "",
                        roomId: roomId
                    )
                }
                return
            }
            self.updateRoomUsers(Self.socketUserDictionaries(users), fallbackRoomId: roomId)
            NotificationCenter.default.post(
                name: .iosRoomUsersUpdated,
                object: nil,
                userInfo: ["roomId": roomId, "users": users]
            )
        }

        socket.on("user-audio-state-changed") { [weak self] _, _ in
            self?.requestRoomUsers()
        }

        socket.on("room-messages") { [weak self] data, _ in
            guard let self,
                  let payload = self.socketDictionary(from: data) else { return }
            let roomId = Self.socketRoomId(payload, fallback: self.joinedRoomId)
            let messages = Self.socketMessagesValue(payload)
            for message in messages {
                self.postRoomMessage(message, fallbackRoomId: roomId)
            }
        }

        socket.on("chat-message") { [weak self] data, _ in
            guard let self,
                  let payload = self.socketDictionary(from: data) else { return }
            self.postRoomMessage(payload, fallbackRoomId: self.joinedRoomId)
        }

        socket.on("direct-message") { data, _ in
            guard let payload = Self.socketDictionaryValue(data.first) else { return }
            let userId = normalizedSocketText(payload["senderId"] ?? payload["userId"], fallback: "")
            let userName = normalizedSocketText(payload["senderName"] ?? payload["userName"], fallback: "User")
            NotificationCenter.default.post(
                name: .iosDirectMessageEvent,
                object: nil,
                userInfo: ["userId": userId, "userName": userName]
            )
        }

        socket.on("room-transcript") { [weak self] data, _ in
            guard let self,
                  let payload = self.socketDictionary(from: data) else { return }
            let roomId = normalizedSocketText(payload["roomId"], fallback: self.joinedRoomId)
            let roomName = normalizedSocketText(payload["roomName"], fallback: self.joinedRoomName)
            let speaker = normalizedSocketText(
                payload["speaker"] ?? payload["userName"] ?? payload["author"],
                fallback: "Speaker"
            )
            let body = normalizedSocketText(payload["text"] ?? payload["body"], fallback: "")
            guard !roomId.isEmpty, !body.isEmpty else { return }
            NotificationCenter.default.post(
                name: .iosRoomTranscriptEvent,
                object: nil,
                userInfo: [
                    "roomId": roomId,
                    "roomName": roomName,
                    "speaker": speaker,
                    "body": body,
                    "timestamp": Date().timeIntervalSince1970
                ]
            )
        }

        socket.on("relay-status") { [weak self] data, _ in
            guard let self else { return }
            let payload = Self.socketDictionaryValue(data.first) ?? [:]
            let isActive = (payload["active"] as? Bool) ?? false
            self.audioRelayStatus = isActive ? "Relay active" : "Relay unavailable"
            if isActive {
                self.relayPlayer.startIfNeeded()
            } else {
                self.relayPlayer.stop()
            }
        }

        socket.on("relayed-audio") { [weak self] data, _ in
            guard let self,
                  let payload = self.socketDictionary(from: data) else { return }
            self.updateIncomingAudioLevel(from: payload)
            self.relayPlayer.playPacket(payload)
        }

        socket.on("user-joined") { [weak self] _, _ in
            self?.requestRoomUsers()
        }

        socket.on("user-left") { [weak self] _, _ in
            self?.requestRoomUsers()
        }
    }

    private func updateRoomUsers(_ users: [[String: Any]], fallbackRoomId: String) {
        let resolvedRoomId = fallbackRoomId.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = users.enumerated().compactMap { index, user -> IOSDirectMessageTarget? in
            let id = normalizedSocketText(user["id"] ?? user["userId"], fallback: "")
            let rawName = normalizedSocketText(
                user["name"] ?? user["userName"] ?? user["displayName"] ?? user["username"],
                fallback: ""
            )
            let resolvedId = id.isEmpty
                ? "\(resolvedRoomId)|\(rawName.isEmpty ? "user-\(index)" : rawName.lowercased())"
                : id
            let fallbackName = resolvedId.count > 8 ? "User \(resolvedId.prefix(8))" : "User \(resolvedId)"
            let name = rawName.isEmpty ? fallbackName : rawName
            return IOSDirectMessageTarget(
                id: resolvedId,
                name: name,
                isMuted: (user["muted"] as? Bool) ?? (user["isMuted"] as? Bool) ?? false,
                isDeafened: (user["deafened"] as? Bool) ?? (user["isDeafened"] as? Bool) ?? false,
                isSpeaking: (user["speaking"] as? Bool) ?? (user["isSpeaking"] as? Bool) ?? false,
                transmitEnabled: (user["transmitEnabled"] as? Bool) ?? true,
                isBot: (user["isBot"] as? Bool) ?? false,
                hasAudioControls: (user["hasAudioControls"] as? Bool) ?? ((user["isBot"] as? Bool) != true),
                deviceName: normalizedSocketText(user["deviceName"], fallback: ""),
                deviceType: normalizedSocketText(user["deviceType"], fallback: ""),
                clientVersion: normalizedSocketText(user["clientVersion"], fallback: "")
            )
        }

        guard !mapped.isEmpty else { return }
        roomUsers = mapped.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let sessionToken = pendingSession?.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (UserDefaults.standard.string(forKey: "voicelink.authToken") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sessionToken.isEmpty {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            request.setValue(sessionToken, forHTTPHeaderField: "x-session-token")
        }
        return request
    }

    private func refreshRoomUsersViaHTTP(baseURL: String, roomId: String) async {
        let normalizedRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !normalizedRoomId.isEmpty,
              let encodedRoomId = normalizedRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedBaseURL)/api/rooms/\(encodedRoomId)/users") else {
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let users = Self.socketArrayDictionaryValue(payload["users"])
            guard !users.isEmpty else { return }
            self.updateRoomUsers(users, fallbackRoomId: normalizedRoomId)
            NotificationCenter.default.post(
                name: .iosRoomUsersUpdated,
                object: nil,
                userInfo: [
                    "roomId": normalizedRoomId,
                    "users": users
                ]
            )
        } catch {
            return
        }
    }

    private func refreshRoomMessagesViaHTTP(baseURL: String, roomId: String) async {
        let normalizedRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !normalizedRoomId.isEmpty,
              let encodedRoomId = normalizedRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedBaseURL)/api/rooms/\(encodedRoomId)/messages?limit=100") else {
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let messages = Self.socketArrayDictionaryValue(payload["messages"])
            guard !messages.isEmpty else { return }
            for message in messages {
                self.postRoomMessage(message, fallbackRoomId: normalizedRoomId)
            }
        } catch {
            return
        }
    }

    private func joinPendingSessionIfNeeded() {
        guard let pendingSession else { return }
        socket?.emit("join-room", [
            "roomId": pendingSession.roomId,
            "userName": pendingSession.displayName
        ])
        connectionStatus = "Joining \(pendingSession.roomName)…"
    }

    private func socketDictionary(from data: [Any]) -> [String: Any]? {
        Self.socketDictionaryValue(data.first)
    }

    private static func socketDictionaryValue(_ value: Any?) -> [String: Any]? {
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

    private static func socketArrayDictionaryValue(_ value: Any?) -> [[String: Any]] {
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

    private static func socketUserDictionaries(_ values: [Any]) -> [[String: Any]] {
        values.compactMap { value in
            socketDictionaryValue(value)
        }
    }

    private static func socketRoomId(_ payload: [String: Any], fallback: String) -> String {
        let room = socketDictionaryValue(payload["room"]) ?? [:]
        return normalizedSocketText(
            payload["roomId"] ?? payload["id"] ?? room["roomId"] ?? room["id"],
            fallback: fallback
        )
    }

    private static func socketUsersValue(_ payload: [String: Any]) -> [Any] {
        if let users = payload["users"] as? [Any] {
            return users
        }
        if let payloadData = socketDictionaryValue(payload["payload"]),
           let users = payloadData["users"] as? [Any] {
            return users
        }
        if let room = socketDictionaryValue(payload["room"]) {
            if let users = room["users"] as? [Any] {
                return users
            }
            if let members = room["members"] as? [Any] {
                return members
            }
            if let participants = room["participants"] as? [Any] {
                return participants
            }
        }
        if let members = payload["members"] as? [Any] {
            return members
        }
        if let participants = payload["participants"] as? [Any] {
            return participants
        }
        return []
    }

    private static func socketMessagesValue(_ payload: [String: Any]) -> [[String: Any]] {
        if let payloadData = socketDictionaryValue(payload["payload"]) {
            let payloadMessages = socketArrayDictionaryValue(payloadData["messages"])
            if !payloadMessages.isEmpty {
                return payloadMessages
            }
        }
        let directMessages = socketArrayDictionaryValue(payload["messages"])
        if !directMessages.isEmpty {
            return directMessages
        }
        if let room = socketDictionaryValue(payload["room"]) {
            let roomMessages = socketArrayDictionaryValue(room["messages"])
            if !roomMessages.isEmpty {
                return roomMessages
            }
        }
        return []
    }

    private func publishAudioState() {
        guard !joinedRoomId.isEmpty else { return }
        socket?.emit("audio-state", [
            "roomId": joinedRoomId,
            "muted": inputMuted,
            "deafened": outputMuted,
            "transmitEnabled": !inputMuted,
            "localMuted": inputMuted,
            "outputMuted": outputMuted
        ])
    }

    private func startMicrophoneCaptureIfNeeded() {
        microphoneCapture.start { [weak self] packet in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.joinedRoomId.isEmpty,
                      !self.inputMuted,
                      let socket = self.socket,
                      socket.status == .connected else {
                    return
                }
                socket.emit("audio-data", [
                    "roomId": self.joinedRoomId,
                    "audioData": packet.audioData.base64EncodedString(),
                    "timestamp": Date().timeIntervalSince1970,
                    "sampleRate": packet.sampleRate,
                    "channels": packet.channels
                ])
            }
        }
    }

    private func registerPendingSessionIfNeeded() {
        guard let pendingSession else { return }
        let token = pendingSession.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = pendingSession.authProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let user = pendingSession.authUser
        if token.isEmpty || provider.isEmpty || String(describing: user["id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            joinPendingSessionIfNeeded()
            return
        }
        connectionStatus = "Verifying account session…"
        socket?.emit("register-session", [
            "token": token,
            "provider": provider,
            "deviceId": UIDevice.current.identifierForVendor?.uuidString ?? "ios",
            "deviceName": UIDevice.current.name,
            "deviceType": "ios",
            "clientVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "timeZone": TimeZone.current.identifier,
            "locale": Locale.current.identifier,
            "user": user
        ])
    }

    private func postRoomMessage(_ payload: [String: Any], fallbackRoomId: String) {
        let roomId = normalizedSocketText(payload["roomId"], fallback: fallbackRoomId)
        let roomName = normalizedSocketText(payload["roomName"], fallback: joinedRoomName)
        let author = normalizedSocketText(
            payload["userName"] ?? payload["senderName"] ?? payload["author"] ?? payload["botName"] ?? payload["name"],
            fallback: "User"
        )
        let senderId = normalizedSocketText(
            payload["userId"] ?? payload["senderId"] ?? payload["botId"] ?? payload["id"],
            fallback: ""
        )
        let body = normalizedSocketText(payload["message"] ?? payload["content"] ?? payload["text"] ?? payload["body"], fallback: "")
        let type = normalizedSocketText(payload["type"] ?? payload["messageType"], fallback: "text")
        guard !roomId.isEmpty, !body.isEmpty else { return }
        NotificationCenter.default.post(
            name: .iosRoomMessageEvent,
            object: nil,
            userInfo: [
                "roomId": roomId,
                "roomName": roomName,
                "userId": senderId,
                "author": author,
                "body": body,
                "isBot": (payload["isBot"] as? Bool) ?? false,
                "type": type.isEmpty ? "text" : type,
                "timestamp": Date().timeIntervalSince1970
            ]
        )
    }

    private func updateIncomingAudioLevel(from payload: [String: Any]) {
        let userId = normalizedSocketText(payload["userId"], fallback: "")
        guard !userId.isEmpty else { return }
        let encoded = (payload["audioData"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let level = IOSRoomAudioRelayPlayer.packetLevel(fromBase64Audio: encoded)
        userAudioLevels[userId] = level
    }

    private func parseErrorMessage(_ data: [Any]) -> String? {
        if let payload = data.first as? [String: Any],
           let message = payload["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        if let text = data.first as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }
}

private func normalizedSocketText(_ value: Any?, fallback: String = "") -> String {
    if value == nil || value is NSNull {
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let text = String(describing: value ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = text.lowercased()
    if text.isEmpty || lowered == "null" || lowered == "<null>" || lowered == "nil" {
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
}

private func decodeAuthUserPayload(_ rawJSON: String) -> [String: Any] {
    let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return json
}

private final class IOSRoomAudioRelayPlayer {
    private let renderQueue = DispatchQueue(label: "voicelink.ios.audio-relay.playback")
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    private var gain: Float = 1.0
    private var duckScale: Float = 1.0
    private var isMuted = false
    private var isConfigured = false
    private var monitorUserId: String?
    private var userGains: [String: Float] = [:]
    private var userMuted: [String: Bool] = [:]

    func startIfNeeded() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured, let playbackFormat = self.playbackFormat {
                self.engine.attach(self.playerNode)
                self.engine.connect(self.playerNode, to: self.engine.mainMixerNode, format: playbackFormat)
                self.applyOutputVolume()
                self.isConfigured = true
            }
            guard !self.engine.isRunning else {
                if !self.playerNode.isPlaying {
                    self.playerNode.play()
                }
                return
            }
            do {
                self.engine.prepare()
                try self.engine.start()
                self.playerNode.play()
            } catch {
                self.engine.stop()
            }
        }
    }

    func stop() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            self.engine.stop()
        }
    }

    func setGain(_ gain: Float) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.gain = max(0, min(3, gain))
            self.applyOutputVolume()
        }
    }

    func setMuted(_ muted: Bool) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.isMuted = muted
            self.applyOutputVolume()
        }
    }

    func setDuckScale(_ scale: Float) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.duckScale = max(0, min(1, scale))
            self.applyOutputVolume()
        }
    }

    func setMonitorUserId(_ userId: String?) {
        renderQueue.async { [weak self] in
            self?.monitorUserId = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func setUserGain(_ gain: Float, for userId: String) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.userGains[userId] = max(0, min(3, gain))
        }
    }

    func setUserMuted(_ muted: Bool, for userId: String) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.userMuted[userId] = muted
        }
    }

    func playPacket(_ payload: [String: Any]) {
        guard let encoded = payload["audioData"] as? String,
              let data = Data(base64Encoded: encoded) else {
            return
        }
        let sampleRate = (payload["sampleRate"] as? Double) ?? 48_000
        let channels = AVAudioChannelCount((payload["channels"] as? Int) ?? 1)
        let senderId = String(describing: payload["userId"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        renderQueue.async { [weak self] in
            guard let self else { return }
            if let monitorUserId = self.monitorUserId,
               !monitorUserId.isEmpty,
               senderId != monitorUserId {
                return
            }
            if self.userMuted[senderId] == true {
                return
            }
            if self.playbackFormat?.sampleRate != sampleRate || self.playbackFormat?.channelCount != channels {
                self.rebuildEngine(sampleRate: sampleRate, channels: channels)
            }
            guard let format = self.playbackFormat else { return }
            let sampleCount = data.count / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return }
            let frameCount = AVAudioFrameCount(sampleCount / max(1, Int(channels)))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return
            }
            buffer.frameLength = frameCount
            data.withUnsafeBytes { rawBuffer in
                guard let source = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
                let userGain = max(0, min(3, self.userGains[senderId] ?? 1.0))
                if channels == 1, let channel = buffer.floatChannelData?[0] {
                    for frame in 0..<Int(frameCount) {
                        channel[frame] = source[frame] * userGain
                    }
                } else if channels >= 2, let channelData = buffer.floatChannelData {
                    let frames = Int(frameCount)
                    for frame in 0..<frames {
                        for channelIndex in 0..<min(Int(channels), Int(format.channelCount)) {
                            channelData[channelIndex][frame] = source[frame * Int(channels) + channelIndex] * userGain
                        }
                    }
                }
            }
            self.startIfNeeded()
            self.playerNode.scheduleBuffer(buffer, completionHandler: nil)
        }
    }

    private func rebuildEngine(sampleRate: Double, channels: AVAudioChannelCount) {
        playerNode.stop()
        engine.stop()
        if isConfigured {
            engine.disconnectNodeOutput(playerNode)
            engine.detach(playerNode)
            isConfigured = false
        }
        playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate > 0 ? sampleRate : 48_000,
            channels: max(1, channels)
        )
    }

    private func applyOutputVolume() {
        let scaledGain = gain * duckScale
        engine.mainMixerNode.outputVolume = isMuted ? 0 : max(0, min(3, scaledGain))
    }

    static func packetLevel(fromBase64Audio encoded: String) -> Float {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = Data(base64Encoded: trimmed) else {
            return 0
        }
        let sampleCount = data.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return 0 }

        let rms = data.withUnsafeBytes { rawBuffer -> Float in
            guard let samples = rawBuffer.bindMemory(to: Float.self).baseAddress else { return 0 }
            var sumOfSquares: Float = 0
            for index in 0..<sampleCount {
                let sample = samples[index]
                sumOfSquares += sample * sample
            }
            return sqrt(sumOfSquares / Float(sampleCount))
        }

        return max(0, min(1, rms * 3))
    }
}

private struct IOSCapturedAudioPacket {
    let audioData: Data
    let sampleRate: Double
    let channels: Int
}

private final class IOSRoomMicrophoneCapture {
    private let captureQueue = DispatchQueue(label: "voicelink.ios.microphone.capture")
    private let engine = AVAudioEngine()
    private var isRunning = false

    func start(onPacket: @escaping (IOSCapturedAudioPacket) -> Void) {
        captureQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }

            let inputNode = self.engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            let channelCount = max(1, Int(inputFormat.channelCount))
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                guard let packet = self.encode(buffer: buffer, sampleRate: inputFormat.sampleRate, channels: channelCount) else {
                    return
                }
                onPacket(packet)
            }

            do {
                self.engine.prepare()
                try self.engine.start()
                self.isRunning = true
            } catch {
                inputNode.removeTap(onBus: 0)
                self.engine.stop()
                self.isRunning = false
            }
        }
    }

    func stop() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.isRunning = false
        }
    }

    private func encode(buffer: AVAudioPCMBuffer, sampleRate: Double, channels: Int) -> IOSCapturedAudioPacket? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else {
            return nil
        }

        var pcmData = Data(count: frameCount * channels * MemoryLayout<Float>.size)
        pcmData.withUnsafeMutableBytes { rawBuffer in
            guard let target = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
            if channels == 1 {
                target.update(from: channelData[0], count: frameCount)
                return
            }
            for frame in 0..<frameCount {
                for channelIndex in 0..<channels {
                    target[frame * channels + channelIndex] = channelData[channelIndex][frame]
                }
            }
        }

        return IOSCapturedAudioPacket(
            audioData: pcmData,
            sampleRate: sampleRate > 0 ? sampleRate : 48_000,
            channels: channels
        )
    }
}

private func normalizedSocketBaseURL(_ rawURL: String) -> String {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "https://voicelink.devinecreations.net"
    }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
    return "https://\(trimmed)"
}
