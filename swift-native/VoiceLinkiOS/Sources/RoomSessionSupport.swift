import SwiftUI
import Foundation
import AVFoundation
import AVKit
import SocketIO
import UIKit
@preconcurrency import UserNotifications

struct RoomSessionDestination: Identifiable, Hashable {
    let id: String
    let roomId: String
    let roomName: String
    let roomDescription: String
    let baseURL: String

    init(roomId: String, roomName: String, roomDescription: String, baseURL: String) {
        self.id = "\(baseURL)|\(roomId)|session"
        self.roomId = roomId
        self.roomName = roomName
        self.roomDescription = roomDescription
        self.baseURL = baseURL
    }
}

struct RoomPreviewDestination: Identifiable, Hashable {
    let id: String
    let roomId: String
    let roomName: String
    let roomDescription: String
    let baseURL: String
    let room: RoomSummary

    init(roomId: String, roomName: String, roomDescription: String, baseURL: String, room: RoomSummary) {
        self.id = "\(baseURL)|\(roomId)|preview"
        self.roomId = roomId
        self.roomName = roomName
        self.roomDescription = roomDescription
        self.baseURL = baseURL
        self.room = room
    }
}

struct RoomPresence: Identifiable, Hashable {
    let id: String
    let name: String
}

struct RoomChatMessage: Identifiable, Hashable {
    let id: String
    let author: String
    let body: String
    let timestamp: Date
}

@MainActor
final class RoomConnectionManager: ObservableObject {
    @Published var isConnected = false
    @Published var isJoined = false
    @Published var statusText = "Connecting…"
    @Published var users: [RoomPresence] = []
    @Published var messages: [RoomChatMessage] = []

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var activeRoomId = ""
    private var activeRoomName = ""
    private var isConnecting = false
    private var joinedAckFallback: DispatchWorkItem?
    private var lastSystemNotificationFingerprint = ""
    private var lastSystemNotificationAt = Date.distantPast
    private let relayAudio = IOSRelayAudioEngine()
    private var microphoneCaptureEnabled = false

    func connectAndJoin(baseURL: String, roomId: String, roomName: String, userName: String, authToken: String) {
        let normalizedRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoomId.isEmpty else {
            statusText = "Invalid room."
            return
        }
        guard !isConnecting else { return }
        isConnecting = true
        disconnect()
        activeRoomId = normalizedRoomId
        activeRoomName = roomName
        microphoneCaptureEnabled = false
        statusText = "Connecting to \(roomName)…"

        guard let socketURL = URL(string: normalizeBaseURL(baseURL)) else {
            statusText = "Invalid server URL."
            return
        }

        var config: SocketIOClientConfiguration = [
            .path("/socket.io"),
            .forceWebsockets(true),
            .compress,
            .log(false),
            .reconnects(true),
            .reconnectAttempts(8)
        ]

        let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            config.insert(.extraHeaders([
                "Authorization": "Bearer \(trimmedToken)",
                "x-session-token": trimmedToken
            ]))
        }

        let mgr = SocketManager(socketURL: socketURL, config: config)
        manager = mgr
        socket = mgr.defaultSocket
        registerSocketHandlers(userName: userName, authToken: trimmedToken)
        socket?.connect()
    }

    func sendMessage(_ text: String) {
        guard isConnected, isJoined else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        socket?.emit("chat-message", ["roomId": activeRoomId, "message": body, "type": "text"])
        NotificationCenter.default.post(
            name: .iosRoomMessageEvent,
            object: nil,
            userInfo: [
                "roomId": activeRoomId,
                "roomName": activeRoomName,
                "author": "You",
                "body": body,
                "timestamp": Date().timeIntervalSince1970
            ]
        )
    }

    func disconnect() {
        joinedAckFallback?.cancel()
        joinedAckFallback = nil
        socket?.disconnect()
        manager = nil
        socket = nil
        relayAudio.stop()
        microphoneCaptureEnabled = false
        isConnected = false
        isJoined = false
        users = []
        isConnecting = false
        NotificationCenter.default.post(
            name: .iosRoomLeft,
            object: nil,
            userInfo: [
                "roomId": activeRoomId,
                "roomName": activeRoomName
            ]
        )
    }

    func setMicrophoneCaptureEnabled(_ enabled: Bool) {
        microphoneCaptureEnabled = enabled
        relayAudio.setCaptureEnabled(enabled)
    }

    func sendDirectMessage(to userId: String, userName: String, text: String) {
        guard isConnected, isJoined else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        socket?.emit("direct-message", [
            "targetUserId": userId,
            "message": body,
            "type": "text"
        ])
        NotificationCenter.default.post(
            name: .iosDirectMessageEvent,
            object: nil,
            userInfo: [
                "roomId": activeRoomId,
                "roomName": activeRoomName,
                "userId": userId,
                "userName": userName,
                "author": "You",
                "body": body,
                "timestamp": Date().timeIntervalSince1970
            ]
        )
    }

    private func registerSocketHandlers(userName: String, authToken: String) {
        socket?.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.isConnecting = false
                self.isConnected = true
                self.statusText = "Connected. Joining \(self.activeRoomName)…"
                if !authToken.isEmpty {
                    self.socket?.emit("register-session", ["token": authToken, "provider": "email"])
                }
                self.socket?.emit("join-room", ["roomId": self.activeRoomId, "userName": userName])
                self.scheduleJoinFallback()
                await self.fetchHistory()
            }
        }

        socket?.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in
                self?.isConnecting = false
                self?.isConnected = false
                self?.isJoined = false
                self?.statusText = "Disconnected."
            }
        }

        socket?.on(clientEvent: .error) { [weak self] data, _ in
            let message = Self.stringify(data.first) ?? "Connection error."
            Task { @MainActor in
                self?.isConnecting = false
                self?.statusText = message
            }
        }

        socket?.on("joined-room") { [weak self] data, _ in
            guard let self else { return }
            Task { @MainActor in
                self.isJoined = true
                self.statusText = "Joined \(self.activeRoomName)."
                self.joinedAckFallback?.cancel()
                self.joinedAckFallback = nil
                if let payload = data.first as? [String: Any],
                   let room = payload["room"] as? [String: Any],
                   let usersRaw = room["users"] as? [[String: Any]] {
                    self.users = usersRaw.compactMap(Self.mapPresence)
                    NotificationCenter.default.post(
                        name: .iosRoomUsersUpdated,
                        object: nil,
                        userInfo: [
                            "roomId": self.activeRoomId,
                            "roomName": self.activeRoomName,
                            "users": self.users.map { ["id": $0.id, "name": $0.name] }
                        ]
                    )
                }
                NotificationCenter.default.post(
                    name: .iosRoomJoined,
                    object: nil,
                    userInfo: [
                        "roomId": self.activeRoomId,
                        "roomName": self.activeRoomName
                    ]
                )
                self.relayAudio.start(socket: self.socket, captureEnabled: self.microphoneCaptureEnabled)
            }
        }

        socket?.on("room-users") { [weak self] data, _ in
            guard let self else { return }
            Task { @MainActor in
                guard let payload = data.first as? [String: Any],
                      let usersRaw = payload["users"] as? [[String: Any]] else { return }
                self.users = usersRaw.compactMap(Self.mapPresence)
                NotificationCenter.default.post(
                    name: .iosRoomUsersUpdated,
                    object: nil,
                    userInfo: [
                        "roomId": self.activeRoomId,
                        "roomName": self.activeRoomName,
                        "users": self.users.map { ["id": $0.id, "name": $0.name] }
                    ]
                )
            }
        }

        socket?.on("chat-message") { [weak self] data, _ in
            guard let self else { return }
            Task { @MainActor in
                guard let payload = data.first as? [String: Any],
                      let message = Self.mapMessage(payload) else { return }
                self.messages.append(message)
                if self.messages.count > 200 {
                    self.messages = Array(self.messages.suffix(200))
                }
                NotificationCenter.default.post(
                    name: .iosRoomMessageEvent,
                    object: nil,
                    userInfo: [
                        "roomId": self.activeRoomId,
                        "roomName": self.activeRoomName,
                        "author": message.author,
                        "body": message.body,
                        "timestamp": message.timestamp.timeIntervalSince1970
                    ]
                )
            }
        }

        socket?.on("direct-message") { [weak self] data, _ in
            guard let self else { return }
            Task { @MainActor in
                guard let payload = data.first as? [String: Any] else { return }
                let sender = Self.stringify(payload["senderName"]) ?? Self.stringify(payload["senderUsername"]) ?? "User"
                let senderId = Self.stringify(payload["senderId"]) ?? Self.stringify(payload["fromUserId"]) ?? ""
                let body = Self.stringify(payload["message"]) ?? Self.stringify(payload["content"]) ?? ""
                guard !body.isEmpty else { return }
                let timestamp = Self.parseDate(payload["timestamp"])?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                NotificationCenter.default.post(
                    name: .iosDirectMessageEvent,
                    object: nil,
                    userInfo: [
                        "roomId": self.activeRoomId,
                        "roomName": self.activeRoomName,
                        "userId": senderId,
                        "userName": sender,
                        "author": sender,
                        "body": body,
                        "timestamp": timestamp
                    ]
                )
            }
        }

        let handleSystemActionEvent: ([Any]) -> Void = { [weak self] data in
            guard let self else { return }
            guard let payload = data.first as? [String: Any] else { return }
            Task { @MainActor in
                self.handleIncomingSystemAction(payload)
            }
        }
        socket?.on("system-action-notification") { data, _ in
            handleSystemActionEvent(data)
        }
        socket?.on("admin-notification") { data, _ in
            handleSystemActionEvent(data)
        }

        socket?.on("join-room-error") { [weak self] data, _ in
            let message = Self.stringify((data.first as? [String: Any])?["message"]) ?? "Could not join room."
            Task { @MainActor in
                self?.isConnecting = false
                self?.statusText = message
                self?.isJoined = false
            }
        }

        socket?.on("relayed-audio") { [weak self] data, _ in
            guard let self,
                  let payload = data.first as? [String: Any] else { return }
            self.relayAudio.handleIncomingAudio(payload)
        }

        socket?.on("audio-data") { [weak self] data, _ in
            guard let self,
                  let payload = data.first as? [String: Any] else { return }
            self.relayAudio.handleIncomingAudio(payload)
        }
    }

    private func handleIncomingSystemAction(_ payload: [String: Any]) {
        let enabled = UserDefaults.standard.object(forKey: "systemActionNotifications") as? Bool ?? true
        guard enabled else { return }

        let title = (Self.stringify(payload["title"]) ?? "VoiceLink System").trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (Self.stringify(payload["message"]) ?? "A system action was sent.").trimmingCharacters(in: .whitespacesAndNewlines)
        let type = Self.stringify(payload["type"]) ?? "system_action"
        let timestamp = Self.stringify(payload["timestamp"]) ?? ""
        let fingerprint = "\(type)|\(title)|\(message)|\(timestamp)"
        if fingerprint == lastSystemNotificationFingerprint,
           Date().timeIntervalSince(lastSystemNotificationAt) < 1.25 {
            return
        }
        lastSystemNotificationFingerprint = fingerprint
        lastSystemNotificationAt = Date()

        let systemMessage = RoomChatMessage(
            id: UUID().uuidString,
            author: "System",
            body: "\(title): \(message)",
            timestamp: Date()
        )
        messages.append(systemMessage)
        if messages.count > 200 {
            messages = Array(messages.suffix(200))
        }

        let includeSound = UserDefaults.standard.object(forKey: "systemActionNotificationSound") as? Bool ?? true
        deliverLocalSystemNotification(
            identifier: "system-action-\(UUID().uuidString)",
            title: title,
            body: message,
            includeSound: includeSound
        )
    }

    private func deliverLocalSystemNotification(identifier: String, title: String, body: String, includeSound: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let deliver: () -> Void = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                if includeSound {
                    content.sound = .default
                }
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

    private func scheduleJoinFallback() {
        joinedAckFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isConnected, !self.isJoined else { return }
            self.isJoined = true
            self.statusText = "Connected to \(self.activeRoomName)."
        }
        joinedAckFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func fetchHistory() async {
        guard let url = URL(string: "\(normalizeBaseURL(manager?.socketURL.absoluteString ?? ""))/api/rooms/\(activeRoomId)/messages?limit=50") else {
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawMessages = json["messages"] as? [[String: Any]] else { return }
            let mapped = rawMessages.compactMap(Self.mapMessage)
            if !mapped.isEmpty {
                messages = mapped
            }
        } catch {
            // History loading is optional; socket stream continues.
        }
    }

    private static func mapPresence(_ raw: [String: Any]) -> RoomPresence? {
        let id = stringify(raw["id"]) ?? UUID().uuidString
        let name = stringify(raw["name"]) ?? stringify(raw["username"]) ?? "User"
        return RoomPresence(id: id, name: name)
    }

    static func mapMessage(_ raw: [String: Any]) -> RoomChatMessage? {
        let body = stringify(raw["message"]) ?? stringify(raw["content"]) ?? ""
        guard !body.isEmpty else { return nil }
        let id = stringify(raw["id"]) ?? UUID().uuidString
        let author = stringify(raw["userName"]) ?? stringify(raw["username"]) ?? "User"
        let timestamp = parseDate(raw["timestamp"]) ?? Date()
        return RoomChatMessage(id: id, author: author, body: body, timestamp: timestamp)
    }

    private static func stringify(_ value: Any?) -> String? {
        if let stringValue = value as? String { return stringValue }
        if let intValue = value as? Int { return String(intValue) }
        if let doubleValue = value as? Double { return String(doubleValue) }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let iso = value as? String {
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: iso)
        }
        return nil
    }
}

final class IOSRelayAudioEngine {
    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private weak var socket: SocketIOClient?
    private var started = false
    private var captureEnabled = false

    func start(socket: SocketIOClient?, captureEnabled: Bool) {
        guard !started else { return }
        self.socket = socket
        self.captureEnabled = captureEnabled
        startPlayback()
        if captureEnabled {
            startCapture()
        }
        started = true
    }

    func stop() {
        captureEngine?.inputNode.removeTap(onBus: 0)
        captureEngine?.stop()
        playbackEngine?.stop()
        playerNode?.stop()
        captureEngine = nil
        playbackEngine = nil
        playerNode = nil
        started = false
        captureEnabled = false
    }

    func setCaptureEnabled(_ enabled: Bool) {
        captureEnabled = enabled
        if enabled {
            guard started, captureEngine == nil else { return }
            startCapture()
        } else {
            captureEngine?.inputNode.removeTap(onBus: 0)
            captureEngine?.stop()
            captureEngine = nil
        }
    }

    func handleIncomingAudio(_ audioInfo: [String: Any]) {
        guard let base64String = audioInfo["audioData"] as? String,
              let data = Data(base64Encoded: base64String),
              let sampleRate = audioInfo["sampleRate"] as? Double else {
            return
        }
        let channels = AVAudioChannelCount(max(1, audioInfo["channels"] as? Int ?? 1))
        schedulePlayback(data: data, sampleRate: sampleRate, channels: channels)
    }

    private func startCapture() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        socket?.emit("enable-audio-relay", [
            "sampleRate": format.sampleRate,
            "channels": Int(format.channelCount)
        ])
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.send(buffer: buffer)
        }
        do {
            try engine.start()
            captureEngine = engine
        } catch {
            print("[iOS Audio] Capture start failed: \(error)")
        }
    }

    private func startPlayback() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        do {
            try engine.start()
            player.play()
            playbackEngine = engine
            playerNode = player
        } catch {
            print("[iOS Audio] Playback start failed: \(error)")
        }
    }

    private func send(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        var interleaved = [Float](repeating: 0, count: frameLength * channelCount)
        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                interleaved[(frame * channelCount) + channel] = channelData[channel][frame]
            }
        }
        let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        socket?.emit("audio-data", [
            "audioData": data.base64EncodedString(),
            "timestamp": Date().timeIntervalSince1970,
            "sampleRate": buffer.format.sampleRate,
            "channels": channelCount
        ])
    }

    private func schedulePlayback(data: Data, sampleRate: Double, channels: AVAudioChannelCount) {
        guard let playerNode else { return }
        let samples = data.withUnsafeBytes { rawBuffer -> [Float] in
            let pointer = rawBuffer.bindMemory(to: Float.self)
            return Array(pointer)
        }
        let frameCount = max(1, samples.count / Int(channels))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            for channel in 0..<Int(channels) {
                let sampleIndex = (frame * Int(channels)) + channel
                if sampleIndex < samples.count {
                    channelData[channel][frame] = samples[sampleIndex]
                }
            }
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }
}

@MainActor
final class IOSVoiceSessionManager: ObservableObject {
    @Published var sessionStatus = ""
    private var wantsActive = false
    private var observers: [NSObjectProtocol] = []

    enum SessionMode {
        case roomPlayback
        case fullDuplex
    }

    init() {
        registerObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func activateForRoomIfNeeded(permissionGranted: Bool) {
        wantsActive = true
        configureAndActivate(reason: "room-open", mode: permissionGranted ? .fullDuplex : .roomPlayback)
    }

    func deactivate() {
        wantsActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Keep silent here; deactivation failures are non-fatal during navigation.
        }
    }

    private func registerObservers() {
        let center = NotificationCenter.default

        let interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                guard
                    let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let interruptionType = AVAudioSession.InterruptionType(rawValue: typeValue)
                else { return }

                switch interruptionType {
                case .began:
                    self.sessionStatus = "Audio interrupted."
                case .ended:
                    if self.wantsActive {
                        self.configureAndActivate(reason: "interruption-ended", mode: .roomPlayback)
                    }
                @unknown default:
                    break
                }
            }
        }
        observers.append(interruptionObserver)

        let routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.wantsActive else { return }
                self.configureAndActivate(reason: "route-change", mode: .roomPlayback)
            }
        }
        observers.append(routeObserver)

        let mediaResetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.wantsActive else { return }
                self.configureAndActivate(reason: "media-services-reset", mode: .roomPlayback)
            }
        }
        observers.append(mediaResetObserver)
    }

    private func configureAndActivate(reason: String, mode: SessionMode) {
        let session = AVAudioSession.sharedInstance()
        let stereoOptions: AVAudioSession.CategoryOptions = [.allowAirPlay, .allowBluetoothA2DP]

        func applyPlaybackFallback(message: String) {
            do {
                try session.setCategory(.playback, mode: .default, options: stereoOptions)
                try session.setActive(true)
                sessionStatus = message
            } catch {
                do {
                    try session.setCategory(.ambient, mode: .default, options: stereoOptions)
                    try session.setActive(true)
                    sessionStatus = message
                } catch {
                    sessionStatus = "Room joined, but audio is not available right now."
                }
            }
        }

        func configurePlayback() throws {
            try session.setCategory(.playback, mode: .default, options: stereoOptions)
            if session.maximumOutputNumberOfChannels >= 2 {
                try? session.setPreferredOutputNumberOfChannels(2)
            }
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        }

        func configureFullDuplex(primaryOptions: AVAudioSession.CategoryOptions) throws {
            try session.setCategory(.playAndRecord, mode: .default, options: primaryOptions)
            if session.maximumOutputNumberOfChannels >= 2 {
                try? session.setPreferredOutputNumberOfChannels(2)
            }
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        }

        do {
            switch mode {
            case .roomPlayback:
                try configurePlayback()
                sessionStatus = "Audio ready."
            case .fullDuplex:
                do {
                    try configureFullDuplex(primaryOptions: [.defaultToSpeaker, .allowBluetooth, .allowAirPlay])
                    sessionStatus = "Audio ready. Microphone and output are active."
                } catch {
                    do {
                        try configureFullDuplex(primaryOptions: [.defaultToSpeaker, .allowBluetooth])
                        sessionStatus = "Audio ready. Microphone and output are active."
                    } catch {
                        do {
                            try configurePlayback()
                            sessionStatus = "Room joined. Audio is using playback-only mode."
                        } catch {
                            applyPlaybackFallback(message: "Room joined. Audio is using fallback playback.")
                        }
                    }
                }
            }
        } catch {
            if mode == .roomPlayback {
                applyPlaybackFallback(message: "Room joined. Audio is using fallback playback.")
            } else {
                applyPlaybackFallback(message: "Room joined. Audio is using playback-only mode.")
            }
        }
    }
}

@MainActor
final class IOSRoomMediaPlaybackManager: ObservableObject {
    @Published var playbackStatus = ""

    private var player: AVPlayer?
    private var currentURL: URL?
    private var roomObserver: NSObjectProtocol?

    deinit {
        if let roomObserver {
            NotificationCenter.default.removeObserver(roomObserver)
        }
    }

    func startPreview(baseURL: String, roomId: String) async {
        await startPlayback(baseURL: baseURL, roomId: roomId, preferBackground: true)
    }

    func startForJoinedRoom(baseURL: String, roomId: String) async {
        observeRoomStreamEvents(baseURL: baseURL, roomId: roomId)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            // Keep going; joined-room playback may still succeed once the room audio session activates.
        }
        await startPlayback(baseURL: baseURL, roomId: roomId, preferBackground: false)
    }

    func stop() {
        player?.pause()
        player = nil
        currentURL = nil
        playbackStatus = ""
        if let roomObserver {
            NotificationCenter.default.removeObserver(roomObserver)
            self.roomObserver = nil
        }
    }

    private func observeRoomStreamEvents(baseURL: String, roomId: String) {
        if let roomObserver {
            NotificationCenter.default.removeObserver(roomObserver)
            self.roomObserver = nil
        }
        roomObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.startPlayback(baseURL: baseURL, roomId: roomId, preferBackground: false)
            }
        }
    }

    private func startPlayback(baseURL: String, roomId: String, preferBackground: Bool) async {
        guard let streamInfo = await fetchRoomStream(baseURL: baseURL, roomId: roomId) else {
            playbackStatus = preferBackground ? "No preview audio is active." : "No room media is active."
            stopPlaybackOnly()
            return
        }
        guard streamInfo.active, let streamURL = URL(string: streamInfo.streamUrl), !streamInfo.streamUrl.isEmpty else {
            playbackStatus = streamInfo.disabled ? "Room media is disabled." : (preferBackground ? "No preview audio is active." : "No room media is active.")
            stopPlaybackOnly()
            return
        }
        if currentURL == streamURL, player != nil {
            player?.play()
            playbackStatus = streamInfo.title.isEmpty ? "Playing audio." : "Playing \(streamInfo.title)."
            return
        }

        if preferBackground {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
                try session.setActive(true)
            } catch {
                // Keep going; playback may still succeed.
            }
        }

        currentURL = streamURL
        let newPlayer = AVPlayer(url: streamURL)
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        player = newPlayer
        newPlayer.play()
        playbackStatus = streamInfo.title.isEmpty ? "Playing audio." : "Playing \(streamInfo.title)."
    }

    private func stopPlaybackOnly() {
        player?.pause()
        player = nil
        currentURL = nil
    }

    private func fetchRoomStream(baseURL: String, roomId: String) async -> RoomStreamInfo? {
        guard let url = URL(string: "\(normalizeBaseURL(baseURL))/api/jellyfin/room-stream/\(roomId)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return RoomStreamInfo(
                active: (json["active"] as? Bool) ?? false,
                disabled: (json["disabled"] as? Bool) ?? false,
                streamUrl: (json["streamUrl"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                title: (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return nil
        }
    }
}

private struct RoomStreamInfo {
    let active: Bool
    let disabled: Bool
    let streamUrl: String
    let title: String
}

struct RoomSessionView: View {
    let destination: RoomSessionDestination

    @Environment(\.dismiss) private var dismiss
    @StateObject private var connection = RoomConnectionManager()
    @StateObject private var audioSession = IOSVoiceSessionManager()
    @StateObject private var mediaPlayback = IOSRoomMediaPlaybackManager()
    @AppStorage("voicelink.authToken") private var authToken = ""
    @AppStorage("voicelink.displayName") private var displayName = ""
    @State private var messageDraft = ""
    @State private var permissionText = ""
    @State private var selectedUser: RoomPresence?
    @State private var showUserActions = false
    @State private var didStartSession = false
    @State private var showRoomChat = false

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(connection.statusText)
                    if !permissionText.isEmpty {
                        Text(permissionText)
                            .foregroundStyle(.secondary)
                    }
                    if !mediaPlayback.playbackStatus.isEmpty {
                        Text(mediaPlayback.playbackStatus)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Users in Room") {
                    if connection.users.isEmpty {
                        Text("No active users listed yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(connection.users) { user in
                            Button(user.name) {
                                selectedUser = user
                                showUserActions = true
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the profile. Additional user actions are available through VoiceOver actions.")
                            .accessibilityAction(named: Text("View Profile")) {
                                selectedUser = user
                                permissionText = "Profile view opened for \(user.name)."
                                NotificationCenter.default.post(
                                    name: .iosShowUserProfile,
                                    object: nil,
                                    userInfo: [
                                        "userId": user.id,
                                        "userName": user.name
                                    ]
                                )
                            }
                            .accessibilityAction(named: Text("Message User")) {
                                NotificationCenter.default.post(
                                    name: .iosOpenMessagesTab,
                                    object: nil,
                                    userInfo: [
                                        "roomId": destination.roomId,
                                        "roomName": destination.roomName,
                                        "userId": user.id,
                                        "userName": user.name
                                    ]
                                )
                            }
                        }
                    }
                }

                Section("Room Chat") {
                    Text(showRoomChat ? "Room messages are shown below the room controls." : "Show chat to read and send room messages without leaving the room.")
                        .foregroundStyle(.secondary)
                    Button(showRoomChat ? "Hide Chat" : "Show Chat") {
                        showRoomChat.toggle()
                    }
                    .buttonStyle(.borderedProminent)

                    if showRoomChat {
                        if connection.messages.isEmpty {
                            Text("No room messages yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(connection.messages.suffix(150).reversed()) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.author)
                                        .font(.subheadline.weight(.semibold))
                                    Text(message.body)
                                        .font(.body)
                                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .navigationTitle(destination.roomName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Room Actions") {
                        Button(showRoomChat ? "Hide Chat" : "Show Chat") {
                            showRoomChat.toggle()
                        }
                        Button("Leave Room", role: .destructive) {
                            dismiss()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    TextField("Message \(destination.roomName)", text: $messageDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Message")
                    Button("Send") {
                        let outgoing = messageDraft
                        messageDraft = ""
                        connection.sendMessage(outgoing)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
                .background(.ultraThinMaterial)
            }
            .task {
                guard !didStartSession else { return }
                didStartSession = true
                audioSession.activateForRoomIfNeeded(permissionGranted: false)
                connection.setMicrophoneCaptureEnabled(false)
                await mediaPlayback.startForJoinedRoom(baseURL: destination.baseURL, roomId: destination.roomId)
                if !audioSession.sessionStatus.isEmpty {
                    permissionText = audioSession.sessionStatus
                }
                let userName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "iOS User" : displayName
                connection.connectAndJoin(
                    baseURL: destination.baseURL,
                    roomId: destination.roomId,
                    roomName: destination.roomName,
                    userName: userName,
                    authToken: authToken
                )
                let permissionGranted = await requestMicrophonePermission()
                if permissionGranted {
                    try? await Task.sleep(for: .milliseconds(450))
                }
                audioSession.activateForRoomIfNeeded(permissionGranted: permissionGranted)
                connection.setMicrophoneCaptureEnabled(permissionGranted)
                if !audioSession.sessionStatus.isEmpty {
                    permissionText = audioSession.sessionStatus
                }
            }
            .onDisappear {
                guard didStartSession else { return }
                didStartSession = false
                connection.disconnect()
                audioSession.deactivate()
                mediaPlayback.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .iosSendDirectMessage)) { notification in
                guard let info = notification.userInfo else { return }
                guard let roomId = info["roomId"] as? String, roomId == destination.roomId else { return }
                let userId = (info["userId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let userName = (info["userName"] as? String ?? "User").trimmingCharacters(in: .whitespacesAndNewlines)
                let body = (info["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !userId.isEmpty, !body.isEmpty else { return }
                connection.sendDirectMessage(to: userId, userName: userName.isEmpty ? "User" : userName, text: body)
            }
            .onReceive(NotificationCenter.default.publisher(for: .iosRequestLeaveRoom)) { notification in
                if let info = notification.userInfo,
                   let roomId = info["roomId"] as? String,
                   !roomId.isEmpty,
                   roomId != destination.roomId {
                    return
                }
                dismiss()
            }
            .confirmationDialog(
                selectedUser?.name ?? "User Actions",
                isPresented: $showUserActions,
                titleVisibility: .visible
            ) {
                if let selectedUser {
                    Button("View Profile") {
                        permissionText = "Profile view opened for \(selectedUser.name)."
                        NotificationCenter.default.post(
                            name: .iosShowUserProfile,
                            object: nil,
                            userInfo: [
                                "userId": selectedUser.id,
                                "userName": selectedUser.name
                            ]
                        )
                    }
                    Button("Message User") {
                        NotificationCenter.default.post(
                            name: .iosOpenMessagesTab,
                            object: nil,
                            userInfo: [
                                "roomId": destination.roomId,
                                "roomName": destination.roomName,
                                "userId": selectedUser.id,
                                "userName": selectedUser.name
                            ]
                        )
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .accessibilityAction(.magicTap) {
                announceCurrentSpeakers()
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            permissionText = "Microphone access granted."
            return true
        case .denied:
            permissionText = "Microphone access denied in iOS settings."
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    Task { @MainActor in
                        permissionText = granted ? "Microphone access granted." : "Microphone access denied."
                        continuation.resume(returning: granted)
                    }
                }
            }
        @unknown default:
            permissionText = ""
            return false
        }
    }

    private func announceCurrentSpeakers() {
        let names = connection.users.map(\.name)
        let message: String
        if names.isEmpty {
            message = "No active speakers right now."
        } else {
            message = "Users in room: \(names.prefix(3).joined(separator: ", "))."
        }
        UIAccessibility.post(notification: .announcement, argument: message)
        permissionText = message
    }
}

struct RoomPreviewView: View {
    let destination: RoomPreviewDestination

    @Environment(\.dismiss) private var dismiss
    @StateObject private var mediaPlayback = IOSRoomMediaPlaybackManager()
    @State private var nowPlaying = "No active media."
    @State private var latestMessages: [RoomChatMessage] = []
    @State private var previewStatus = "Loading preview…"

    var body: some View {
        NavigationStack {
            List {
                Section("Room") {
                    LabeledContent("Name", value: destination.roomName)
                    LabeledContent("Users", value: "\(destination.room.userCount)")
                    LabeledContent("Visibility", value: destination.room.visibility.capitalized)
                    if !destination.roomDescription.isEmpty {
                        Text(destination.roomDescription)
                    }
                }

                Section("Now Playing") {
                    Text(nowPlaying)
                        .foregroundStyle(.secondary)
                    if !mediaPlayback.playbackStatus.isEmpty {
                        Text(mediaPlayback.playbackStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Latest Messages") {
                    if latestMessages.isEmpty {
                        Text(previewStatus)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(latestMessages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(message.body)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await loadPreview()
                await mediaPlayback.startPreview(baseURL: destination.baseURL, roomId: destination.roomId)
            }
            .onDisappear {
                mediaPlayback.stop()
            }
        }
    }

    private func loadPreview() async {
        await loadNowPlaying()
        await loadRecentMessages()
    }

    private func loadNowPlaying() async {
        guard let url = URL(string: "\(normalizeBaseURL(destination.baseURL))/api/rooms/\(destination.roomId)/now-playing") else {
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            if let title = json["title"] as? String, !title.isEmpty {
                nowPlaying = title
            } else if let name = json["name"] as? String, !name.isEmpty {
                nowPlaying = name
            }
        } catch {
            // Preview data is optional.
        }
    }

    private func loadRecentMessages() async {
        guard let url = URL(string: "\(normalizeBaseURL(destination.baseURL))/api/rooms/\(destination.roomId)/messages?limit=25") else {
            previewStatus = "Invalid server URL."
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawMessages = json["messages"] as? [[String: Any]] else {
                previewStatus = "No preview messages available."
                return
            }
            let mapped = rawMessages.compactMap(RoomConnectionManager.mapMessage)
            latestMessages = Array(mapped.suffix(15))
            previewStatus = latestMessages.isEmpty ? "No preview messages available." : ""
        } catch {
            previewStatus = "Could not load preview."
        }
    }
}

extension Notification.Name {
    static let iosRoomMessageEvent = Notification.Name("iosRoomMessageEvent")
    static let iosOpenMessagesTab = Notification.Name("iosOpenMessagesTab")
    static let iosShowUserProfile = Notification.Name("iosShowUserProfile")
    static let iosDirectMessageEvent = Notification.Name("iosDirectMessageEvent")
    static let iosSendDirectMessage = Notification.Name("iosSendDirectMessage")
    static let iosRequestLeaveRoom = Notification.Name("iosRequestLeaveRoom")
    static let iosRoomJoined = Notification.Name("iosRoomJoined")
    static let iosRoomLeft = Notification.Name("iosRoomLeft")
    static let iosRoomUsersUpdated = Notification.Name("iosRoomUsersUpdated")
}

private func normalizeBaseURL(_ rawURL: String) -> String {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "https://voicelink.devinecreations.net"
    }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
    return "https://\(trimmed)"
}
